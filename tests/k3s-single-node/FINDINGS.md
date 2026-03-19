# Test Findings: k3s Single-Node Helm Values and Setup Script

**Files under test:**
- `deploy/k3s/values.yaml`
- `deploy/k3s/setup.sh`

**Test script:** `tests/k3s-single-node/test-validate.sh`

**Execution method:** Manual via Grep/Read (Bash execution unavailable during test run).
**Helm rendering tests (T-RENDER-*):** Skipped — require `make docker.build` in `helm-chart/`.
**shellcheck (T-SCRIPT-07):** Skipped — requires Bash execution.

---

## Summary

| Category | Total | Pass | Fail | Skip |
|----------|-------|------|------|------|
| Values file (T-VALUES-*) | 12 | 12 | 0 | 0 |
| Setup script (T-SCRIPT-*) | 20 | 19 | 0 | 1 |
| Cross-file (T-CROSS-*) | 6 | 5 | 1 | 0 |
| Helm rendering (T-RENDER-*) | 8 | — | — | 8 |
| **Total** | **46** | **36** | **1** | **9** |

---

## Failures

### T-CROSS-05a — FAIL (Low severity — documentation bug)

**Finding:** The `deploy/k3s/values.yaml` usage comment (lines 12–13) instructs operators to use
`--set ingress.ssl.crt=...` and `--set ingress.ssl.key=...` when doing a manual Helm install.
The `deploy/k3s/setup.sh` script correctly uses `--set-string` for those values.

**Why it matters:** Helm's `--set` performs type inference. A base64 string that happens to be
all-numeric, match a boolean literal (`true`/`false`), or begin with special characters could be
coerced to a non-string type, producing a silently wrong or empty TLS Secret. `--set-string`
forces the string type and is the correct form. Operators who copy the example from the values
comment will hit this on unlucky cert values.

**Fix needed:** Update the usage comment in `deploy/k3s/values.yaml` lines 12–13 to use
`--set-string` instead of `--set` for `ingress.ssl.crt` and `ingress.ssl.key`.

---

## Skipped Tests

### T-SCRIPT-07 — shellcheck (requires Bash)

Unable to run `shellcheck deploy/k3s/setup.sh` during this test run. This is the highest-priority
pending check. Run manually:

```sh
shellcheck deploy/k3s/setup.sh
```

Known potential shellcheck findings (from reading the script):
- Line 170: `curl -sfL ... | INSTALL_K3S_VERSION="..." sh -` — inline env var before piped `sh` is
  valid bash but shellcheck SC2031 may flag the variable as not exported. This is intentional and
  correct; a `# shellcheck disable=SC2031` comment may be needed.
- Line 204: `curl -sfL ... | DESIRED_VERSION="..." bash` — same pattern.

### T-RENDER-01 through T-RENDER-08 — Helm rendering (requires Docker image)

To run:
```sh
cd helm-chart
make docker.build
cd ..
bash tests/k3s-single-node/test-validate.sh
```

These tests validate that:
- `helm template` exits 0 with the override applied
- No GCE resources (FrontendConfig, BackendConfig) are rendered
- TLS Secret is rendered for `ingress.ssl.type=custom`
- No EE-only Mappings appear in CE render
- Traefik annotation appears on the Ingress
- `helm template` correctly fails when `global.domain.name` is absent

---

## Confirmed Correct (Key Properties)

The following properties of the delivered artifacts were verified against specification:

1. **Ingress class is Traefik** — `ingress.className: "traefik"` (not `"gce"`).

2. **SSL type is custom** — produces a `kubernetes.io/tls` TLS Secret; no Google-managed cert
   annotation; no `kind: FrontendConfig` or `kind: BackendConfig` GCE resources.

3. **emissary-ingress name overrides** — `nameOverride: ambassador`, `fullnameOverride: ambassador`,
   `service.nameOverride: "ambassador"` all present. Without these the Ingress backend
   (`service.name: ambassador`) would not resolve and every inbound request would return 503.

4. **waitForApiext.enabled: false** — prevents helm install from hanging on k3s where the CRDs
   are pre-installed manually.

5. **GCE annotations cleared** — `annotations: {}` on the emissary service nulls out the
   `cloud.google.com/backend-config` and `cloud.google.com/neg` defaults from `values.yaml.in`.

6. **Edition is ce** — `global.edition: "ce"` stated explicitly to guard against accidental
   EE subchart activation.

7. **No credentials in VCS** — `crt`, `key`, `domain.ip`, `domain.name`, `rootUser.email`,
   `rootUser.name` are all empty placeholders.

8. **set -euo pipefail** — strict error handling throughout the script.

9. **All required variable guards** — six variables checked with `[[ -n ... ]] || die` before
   any use, producing clear error messages before any work is done.

10. **Prerequisite checks** — `curl` and `base64` verified via `command -v` before use.

11. **Cert file guards** — `[[ -f "${CERT_FILE}" ]]` and `[[ -f "${KEY_FILE}" ]]` checked
    before `base64` reads them; missing files produce a clear `die` message.

12. **Portable base64** — `base64 < file | tr -d '\n'` used (not GNU-only `base64 -w 0`);
    works on both Ubuntu/Debian and macOS/BSD systems.

13. **No double base64 encoding** — script encodes once; template uses `data:` + `| quote`
    (not `| b64enc`), so the pre-encoded value is expected and correct.

14. **--set-string for TLS values** — prevents Helm type coercion of cert data.

15. **Version-pinned installers** — k3s (`INSTALL_K3S_VERSION`) and Helm (`DESIRED_VERSION`)
    are pinned, making installs reproducible.

16. **KUBECONFIG conflict detection** — if `KUBECONFIG` is already set to a different cluster,
    the script logs a warning instead of silently targeting the wrong cluster.

17. **Meaningful post-install smoke test** — `kubectl wait --for=condition=Ready pod
    -l product=semaphoreci` fails fast on pod crashes; a bare `get pods` would always exit 0.

18. **Idempotent helm command** — `helm upgrade --install` (not `helm install`).

19. **Consistent namespace** — `--namespace "${NAMESPACE}"` on the helm command; the namespace
    variable defaults to `semaphore` and is honoured throughout.

20. **emissary CRD version consistent** — `3.9.1` in both `values.yaml` prerequisite comment
    and `setup.sh` constant.

---

## Recommendations to Surgeon

**Required fix (blocks correctness for manual operators):**
- Update `deploy/k3s/values.yaml` lines 12–13: change `--set ingress.ssl.crt=` and
  `--set ingress.ssl.key=` to `--set-string ingress.ssl.crt=` and
  `--set-string ingress.ssl.key=` in the usage comment.

**Recommended actions:**
- Run `shellcheck deploy/k3s/setup.sh` and address any findings before merge.
- Run `make docker.build && bash tests/k3s-single-node/test-validate.sh` in `helm-chart/`
  to execute the T-RENDER-* Helm rendering tests.
- Consider adding a `# shellcheck disable=SC2031` comment on the inline-env-var pipe lines
  (170 and 204) if shellcheck flags them, with an explanatory note.
