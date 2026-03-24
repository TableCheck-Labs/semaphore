#!/usr/bin/env bash
# setup.sh — Install Semaphore CE on a single-node k3s cluster.
#
# Usage:
#   sudo ./deploy/k3s/setup.sh [OPTIONS]
#
# Options (flags take precedence over environment variables):
#   -d, --domain DOMAIN     Base domain for Semaphore            (env: SEMAPHORE_DOMAIN)
#   -i, --ip IP             Public IP of the k3s node            (env: SEMAPHORE_IP)
#   -e, --email EMAIL       Admin root-user email address         (env: SEMAPHORE_EMAIL)
#   -n, --name NAME         Admin root-user display name          (env: SEMAPHORE_NAME)
#   -c, --cert FILE         Path to TLS full-chain PEM            (env: SEMAPHORE_CERT)
#   -k, --key  FILE         Path to TLS private-key PEM           (env: SEMAPHORE_KEY)
#       --chart-version VER Semaphore chart version to install    (env: SEMAPHORE_CHART_VERSION)
#                           (default: v1.5.0)
#       --chart-path  PATH  Path to a local Helm chart directory  (env: SEMAPHORE_CHART_PATH)
#                           Overrides --chart-version and the OCI reference.
#                           Run `helm dependency build <PATH>` before using this flag.
#       --k3s-version VER   k3s version to install                (env: SEMAPHORE_K3S_VERSION)
#                           (default: v1.32.13+k3s1)
#       --helm-version VER  Helm version to install               (env: SEMAPHORE_HELM_VERSION)
#                           (default: v3.17.1)
#       --namespace NS      Kubernetes namespace                   (default: semaphore)
#       --release REL       Helm release name                     (default: semaphore)
#       --skip-k3s          Skip k3s installation
#       --skip-helm         Skip Helm installation
#   -h, --help              Show this help and exit
#
# Prerequisites:
#   - Linux host with systemd (k3s requires systemd)
#   - curl and base64 installed
#   - Root or sudo privileges (k3s installer requires root)
#   - Outbound internet access (container images, k3s/Helm installers, OCI chart)
#   - A valid TLS certificate and private key for --domain
#
# What this script does:
#   1. Installs k3s in single-server mode (Traefik kept enabled for ingress)
#   2. Installs Helm if not already present
#   3. Runs `helm upgrade --install` using deploy/k3s/values.yaml
#   4. Waits for all Semaphore pods to become Ready, then lists all pods
#
# Examples:
#   # Minimal — pass secrets as env vars to avoid shell history exposure:
#   export SEMAPHORE_CERT=/etc/letsencrypt/live/ci.example.com/fullchain.pem
#   export SEMAPHORE_KEY=/etc/letsencrypt/live/ci.example.com/privkey.pem
#   sudo --preserve-env ./deploy/k3s/setup.sh \
#       --domain ci.example.com \
#       --ip    203.0.113.10 \
#       --email admin@example.com \
#       --name  "CI Admin"
#
#   # Explicit flags:
#   sudo ./deploy/k3s/setup.sh \
#       --domain ci.example.com --ip 203.0.113.10 \
#       --email admin@example.com --name "CI Admin" \
#       --cert /path/to/fullchain.pem --key /path/to/privkey.pem \
#       --chart-version v1.5.0

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths derived from the location of this script
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
K3S_INSTALL_URL="https://get.k3s.io"
# Helm installer is fetched at a pinned tag to ensure reproducibility.
# Update DEFAULT_HELM_VERSION when upgrading Helm.
HELM_INSTALL_URL="https://raw.githubusercontent.com/helm/helm/v3.17.1/scripts/get-helm-3"
SEMAPHORE_CHART_OCI="oci://ghcr.io/semaphoreio/semaphore"

DEFAULT_CHART_VERSION="v1.5.0"
# k3s v1.32.x ships Traefik v3 (replacing v2.11 in v1.31.x). This is required for
# stable Gateway API support and Traefik IngressRoute v3 CRD group (traefik.io/v1alpha1).
# Update when upgrading the Semaphore chart to a newer k3s-tested release.
DEFAULT_K3S_VERSION="v1.32.13+k3s1"
DEFAULT_HELM_VERSION="v3.17.1"
DEFAULT_NAMESPACE="semaphore"
DEFAULT_RELEASE="semaphore"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
log_warn()  { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2; }
log_error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }

