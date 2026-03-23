---
description: Install Semaphore CE on a single Linux machine using k3s and the setup script
---

# Single-Node k3s Deployment

This page explains how to install the Semaphore Community Edition control plane on a
single Linux server using [k3s](https://k3s.io/) and the `setup.sh` script bundled in the
Semaphore repository.

## Overview {#overview}

The setup script automates the full installation sequence: it installs k3s (with Traefik
ingress), Helm, the Emissary Ingress CRDs, and the Semaphore Helm chart in a single run.
The k3s values override in `deploy/k3s/values.yaml` pre-configures the chart for
single-node use so you don't have to supply low-level Helm flags.

This guide is the fastest path to a self-hosted Semaphore CE installation. It is suitable
for small teams that want a simple, low-cost deployment without high availability or
horizontal scalability.

### Ingress architecture {#ingress-architecture}

This deployment uses **two ingress controllers in tandem** — they are not alternatives:

| Controller | Role |
|---|---|
| **Traefik** (k3s built-in) | Handles the Kubernetes `Ingress` object; terminates TLS on port 443; forwards all traffic to the Emissary ambassador service on port 8080 |
| **Emissary-ingress (ambassador)** | Handles all internal L7 routing to Semaphore microservices via its own CRDs (`Mapping`, `Listener`, `Host`, `AuthService`) |

```
Internet → Traefik (port 443, TLS termination)
         → ambassador/emissary (port 8080, internal routing)
         → Semaphore microservices
```

The Emissary CRDs **cannot be skipped**, even though Traefik is already bundled with k3s.
The Semaphore Helm chart hard-codes `ambassador` as the Ingress backend service and
expresses all internal routing as Emissary `Mapping` resources. If the CRDs are absent,
`helm install` will fail at API server validation before any pod starts.

Replacing Emissary with Traefik-native routing would require replacing all `Mapping`,
`Listener`, and `AuthService` resources in the chart with Traefik `IngressRoute` equivalents
— a chart-level change, not a values override.

:::info Self-hosted agents

The control plane installed here runs your CI/CD pipelines but does not execute job
workloads itself. After installation, add one or more
[self-hosted agents](../using-semaphore/self-hosted.md) as job runners. The number of
agents depends on your expected concurrency.

:::

## Prerequisites {#prerequisites}

### Software

- Linux host running **Ubuntu 22.04 LTS or 24.04 LTS** (other systemd-based distros may work
  but are not tested)
- `curl` and `base64` installed (both are present in a default Ubuntu install)
- Root or sudo privileges (the k3s installer requires root)
- Outbound internet access for container images, the k3s and Helm installers, and the OCI
  Helm chart (`ghcr.io`)
- The Semaphore repository cloned to the machine — the script reads
  `deploy/k3s/values.yaml` from the same directory

### Networking

- A **domain** you control (Semaphore must be installed on a subdomain, e.g.
  `ci.example.com`)
- A **public IP address** assigned to the machine
- Inbound ports **22** (SSH), **80** (HTTP), and **443** (HTTPS) open in your firewall or
  cloud security group
- Two DNS A records pointing to the public IP (see [Step 3](#dns))

### TLS certificate

- A valid wildcard TLS certificate for your subdomain, e.g. `*.ci.example.com`
- The full-chain PEM file and the private-key PEM file must be present on the machine
  before running the script

:::note

TLS certificates issued by Let's Encrypt expire after **90 days** and do not auto-renew in
this setup. Store the paths and commands you used; you'll need them for
[certificate renewal](#renew).

:::

## Minimum system requirements {#requirements}

| Resource | Minimum |
|---|---|
| CPU | 8 vCPUs |
| RAM | 16 GB |
| Disk | 50 GB |

:::tip

If your host has 32 GB or more of RAM, increase the Postgres `sharedBuffers` from the
k3s-override default of 256 MB back to 1024 MB by adding
`--set global.database.local.sharedBuffers=1024MB` when running the script.

:::

## Step 1 - Define the domain {#domain}

Install Semaphore on a **subdomain**. Installing on a bare domain may interfere with
other services.

If your base domain is `example.com`, choose a subdomain such as `ci.example.com` for the
Semaphore installation.

## Step 2 - Prepare the machine {#env}

<Steps>

1. SSH into the Linux server

    ```shell title="Connect to your server"
    ssh <user>@<hostname>
    ```

2. Create a dedicated user to run the installation and give them sudo privileges

    ```shell title="Create semaphore user"
    sudo adduser semaphore
    sudo usermod -aG sudo semaphore
    su - semaphore
    ```

3. Install certbot if it is not already present

    ```shell title="Install certbot"
    sudo apt-get update
    sudo apt-get -y install certbot
    ```

4. Clone the Semaphore repository — the setup script and the k3s values override live
   inside it

    ```shell title="Clone the Semaphore repository"
    git clone https://github.com/semaphoreio/semaphore.git
    cd semaphore
    ```

</Steps>

## Step 3 - Create DNS A records {#dns}

<Steps>

1. Go to your domain provider's DNS settings

2. Create an A record for your subdomain

    - Type: A
    - Name: `ci.example.com`
    - Value: the public IP address of your Linux machine

3. Create a wildcard A record

    - Type: A
    - Name: `*.ci.example.com`
    - Value: the public IP address of your Linux machine

4. Wait for DNS propagation (typically a few minutes)

    Verify propagation using the [Google Dig Tool](https://toolbox.googleapps.com/apps/dig/#A/)
    for both `ci.example.com` and `id.ci.example.com`

</Steps>

## Step 4 - Create TLS certificates {#certs}

Run certbot to generate a wildcard certificate for your subdomain.

<Steps>

1. Run certbot in manual DNS-challenge mode

    ```shell title="Create TLS certificate"
    mkdir -p certs
    certbot certonly --manual --preferred-challenges=dns \
        -d "*.ci.example.com" \
        --register-unsafely-without-email \
        --work-dir certs \
        --config-dir certs \
        --logs-dir certs
    ```

2. Certbot prompts you to create a DNS TXT record to verify domain ownership

    ```text title="Certbot challenge prompt"
    Please deploy a DNS TXT record under the name:

    _acme-challenge.ci.example.com.

    with the following value:

    EL545Zty7vUUvIHQRSkwxXTWsirldw91enasgB5uOHs
    ```

3. Add the TXT record in your DNS provider's console and wait for it to propagate

    :::tip

    Verify the TXT record is live with the
    [Google Dig Tool](https://toolbox.googleapps.com/apps/dig/#TXT/) before continuing.

    :::

4. Press Enter to continue certbot. A successful run produces output like this

    ```text title="Certbot success message"
    Successfully received the certificate.
    Certificate is saved at: certs/live/ci.example.com/fullchain.pem
    Key is saved at:         certs/live/ci.example.com/privkey.pem
    This certificate expires on 2026-06-16.
    ```

5. Note the paths to both files — you pass them to the setup script in the next step

    - Full-chain certificate: `certs/live/ci.example.com/fullchain.pem`
    - Private key: `certs/live/ci.example.com/privkey.pem`

6. You may delete the DNS TXT record after certbot completes; it is no longer needed

</Steps>

## Step 5 - Run the setup script {#install}

The `setup.sh` script performs the following steps automatically:

1. Installs k3s in single-server mode (Traefik enabled for ingress)
2. Installs Helm
3. Pre-installs the Emissary Ingress CRDs
4. Creates the `semaphore` namespace
5. Base64-encodes your TLS certificate and key
6. Runs `helm upgrade --install` using `deploy/k3s/values.yaml`
7. Waits for all Semaphore pods to reach `Ready` state (up to five minutes), then prints
   a pod listing — exits non-zero immediately if any pod enters `CrashLoopBackOff`

Pass TLS paths as environment variables to keep them out of your shell history, then run
the script with `sudo --preserve-env`:

<Steps>

1. Export the certificate paths

    ```shell title="Export certificate paths"
    export SEMAPHORE_CERT="$PWD/certs/live/ci.example.com/fullchain.pem"
    export SEMAPHORE_KEY="$PWD/certs/live/ci.example.com/privkey.pem"
    ```

2. Run the setup script

    ```shell title="Run the setup script"
    sudo --preserve-env ./deploy/k3s/setup.sh \
        --domain ci.example.com \
        --ip    203.0.113.10 \
        --email admin@example.com \
        --name  "CI Admin"
    ```

    Replace `ci.example.com`, `203.0.113.10`, `admin@example.com`, and `"CI Admin"` with
    your actual values.

    The installation typically takes **10 to 30 minutes** depending on image pull speed. You
    will see `[INFO]` log lines as each step completes.

3. When the script finishes successfully, it prints a summary like this

    ```text title="Setup script completion summary"
    [INFO]  Semaphore CE is installed.
    [INFO]    URL       : https://ci.example.com
    [INFO]    Namespace : semaphore
    [INFO]    Release   : semaphore
    ```

4. Make the k3s kubeconfig available to the `semaphore` user for post-install commands

    ```shell title="Persist KUBECONFIG in your shell profile"
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
    source ~/.bashrc
    ```

    :::warning

    If `KUBECONFIG` is already set to a different cluster config before you run the script,
    the script prints a warning and does **not** override it. `kubectl` and `helm` will
    then target the wrong cluster. Either unset `KUBECONFIG` or prefix the script invocation
    with `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`.

    :::

5. Optionally, install [k9s](https://k9scli.io/) for an interactive TUI view of your
   cluster

    ```shell title="Install k9s"
    wget https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb \
      && sudo apt install ./k9s_linux_amd64.deb \
      && rm k9s_linux_amd64.deb
    ```

</Steps>

### Script options reference {#script-options}

The script accepts flags and equivalent environment variables. Flags take precedence.

| Flag | Environment variable | Required | Description |
|---|---|---|---|
| `--domain DOMAIN` | `SEMAPHORE_DOMAIN` | Yes | Base domain for Semaphore (e.g. `ci.example.com`) |
| `--ip IP` | `SEMAPHORE_IP` | Yes | Public IP of the k3s node |
| `--email EMAIL` | `SEMAPHORE_EMAIL` | Yes | Admin root-user email address |
| `--name NAME` | `SEMAPHORE_NAME` | Yes | Admin root-user display name |
| `--cert FILE` | `SEMAPHORE_CERT` | Yes | Path to TLS full-chain PEM file |
| `--key FILE` | `SEMAPHORE_KEY` | Yes | Path to TLS private-key PEM file |
| `--chart-version VER` | `SEMAPHORE_CHART_VERSION` | No | Chart version to install (default: `v1.5.0`) |
| `--k3s-version VER` | `SEMAPHORE_K3S_VERSION` | No | k3s version to install (default: `v1.31.4+k3s1`) |
| `--helm-version VER` | `SEMAPHORE_HELM_VERSION` | No | Helm version to install (default: `v3.17.1`) |
| `--namespace NS` | — | No | Kubernetes namespace (default: `semaphore`) |
| `--release REL` | — | No | Helm release name (default: `semaphore`) |
| `--skip-k3s` | — | No | Skip k3s installation (useful if k3s is already installed) |
| `--skip-helm` | — | No | Skip Helm installation (useful if Helm is already installed) |

## Step 6 - First login {#first-login}

<Steps>

1. Retrieve the auto-generated login credentials

    ```shell title="Get login credentials"
    echo "Email:     $(kubectl get secret semaphore-authentication -n semaphore \
      -o jsonpath='{.data.ROOT_USER_EMAIL}'    | base64 -d)"
    echo "Password:  $(kubectl get secret semaphore-authentication -n semaphore \
      -o jsonpath='{.data.ROOT_USER_PASSWORD}' | base64 -d)"
    echo "API Token: $(kubectl get secret semaphore-authentication -n semaphore \
      -o jsonpath='{.data.ROOT_USER_TOKEN}'    | base64 -d)"
    ```

2. Open `https://id.ci.example.com` in your browser (replace `ci.example.com` with your
   actual domain)

3. Fill in the email and password. You may be prompted to set a new password on first login

    ![Log in screen for Semaphore](./img/first-login.jpg)

4. Open the server menu and select **Settings**

    ![Server settings menu](./img/settings-menu.jpg)

5. Select **Initialization jobs**

    ![Init job configuration](./img/init-job.jpg)

6. Set **Environment Type** to `Self-hosted Machine`

7. Set **Machine Type** to `s1-kubernetes`, leave **OS Image** empty, and press
   **Save changes**

    :::note

    Press **Save changes** even if those values are already selected.

    :::

8. Return to the Semaphore home page. Open the **Learn** tab and follow the onboarding guide
   to complete the setup and create your first project

    ![Onboarding guide screen](./img/onboarding.jpg)

9. **Back up** the certificate files and your configuration values in a safe location. You
   need them to [upgrade Semaphore](#upgrade) and to [renew TLS certificates](#renew)

</Steps>

## Post-install verification {#verification}

Run the following commands after installation to confirm all components are healthy.

Check that all deployments in the `semaphore` namespace show `1/1` or expected counts in
the `READY` column:

```shell title="Check deployments"
$ kubectl get deployments -n semaphore
NAME                                   READY   UP-TO-DATE   AVAILABLE   AGE
ambassador                             1/1     1            1           5m
artifacthub-internal-grpc-api          1/1     1            1           5m
auth                                   1/1     1            1           5m
...
```

Check that all pods are in `Running` state:

```shell title="Check pods"
kubectl get pods -n semaphore
```

Check the Helm release status:

```shell title="Check Helm release"
$ helm status semaphore -n semaphore
NAME: semaphore
LAST DEPLOYED: ...
STATUS: deployed
```

Check that the Traefik ingress controller is running (it runs in `kube-system`):

```shell title="Check Traefik"
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
```

## Troubleshooting {#troubleshooting}

### Check deployments {#ts-deployments}

If pods are not coming up, inspect the deployment state:

```shell title="View all deployments"
kubectl get deployments -n semaphore
```

Any deployment with `0` in the `AVAILABLE` column needs further investigation:

```shell title="Describe a failing deployment"
kubectl describe deployment/<deployment-name> -n semaphore
```

### Check pods {#ts-pods}

List pods for a specific deployment:

```shell title="List pods for a deployment"
kubectl get pods -n semaphore --selector=app=<deployment-name>
```

For a pod that is not in `Running` state, fetch its description and logs:

```shell title="Describe and log a failing pod"
kubectl describe pod/<pod-name> -n semaphore
kubectl logs <pod-name> -n semaphore
```

### Check the bootstrapper {#ts-bootstrapper}

The bootstrapper job initialises the database and the organisation on first install. If the
UI is unreachable after pods become ready, check bootstrapper logs:

```shell title="Check bootstrapper logs"
kubectl logs -n semaphore -l app.kubernetes.io/name=bootstrapper
```

### TLS or ingress errors {#ts-ingress}

Confirm that the Traefik ingress object was created and has the correct host rule:

```shell title="Check ingress"
kubectl get ingress -n semaphore
kubectl describe ingress semaphore -n semaphore
```

Confirm that the Emissary ambassador service is running as `NodePort` on port 8080:

```shell title="Check ambassador service"
kubectl get service ambassador -n semaphore
```

### k3s node not ready {#ts-node}

If `kubectl get nodes` shows the node as `NotReady`:

```shell title="Check node conditions"
kubectl describe node
```

Check the k3s service logs for errors:

```shell title="Check k3s service logs"
sudo journalctl -u k3s -n 100 --no-pager
```

### Helm install timed out {#ts-timeout}

If the Helm install times out (default: 30 minutes), check which pods are still pending:

```shell title="Find pending pods"
kubectl get pods -n semaphore --field-selector=status.phase!=Running
```

Pending pods are most often caused by image pull failures (check outbound internet access)
or insufficient CPU/RAM. Confirm the node has at least 8 vCPUs and 16 GB of RAM:

```shell title="Check node resources"
kubectl describe node | grep -A 10 'Allocated resources'
```

Once the issue is resolved, re-run the setup script — `helm upgrade --install` is
idempotent.

## Upgrade path {#upgrade}

To upgrade Semaphore to a newer chart version, re-run the setup script with
`--chart-version` set to the target version. The script's `helm upgrade --install` call is
idempotent and safe to run against an existing installation.

<Steps>

1. SSH into the server and navigate to the Semaphore repository

    ```shell title="Navigate to the repository"
    cd semaphore
    source ~/.bashrc   # ensure KUBECONFIG is set
    ```

2. Export the certificate paths (same files used during installation)

    ```shell title="Export certificate paths"
    export SEMAPHORE_CERT="/path/to/fullchain.pem"
    export SEMAPHORE_KEY="/path/to/privkey.pem"
    ```

3. Run the setup script with the desired chart version and `--skip-k3s --skip-helm` to
   avoid reinstalling k3s and Helm

    ```shell title="Upgrade Semaphore"
    sudo --preserve-env ./deploy/k3s/setup.sh \
        --domain ci.example.com \
        --ip    203.0.113.10 \
        --email admin@example.com \
        --name  "CI Admin" \
        --chart-version v1.6.0 \
        --skip-k3s \
        --skip-helm
    ```

</Steps>

### Renew TLS certificates {#renew}

Let's Encrypt certificates expire after 90 days. Renew them with certbot and then re-run
the setup script so Helm installs the new certificate into the cluster.

<Steps>

1. Navigate to the directory that contains your `certs/` folder

2. Re-run certbot and follow the on-screen instructions

    ```shell title="Renew TLS certificate"
    certbot certonly --manual --preferred-challenges=dns \
        -d "*.ci.example.com" \
        --register-unsafely-without-email \
        --work-dir certs \
        --config-dir certs \
        --logs-dir certs
    ```

3. Run the setup script as described in [the upgrade step above](#upgrade) — the updated
   certificate files are re-encoded and re-applied automatically

</Steps>

## See also {#see-also}

- [Quickstart](./quickstart)
- [Migration guide](./migration-overview)
- [How to upgrade Semaphore](./upgrade-semaphore)
- [How to uninstall Semaphore](./uninstall-semaphore)
- [Self-hosted agents](../using-semaphore/self-hosted.md)