die() { log_error "$*"; exit 1; }

# Print the header comment block as help text.
usage() {
  sed -n '/^# Usage:/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p }; /^[^#]/q }' \
    "${BASH_SOURCE[0]}"
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing — flags override env vars
# ---------------------------------------------------------------------------
DOMAIN="${SEMAPHORE_DOMAIN:-}"
IP="${SEMAPHORE_IP:-}"
EMAIL="${SEMAPHORE_EMAIL:-}"
ADMIN_NAME="${SEMAPHORE_NAME:-}"
CERT_FILE="${SEMAPHORE_CERT:-}"
KEY_FILE="${SEMAPHORE_KEY:-}"
CHART_VERSION="${SEMAPHORE_CHART_VERSION:-${DEFAULT_CHART_VERSION}}"
CHART_PATH="${SEMAPHORE_CHART_PATH:-}"
K3S_VERSION="${SEMAPHORE_K3S_VERSION:-${DEFAULT_K3S_VERSION}}"
HELM_VERSION="${SEMAPHORE_HELM_VERSION:-${DEFAULT_HELM_VERSION}}"
NAMESPACE="${DEFAULT_NAMESPACE}"
RELEASE="${DEFAULT_RELEASE}"
SKIP_K3S=false
SKIP_HELM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)        DOMAIN="$2";        shift 2 ;;
    -i|--ip)            IP="$2";            shift 2 ;;
    -e|--email)         EMAIL="$2";         shift 2 ;;
    -n|--name)          ADMIN_NAME="$2";    shift 2 ;;
    -c|--cert)          CERT_FILE="$2";     shift 2 ;;
    -k|--key)           KEY_FILE="$2";      shift 2 ;;
    --chart-version)    CHART_VERSION="$2"; shift 2 ;;
    --chart-path)       CHART_PATH="$2";    shift 2 ;;
    --k3s-version)      K3S_VERSION="$2";   shift 2 ;;
    --helm-version)     HELM_VERSION="$2";  shift 2 ;;
    --namespace)        NAMESPACE="$2";     shift 2 ;;
    --release)          RELEASE="$2";       shift 2 ;;
    --skip-k3s)         SKIP_K3S=true;      shift   ;;
    --skip-helm)        SKIP_HELM=true;     shift   ;;
    -h|--help)          usage               ;;
    *) die "Unknown option: $1  (use --help for usage)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate required arguments
# ---------------------------------------------------------------------------
[[ -n "${DOMAIN}"      ]] || die "--domain is required (or set SEMAPHORE_DOMAIN). Use --help."
[[ -n "${IP}"          ]] || die "--ip is required (or set SEMAPHORE_IP). Use --help."
[[ -n "${EMAIL}"       ]] || die "--email is required (or set SEMAPHORE_EMAIL). Use --help."
[[ -n "${ADMIN_NAME}"  ]] || die "--name is required (or set SEMAPHORE_NAME). Use --help."
[[ -n "${CERT_FILE}"   ]] || die "--cert is required (or set SEMAPHORE_CERT). Use --help."
[[ -n "${KEY_FILE}"    ]] || die "--key is required (or set SEMAPHORE_KEY). Use --help."

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
log_info "Checking prerequisites..."

command -v curl   &>/dev/null || die "curl is not installed."
command -v base64 &>/dev/null || die "base64 is not installed."

[[ -f "${VALUES_FILE}" ]] \
  || die "Values override file not found: ${VALUES_FILE}"

[[ -f "${CERT_FILE}" ]] \
  || die "TLS certificate file not found: ${CERT_FILE}"

[[ -f "${KEY_FILE}" ]] \
  || die "TLS private key file not found: ${KEY_FILE}"

# ---------------------------------------------------------------------------
# Step 1 — Install k3s (single-server; Traefik kept for ingress)
# ---------------------------------------------------------------------------
install_k3s() {
  log_info "Installing k3s ${K3S_VERSION} (single-server mode)..."
  # INSTALL_K3S_VERSION pins the exact release; without it the installer
  # fetches the latest stable, which is not reproducible across invocations.
  curl -sfL "${K3S_INSTALL_URL}" | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -
  log_info "Waiting up to 120 s for the k3s node to become Ready..."
  # kubectl wait filters by condition type directly — safer than JSONPath
  # on conditions[-1], whose order is not guaranteed by the API.
  kubectl wait --for=condition=Ready node --all --timeout=120s
  log_info "k3s node is Ready."
}

if "${SKIP_K3S}"; then
  log_info "Skipping k3s installation (--skip-k3s set)."
elif command -v k3s &>/dev/null && k3s --version &>/dev/null 2>&1; then
  log_info "k3s already installed: $(k3s --version | head -1). Skipping."
else
  install_k3s
fi

# Ensure KUBECONFIG is exported for kubectl/helm when running as root under k3s.
if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
  if [[ -n "${KUBECONFIG:-}" && "${KUBECONFIG}" != "/etc/rancher/k3s/k3s.yaml" ]]; then
    log_warn "KUBECONFIG is already set to '${KUBECONFIG}' (not the k3s config)."
    log_warn "kubectl and helm will target that cluster, not the local k3s node."
    log_warn "Unset KUBECONFIG or re-run with: KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
  elif [[ -z "${KUBECONFIG:-}" ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    log_info "KUBECONFIG set to /etc/rancher/k3s/k3s.yaml"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — Install Helm
# ---------------------------------------------------------------------------
install_helm() {
  log_info "Installing Helm ${HELM_VERSION}..."
  # DESIRED_VERSION pins the exact Helm release fetched by the installer script.
  curl -sfL "${HELM_INSTALL_URL}" | DESIRED_VERSION="${HELM_VERSION}" bash
  log_info "Helm installed: $(helm version --short)"
}

if "${SKIP_HELM}"; then
  log_info "Skipping Helm installation (--skip-helm set)."
elif command -v helm &>/dev/null && helm version &>/dev/null 2>&1; then
  log_info "Helm already installed: $(helm version --short). Skipping."
else
  install_helm
fi

# ---------------------------------------------------------------------------
# Step 3 — Ensure the target namespace exists (idempotent)
# ---------------------------------------------------------------------------
log_info "Ensuring namespace '${NAMESPACE}' exists..."
if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  log_info "Namespace '${NAMESPACE}' already exists."
else
  kubectl create namespace "${NAMESPACE}"
  log_info "Namespace '${NAMESPACE}' created."
fi

# ---------------------------------------------------------------------------
# Step 4 — Base64-encode TLS certificate and key
# ---------------------------------------------------------------------------
log_info "Encoding TLS certificate and key..."
# tr -d '\n' strips the line breaks that both GNU and BSD base64 insert,
# producing the single-line value that Helm --set requires.
TLS_CRT="$(base64 < "${CERT_FILE}" | tr -d '\n')"
TLS_KEY="$(base64 < "${KEY_FILE}"  | tr -d '\n')"

# ---------------------------------------------------------------------------
# Step 5 — Install or upgrade Semaphore CE via Helm (idempotent)
# ---------------------------------------------------------------------------
log_info "Deploying Semaphore CE..."
log_info "  Release       : ${RELEASE}"
log_info "  Namespace     : ${NAMESPACE}"

# Resolve chart reference: local path overrides OCI + version.
if [[ -n "${CHART_PATH}" ]]; then
  [[ -d "${CHART_PATH}" ]] \
    || die "Chart path does not exist or is not a directory: ${CHART_PATH}"

  # The monorepo chart directory uses file:// sub-chart dependencies that require
  # every service to have a generated Chart.yaml — not available on a fresh clone.
  # Strategy: pull the published OCI chart (all deps already vendored), then
  # overlay templates/ from the local path and patch Chart.yaml to add the
  # emissary-ingress condition.  This gives us a fully functional chart directory
  # without needing to run prepare-chart.sh or yq/jq.
  PATCHED_DIR="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${PATCHED_DIR}'" EXIT

  log_info "Pulling base chart ${SEMAPHORE_CHART_OCI} ${CHART_VERSION} for template patching..."
  helm pull "${SEMAPHORE_CHART_OCI}" \
    --version "${CHART_VERSION}" \
    --untar \
    --untardir "${PATCHED_DIR}"

  CHART_BASE="${PATCHED_DIR}/semaphore"

  [[ -d "${CHART_BASE}" ]] \
    || die "helm pull succeeded but chart directory '${PATCHED_DIR}/semaphore' not found"

  # Overlay templates from the local chart path.
  log_info "Applying local templates from ${CHART_PATH}/templates/ ..."
  cp -r "${CHART_PATH}/templates/." "${CHART_BASE}/templates/"

  # Patch Chart.yaml: add 'condition: emissary-ingress.enabled' to the
  # emissary-ingress dependency so that setting enabled: false in values
  # disables the subchart.  awk inserts the condition line after the
  # 'repository:' line for that dependency (all indented 4 spaces).
  awk '
    /^  - name: emissary-ingress/ { in_dep=1 }
    in_dep && /^    repository:/ {
      print
      print "    condition: emissary-ingress.enabled"
      in_dep=0
      next
    }
    { print }
  ' "${CHART_BASE}/Chart.yaml" > "${CHART_BASE}/Chart.yaml.tmp"
  mv "${CHART_BASE}/Chart.yaml.tmp" "${CHART_BASE}/Chart.yaml"

  CHART_REF="${CHART_BASE}"
  log_info "  Chart         : patched OCI ${CHART_VERSION} + local templates"
  HELM_VERSION_FLAG=()
else
  CHART_REF="${SEMAPHORE_CHART_OCI}"
  log_info "  Chart version : ${CHART_VERSION}"
  HELM_VERSION_FLAG=(--version "${CHART_VERSION}")
fi

# If a previous install attempt left a failed or pending-* release, the stored
# manifest may reference CRD resources that no longer exist (e.g. Emissary types
# from an earlier run with the unguarded chart).  Helm's three-way merge cannot
# build those objects even if the new templates no longer emit them, causing:
#   "unable to build kubernetes objects from release manifest: no matches for kind X"
# Uninstall the stale release first so the next run starts from a clean slate.
# grep exits 1 (no match) when there is no existing release; || true prevents
# that from aborting the script under set -eo pipefail.
HELM_STATUS="$(helm status "${RELEASE}" -n "${NAMESPACE}" -o json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//' || true)"
if [[ "${HELM_STATUS}" == failed || "${HELM_STATUS}" == pending* ]]; then
  log_warn "Found a ${HELM_STATUS} Helm release '${RELEASE}' — uninstalling stale release before fresh install..."
  helm uninstall "${RELEASE}" -n "${NAMESPACE}" || true
fi

log_info "  Domain        : ${DOMAIN}"
log_info "  IP            : ${IP}"
log_info "  Admin email   : ${EMAIL}"
log_info "  Admin name    : ${ADMIN_NAME}"
log_info "  Values file   : ${VALUES_FILE}"

# ${HELM_VERSION_FLAG[@]+...} guard: bash treats an empty array as unset under
# set -u; the parameter expansion only expands the array when it is non-empty.
helm upgrade --install "${RELEASE}" "${CHART_REF}" \
  ${HELM_VERSION_FLAG[@]+"${HELM_VERSION_FLAG[@]}"} \
  --namespace "${NAMESPACE}" \
  -f "${VALUES_FILE}" \
  --set "global.domain.name=${DOMAIN}" \
  --set "global.domain.ip=${IP}" \
  --set "global.rootUser.email=${EMAIL}" \
  --set "global.rootUser.name=${ADMIN_NAME}" \
  --set-string "ingress.ssl.crt=${TLS_CRT}" \
  --set-string "ingress.ssl.key=${TLS_KEY}" \
  --timeout 30m \
  --wait

log_info "Helm upgrade/install completed successfully."

# ---------------------------------------------------------------------------
# Step 6 — Post-install verification
# ---------------------------------------------------------------------------
log_info "Waiting for Semaphore pods to become Ready (up to 5 min)..."
# Wait for all pods labelled product=semaphoreci to be Ready. This is a
# meaningful check — it fails fast if any pod is in CrashLoopBackOff,
# unlike a bare `kubectl get pods` which always exits 0.
kubectl wait \
  --for=condition=Ready pod \
  -l product=semaphoreci \
  -n "${NAMESPACE}" \
  --timeout=300s

log_info "Post-install pod listing (all namespaces):"
kubectl get pods -A

log_info "------------------------------------------------------------"
log_info "Semaphore CE is installed."
log_info "  URL       : https://${DOMAIN}"
log_info "  Namespace : ${NAMESPACE}"
log_info "  Release   : ${RELEASE}"
log_info ""
log_info "Useful commands:"
log_info "  kubectl get pods -n ${NAMESPACE}"
log_info "  helm status ${RELEASE} -n ${NAMESPACE}"
log_info "  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=bootstrapper"
log_info "------------------------------------------------------------"
