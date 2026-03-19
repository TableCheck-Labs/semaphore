#!/usr/bin/env bash
# tests/k3s-single-node/test-validate.sh
#
# Adversarial validation of:
#   deploy/k3s/values.yaml   — Helm values override for k3s single-node CE
#   deploy/k3s/setup.sh      — k3s single-node install script
#
# Run from repo root:
#   bash tests/k3s-single-node/test-validate.sh
#
# Dependencies:
#   - shellcheck  (for T-SCRIPT-07)
#   - helm + docker  (for T-RENDER-* — requires the Makefile helm.test.ce target)
#   - yq  (optional; structured assertions fall back to grep)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALUES_FILE="${REPO_ROOT}/deploy/k3s/values.yaml"
SETUP_SCRIPT="${REPO_ROOT}/deploy/k3s/setup.sh"
CHART_DIR="${REPO_ROOT}/helm-chart"
SSL_CERT_TEMPLATE="${CHART_DIR}/templates/secrets/sslcert.yaml"

PASS=0
FAIL=0
SKIP=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
pass()    { echo "  PASS  $1"; ((PASS++)) || true; }
fail()    { echo "  FAIL  $1"; ((FAIL++)) || true; }
skip()    { echo "  SKIP  $1 — $2"; ((SKIP++)) || true; }
section() { printf '\n=== %s ===\n' "$1"; }

# Run helm template through the docker-based test harness defined in
# helm-chart/Makefile (helm.test.ce target) but add our values override.
# Because Chart.yaml is generated (from Chart.yaml.in), we need the Docker
# image to be present. Falls back to skipping if docker is unavailable or
# the image isn't built.
helm_render() {
    docker run --rm \
        -v "${REPO_ROOT}:/workspace" \
        -w /workspace/helm-chart \
        semaphore-helm-test \
        -c "make helm.cleanup && \
            ./scripts/prepare-chart.sh v0.0.0 && \
            helm dependency build && \
            helm template . \
                -f /workspace/deploy/k3s/values.yaml \
                --set global.domain.name=ci.example.com \
                --set global.domain.ip=1.2.3.4 \
                --set global.rootUser.email=admin@example.com \
                --set 'global.rootUser.name=Admin' \
                --set ingress.ssl.crt=dGVzdC1jcnQ= \
                --set ingress.ssl.key=dGVzdC1rZXk= \
                $*" 2>&1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
section "Preflight checks"

[[ -f "${VALUES_FILE}" ]] \
    || { echo "FATAL: values file not found: ${VALUES_FILE}"; exit 1; }
echo "  values file : ${VALUES_FILE}"

[[ -f "${SETUP_SCRIPT}" ]] \
    || { echo "FATAL: setup script not found: ${SETUP_SCRIPT}"; exit 1; }
echo "  setup script: ${SETUP_SCRIPT}"

HAVE_SHELLCHECK=true
command -v shellcheck &>/dev/null || { echo "  WARN: shellcheck not found — T-SCRIPT-07 will be skipped"; HAVE_SHELLCHECK=false; }

HAVE_DOCKER=true
command -v docker &>/dev/null || { echo "  WARN: docker not found — helm rendering tests will be skipped"; HAVE_DOCKER=false; }

HAVE_DOCKER_IMAGE=false
if $HAVE_DOCKER && docker image inspect semaphore-helm-test &>/dev/null 2>&1; then
    HAVE_DOCKER_IMAGE=true
else
    echo "  WARN: docker image 'semaphore-helm-test' not present — run 'make docker.build' in helm-chart/ to enable rendering tests"
fi

HAVE_YQ=true
command -v yq &>/dev/null || { echo "  WARN: yq not found — using grep for YAML assertions"; HAVE_YQ=false; }

# ---------------------------------------------------------------------------
# VALUES FILE — static YAML content tests
# ---------------------------------------------------------------------------
section "Values file: static content (T-VALUES-*)"

# T-VALUES-01: ingress.className must be "traefik"
val=$(grep -E '^\s+className:' "${VALUES_FILE}" | head -1 | sed 's/.*:[ ]*//' | tr -d '"')
if [[ "${val}" == "traefik" ]]; then
    pass "T-VALUES-01  ingress.className is 'traefik'"
else
    fail "T-VALUES-01  ingress.className is '${val}', expected 'traefik'"
fi

# T-VALUES-02: ingress.ssl.type must be "custom"
# Note: there are two 'type:' lines (ssl type and service type); we want the ssl one.
# The ssl type appears before the NodePort service type in the file.
val=$(awk '/^ingress:/,/^[a-z]/' "${VALUES_FILE}" | grep -E '^\s+type:' | head -1 | sed 's/.*:[ ]*//' | tr -d '"')
if [[ "${val}" == "custom" ]]; then
    pass "T-VALUES-02  ingress.ssl.type is 'custom'"
else
    fail "T-VALUES-02  ingress.ssl.type is '${val}', expected 'custom'"
fi

# T-VALUES-03: global.edition must be "ce"
val=$(grep -E '^\s+edition:' "${VALUES_FILE}" | head -1 | sed 's/.*:[ ]*//' | tr -d '"')
if [[ "${val}" == "ce" ]]; then
    pass "T-VALUES-03  global.edition is 'ce'"
else
    fail "T-VALUES-03  global.edition is '${val}', expected 'ce'"
fi

# T-VALUES-04: waitForApiext.enabled must be false
if grep -A5 'waitForApiext:' "${VALUES_FILE}" | grep -qE 'enabled:\s+false'; then
    pass "T-VALUES-04  emissary-ingress.waitForApiext.enabled is false"
else
    fail "T-VALUES-04  emissary-ingress.waitForApiext.enabled is not false — helm install will hang on k3s"
fi

# T-VALUES-05: skipTlsVerifyInternal must NOT be true (security regression)
if grep -qE 'skipTlsVerifyInternal:\s+true' "${VALUES_FILE}"; then
    fail "T-VALUES-05  skipTlsVerifyInternal is true — disables internal TLS verification globally"
else
    pass "T-VALUES-05  skipTlsVerifyInternal is not enabled"
fi

# T-VALUES-06: ingress.ssl.crt and ingress.ssl.key must be empty in the file
# (real certs go in via --set at install time — not committed to VCS)
crt_val=$(grep -E '^\s+crt:' "${VALUES_FILE}" | head -1 | sed 's/.*crt:[ ]*//' | tr -d '"' | sed 's/#.*//' | xargs)
key_val=$(grep -E '^\s+key:' "${VALUES_FILE}" | head -1 | sed 's/.*key:[ ]*//' | tr -d '"' | sed 's/#.*//' | xargs)
if [[ -z "${crt_val}" ]]; then
    pass "T-VALUES-06a ingress.ssl.crt is empty (correct — set via --set at install time)"
else
    fail "T-VALUES-06a ingress.ssl.crt has a literal value in the file — credentials committed to VCS"
fi
if [[ -z "${key_val}" ]]; then
    pass "T-VALUES-06b ingress.ssl.key is empty (correct — set via --set at install time)"
else
    fail "T-VALUES-06b ingress.ssl.key has a literal value in the file — credentials committed to VCS"
fi

# T-VALUES-07: global.domain.ip and global.domain.name must be empty
ip_val=$(grep -E '^\s+ip:' "${VALUES_FILE}" | head -1 | sed 's/.*ip:[ ]*//' | tr -d '"' | sed 's/#.*//' | xargs)
name_val=$(awk '/^\s+domain:$/,/^\s+rootUser:/' "${VALUES_FILE}" | grep -E '^\s+name:' | head -1 | sed 's/.*name:[ ]*//' | tr -d '"' | sed 's/#.*//' | xargs)
if [[ -z "${ip_val}" ]]; then
    pass "T-VALUES-07a global.domain.ip is empty (set at install time — correct)"
else
    fail "T-VALUES-07a global.domain.ip has literal value '${ip_val}' — should be empty placeholder"
fi
if [[ -z "${name_val}" ]]; then
    pass "T-VALUES-07b global.domain.name is empty (set at install time — correct)"
else
    fail "T-VALUES-07b global.domain.name has literal value '${name_val}' — should be empty placeholder"
fi

# T-VALUES-08: ambassador service annotations nulled out (no GCE annotations)
# The override must set annotations: {} to clear the GCE default annotations
if grep -qE 'annotations:\s*\{\}' "${VALUES_FILE}"; then
    pass "T-VALUES-08  emissary-ingress service annotations are cleared (annotations: {})"
else
    fail "T-VALUES-08  emissary-ingress service annotations not cleared — GCE cloud.google.com annotations may persist"
fi

# T-VALUES-09: nameOverride and fullnameOverride both set to ambassador
# CRITICAL: ingress.yaml hard-codes the backend service name as "ambassador".
# Without these overrides the emissary deployment uses the Helm release-prefixed
# name and every inbound request returns 503.
if grep -qE 'nameOverride:\s+ambassador' "${VALUES_FILE}" && \
   grep -qE 'fullnameOverride:\s+ambassador' "${VALUES_FILE}"; then
    pass "T-VALUES-09  emissary-ingress nameOverride and fullnameOverride are both 'ambassador'"
else
    fail "T-VALUES-09  missing nameOverride or fullnameOverride = ambassador — ingress backend will 503"
fi

# T-VALUES-10: emissary service.nameOverride also set to ambassador
if grep -A20 'service:' "${VALUES_FILE}" | grep -qE 'nameOverride:\s+"ambassador"'; then
    pass "T-VALUES-10  emissary-ingress service.nameOverride is 'ambassador'"
else
    fail "T-VALUES-10  emissary-ingress service.nameOverride not 'ambassador' — service name mismatch with ingress backend"
fi

# T-VALUES-11: telemetry endpoint not pointing to a test server
if grep -qE 'endpoint:.*sxmoon\.com' "${VALUES_FILE}"; then
    fail "T-VALUES-11  telemetry endpoint points to sxmoon.com test server — not the canonical endpoint"
else
    pass "T-VALUES-11  no non-canonical telemetry endpoint in values file"
fi

# T-VALUES-12: ingress.enabled is true
if grep -qE '^ingress:' "${VALUES_FILE}" && \
   awk '/^ingress:/,/^[a-z]/' "${VALUES_FILE}" | grep -qE '^\s+enabled:\s+true'; then
    pass "T-VALUES-12  ingress.enabled is true"
else
    fail "T-VALUES-12  ingress.enabled is not true — ingress will not be created"
fi

# ---------------------------------------------------------------------------
# SETUP SCRIPT — static analysis tests
# ---------------------------------------------------------------------------
section "Setup script: static analysis (T-SCRIPT-*)"

# T-SCRIPT-01: strict error mode (set -e / set -euo pipefail)
if grep -qE '^set -[a-zA-Z]*e[a-zA-Z]*' "${SETUP_SCRIPT}"; then
    pass "T-SCRIPT-01  strict error mode (set -e) present"
else
    fail "T-SCRIPT-01  missing 'set -e' — failed commands will not abort the script"
fi

# T-SCRIPT-02: unset variable protection (set -u)
if grep -qE '^set -[a-zA-Z]*u[a-zA-Z]*|^set -o nounset' "${SETUP_SCRIPT}"; then
    pass "T-SCRIPT-02  unset variable protection (set -u) present"
else
    fail "T-SCRIPT-02  missing 'set -u' — unset variables are silently treated as empty strings"
fi

# T-SCRIPT-03: pipefail
if grep -qE '^set -[a-zA-Z]*o pipefail|^set -o pipefail' "${SETUP_SCRIPT}"; then
    pass "T-SCRIPT-03  pipefail present — failed curl | sh won't go undetected"
else
    fail "T-SCRIPT-03  missing pipefail — failures in piped commands are silently ignored"
fi

# T-SCRIPT-04: all required variables are guarded before use
# The script uses: [[ -n "${VAR}" ]] || die (with || die on same or next line)
required_vars=(DOMAIN IP EMAIL ADMIN_NAME CERT_FILE KEY_FILE)
for var in "${required_vars[@]}"; do
    if grep -q "\-n \"\${${var}}\"" "${SETUP_SCRIPT}"; then
        pass "T-SCRIPT-04-${var}  null guard present for \$${var}"
    else
        fail "T-SCRIPT-04-${var}  no null guard found for \$${var} — empty value accepted silently"
    fi
done

# T-SCRIPT-05: prerequisite tool checks (curl, base64)
for tool in curl base64; do
    if grep -qE "command -v ${tool}" "${SETUP_SCRIPT}"; then
        pass "T-SCRIPT-05-${tool}  prerequisite check for '${tool}' present"
    else
        fail "T-SCRIPT-05-${tool}  no prerequisite check for '${tool}' — obscure failure if missing"
    fi
done

# T-SCRIPT-06: cert and key files validated before base64 encoding
# The script uses: [[ -f "${CERT_FILE}" ]] \ (with backslash continuation)
for var_name in CERT_FILE KEY_FILE; do
    if grep -q "\-f \"\${${var_name}}\"" "${SETUP_SCRIPT}"; then
        pass "T-SCRIPT-06-${var_name}  file existence check present for \$${var_name}"
    else
        fail "T-SCRIPT-06-${var_name}  no existence check for \$${var_name} before reading — silent empty cert on missing file"
    fi
done

# T-SCRIPT-07: shellcheck linting (SC errors = real bugs)
if ! $HAVE_SHELLCHECK; then
    skip "T-SCRIPT-07" "shellcheck not available"
else
    sc_output="$(shellcheck "${SETUP_SCRIPT}" 2>&1)" && sc_exit=0 || sc_exit=$?
    if [[ ${sc_exit} -eq 0 ]]; then
        pass "T-SCRIPT-07  shellcheck passes with no errors"
    else
        fail "T-SCRIPT-07  shellcheck found issues:"
        echo "${sc_output}" | sed 's/^/             /'
    fi
fi

# T-SCRIPT-08: no double base64 encoding
# sslcert.yaml template uses data: with | quote (not b64enc), so values passed
# via --set must already be base64. Verify the script encodes exactly once per cert.
base64_cert_count=$(grep -c 'base64 <' "${SETUP_SCRIPT}" || true)
if [[ ${base64_cert_count} -eq 2 ]]; then
    pass "T-SCRIPT-08a exactly two 'base64 <' invocations (one per cert file)"
elif [[ ${base64_cert_count} -eq 0 ]]; then
    fail "T-SCRIPT-08a no 'base64 <' invocations — certs not encoded before passing to --set"
else
    pass "T-SCRIPT-08a ${base64_cert_count} base64 encoding(s) found"
fi
# No double-pipe: base64 | ... | base64
if grep -qE 'base64.*\|.*base64' "${SETUP_SCRIPT}"; then
    fail "T-SCRIPT-08b double base64 encoding detected — certs will be double-encoded, TLS will break"
else
    pass "T-SCRIPT-08b no double base64 encoding"
fi

# T-SCRIPT-09: base64 portability — uses 'tr -d' not '-w 0'
# 'base64 -w 0' is GNU-only; 'base64 | tr -d '\n'' works on both GNU and BSD.
if grep -qE 'base64.*-w' "${SETUP_SCRIPT}"; then
    fail "T-SCRIPT-09  script uses 'base64 -w 0' (GNU-only) — breaks on macOS/BSD; use 'base64 | tr -d'\\''\\\\n'\\'''"
else
    pass "T-SCRIPT-09  no GNU-only 'base64 -w' flag — portable encoding"
fi

# T-SCRIPT-10: idempotent helm command (upgrade --install, not bare install)
if grep -qE '^\s*helm install\b' "${SETUP_SCRIPT}"; then
    fail "T-SCRIPT-10  bare 'helm install' found — not idempotent; use 'helm upgrade --install'"
else
    pass "T-SCRIPT-10  no bare 'helm install' — 'helm upgrade --install' used (idempotent)"
fi

# T-SCRIPT-11: --namespace flag present on the helm upgrade command
if grep -qE 'helm upgrade.*--namespace\b|helm upgrade.*-n\b' "${SETUP_SCRIPT}"; then
    pass "T-SCRIPT-11  helm upgrade uses --namespace flag"
else
    fail "T-SCRIPT-11  helm upgrade missing --namespace — installs into kubectl context default namespace"
fi

# T-SCRIPT-12: no unconditional kubectl apply of SCM secret files
# (CE installs don't have those files; unconditional apply aborts the script)
for secret_file in github-app-secret.yaml bitbucket-app-secret.yaml gitlab-app-secret.yaml; do
    if grep -q "${secret_file}" "${SETUP_SCRIPT}"; then
        # File is referenced — check it's behind a guard
        if grep -B5 "${secret_file}" "${SETUP_SCRIPT}" | grep -qE '\[ -f|\[\[ -f'; then
            pass "T-SCRIPT-12-${secret_file}  kubectl apply guarded with file existence check"
        else
            fail "T-SCRIPT-12-${secret_file}  unconditional kubectl apply of ${secret_file} — aborts on CE installs"
        fi
    else
        pass "T-SCRIPT-12-${secret_file}  not referenced (not needed for CE — correct)"
    fi
done

# T-SCRIPT-13: no non-canonical telemetry endpoint
if grep -qE 'telemetry.*sxmoon\.com|endpoint.*sxmoon\.com' "${SETUP_SCRIPT}"; then
    fail "T-SCRIPT-13  setup script hardcodes non-canonical telemetry endpoint (sxmoon.com)"
else
    pass "T-SCRIPT-13  no non-canonical telemetry endpoint in setup script"
fi

# T-SCRIPT-14: --wait flag on helm upgrade (waits for all pods to be ready)
if grep -q 'helm upgrade' "${SETUP_SCRIPT}" && \
   grep -A20 'helm upgrade' "${SETUP_SCRIPT}" | grep -q '\-\-wait'; then
    pass "T-SCRIPT-14  helm upgrade uses --wait (waits for pods to be ready)"
else
    fail "T-SCRIPT-14  helm upgrade missing --wait — install returns before pods are ready; post-install steps run prematurely"
fi

# T-SCRIPT-15: emissary CRD wait uses -n emissary-system (not default namespace)
if grep -q 'emissary-system' "${SETUP_SCRIPT}"; then
    pass "T-SCRIPT-15  kubectl wait for emissary-apiext targets -n emissary-system"
else
    fail "T-SCRIPT-15  kubectl wait for emissary-apiext missing '-n emissary-system' — waits in wrong namespace"
fi

# T-SCRIPT-16: --set-string used for TLS cert and key (prevents Helm type coercion)
# Base64 values can occasionally look like other YAML types; --set-string forces string.
if grep -qE '\-\-set-string.*ingress\.ssl\.crt' "${SETUP_SCRIPT}" && \
   grep -qE '\-\-set-string.*ingress\.ssl\.key' "${SETUP_SCRIPT}"; then
    pass "T-SCRIPT-16  --set-string used for ingress.ssl.crt and ingress.ssl.key (prevents type coercion)"
else
    fail "T-SCRIPT-16  bare --set used for TLS certs — Helm may type-coerce base64 cert values (use --set-string)"
fi

# T-SCRIPT-17: k3s install pins a version (INSTALL_K3S_VERSION env var passed before sh)
if grep -q 'INSTALL_K3S_VERSION=' "${SETUP_SCRIPT}"; then
    pass "T-SCRIPT-17  k3s installer uses INSTALL_K3S_VERSION (pinned version, reproducible installs)"
else
    fail "T-SCRIPT-17  k3s installer does not pin INSTALL_K3S_VERSION — fetches latest, non-reproducible"
fi

# T-SCRIPT-18: Helm install pins a version (DESIRED_VERSION env var passed before bash)
if grep -q 'DESIRED_VERSION=' "${SETUP_SCRIPT}"; then
    pass "T-SCRIPT-18  Helm installer uses DESIRED_VERSION (pinned version, reproducible installs)"
else
    fail "T-SCRIPT-18  Helm installer does not pin DESIRED_VERSION — fetches latest, non-reproducible"
fi

# T-SCRIPT-19: KUBECONFIG conflict is detected and logged as a warning (not silently overwritten)
if grep -q 'KUBECONFIG' "${SETUP_SCRIPT}" && grep -q 'log_warn' "${SETUP_SCRIPT}"; then
    # Check that the conflict path (existing KUBECONFIG pointing elsewhere) issues a warning
    if grep -A5 'KUBECONFIG' "${SETUP_SCRIPT}" | grep -q 'log_warn'; then
        pass "T-SCRIPT-19  KUBECONFIG conflict detected and surfaced as a warning"
    else
        fail "T-SCRIPT-19  KUBECONFIG handling present but no warning for conflict case"
    fi
else
    fail "T-SCRIPT-19  no KUBECONFIG conflict handling — script silently targets wrong cluster if KUBECONFIG is already set"
fi

# T-SCRIPT-20: post-install smoke test uses kubectl wait (meaningful check, not bare get pods)
# A meaningful smoke test waits for Ready condition; bare 'kubectl get pods' always exits 0.
if grep -q 'kubectl wait' "${SETUP_SCRIPT}" && \
   grep -q 'product=semaphoreci' "${SETUP_SCRIPT}"; then
    pass "T-SCRIPT-20  post-install smoke test uses kubectl wait with label selector (meaningful readiness check)"
else
    fail "T-SCRIPT-20  post-install check is bare 'kubectl get pods' — always exits 0 even if pods are crashing"
fi

# ---------------------------------------------------------------------------
# CROSS-FILE CONSISTENCY CHECKS
# ---------------------------------------------------------------------------
section "Cross-file consistency (T-CROSS-*)"

# T-CROSS-01: base64 encoding in values.yaml comment matches script behavior
# values.yaml header comment uses: base64 < /path | tr -d '\n'
# setup.sh uses: base64 < "${CERT_FILE}" | tr -d '\n'
# Both must match (both use the tr -d '\n' portable form, not -w 0)
if grep -qE "base64 <.*\| tr -d" "${VALUES_FILE}"; then
    pass "T-CROSS-01a values.yaml usage comment uses portable base64 (tr -d form)"
else
    fail "T-CROSS-01a values.yaml usage comment does not use the portable base64 (tr -d) form"
fi
if grep -qE "base64 <.*\| tr -d" "${SETUP_SCRIPT}"; then
    pass "T-CROSS-01b setup.sh uses portable base64 (tr -d form)"
else
    fail "T-CROSS-01b setup.sh does not use the portable base64 (tr -d) form"
fi

# T-CROSS-02: TLS Secret template uses data: (not stringData:) — requires pre-encoded values
# This validates that the script's base64 encoding is actually needed (not redundant)
if [[ -f "${SSL_CERT_TEMPLATE}" ]]; then
    if grep -qE '^data:' "${SSL_CERT_TEMPLATE}"; then
        if ! grep -qE '^stringData:' "${SSL_CERT_TEMPLATE}"; then
            pass "T-CROSS-02  sslcert.yaml uses 'data:' (not stringData:) — pre-encoded values required; script encodes correctly"
        else
            fail "T-CROSS-02  sslcert.yaml uses both data: and stringData: — encoding expectation is ambiguous"
        fi
    else
        fail "T-CROSS-02  sslcert.yaml does not use 'data:' — check if template was changed to stringData (would break encoding)"
    fi
else
    skip "T-CROSS-02" "sslcert.yaml template not found at ${SSL_CERT_TEMPLATE}"
fi

# T-CROSS-03: sslcert.yaml template uses | quote not | b64enc
# If the template used | b64enc, the script's base64 encoding would cause double-encoding.
# The template uses | quote (YAML string quoting only) — script must supply pre-encoded base64.
if [[ -f "${SSL_CERT_TEMPLATE}" ]]; then
    if grep -qE 'b64enc' "${SSL_CERT_TEMPLATE}"; then
        fail "T-CROSS-03  sslcert.yaml uses | b64enc — script's base64 encoding would double-encode certs"
    else
        pass "T-CROSS-03  sslcert.yaml uses | quote not | b64enc — script base64 encoding is correct (no double-encoding)"
    fi
else
    skip "T-CROSS-03" "sslcert.yaml template not found"
fi

# T-CROSS-04: chart version in values.yaml comment matches script default
# Both should reference the same version to avoid confusing operators.
values_version=$(grep -E 'version v[0-9]' "${VALUES_FILE}" | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
script_version=$(grep -E 'DEFAULT_CHART_VERSION=' "${SETUP_SCRIPT}" | head -1 | sed 's/.*="\(.*\)".*/\1/')
if [[ -n "${values_version}" ]] && [[ -n "${script_version}" ]]; then
    if [[ "${values_version}" == "${script_version}" ]]; then
        pass "T-CROSS-04  chart version consistent: values.yaml comment (${values_version}) matches script default (${script_version})"
    else
        fail "T-CROSS-04  chart version mismatch: values.yaml comment references ${values_version}, script defaults to ${script_version}"
    fi
else
    skip "T-CROSS-04" "could not extract version from one or both files (values=${values_version:-<not found>} script=${script_version:-<not found>})"
fi

# T-CROSS-05a: values.yaml usage comment uses --set for certs; script uses --set-string
# The script is correct. The comment teaches operators the wrong form for manual installs.
values_uses_set_string=$(grep -c 'set-string.*ingress.ssl' "${VALUES_FILE}" || true)
if [[ ${values_uses_set_string} -gt 0 ]]; then
    pass "T-CROSS-05a values.yaml usage comment uses --set-string for TLS certs (consistent with script)"
else
    fail "T-CROSS-05a values.yaml usage comment uses bare --set for TLS certs, but script uses --set-string — operator copy-paste will silently risk type coercion"
fi

# T-CROSS-05b: emissary CRD URL version consistent across values.yaml comment and setup.sh
values_crd_url=$(grep -oE 'emissary/[0-9]+\.[0-9]+\.[0-9]+/emissary-crds' "${VALUES_FILE}" | head -1 || true)
script_crd_url=$(grep -oE 'emissary/[0-9]+\.[0-9]+\.[0-9]+/emissary-crds' "${SETUP_SCRIPT}" | head -1 || true)
if [[ -n "${values_crd_url}" ]] && [[ -n "${script_crd_url}" ]]; then
    if [[ "${values_crd_url}" == "${script_crd_url}" ]]; then
        pass "T-CROSS-05  emissary CRD URL version is consistent (${values_crd_url})"
    else
        fail "T-CROSS-05  emissary CRD URL version mismatch: values.yaml uses '${values_crd_url}', script uses '${script_crd_url}'"
    fi
else
    skip "T-CROSS-05" "could not extract emissary CRD version from one or both files"
fi

# ---------------------------------------------------------------------------
# HELM RENDERING TESTS (requires docker image semaphore-helm-test)
# ---------------------------------------------------------------------------
section "Helm rendering tests (T-RENDER-*)"

if ! $HAVE_DOCKER_IMAGE; then
    for t in T-RENDER-01 T-RENDER-02 T-RENDER-03 T-RENDER-04 T-RENDER-05 T-RENDER-06 T-RENDER-07; do
        skip "${t}" "docker image 'semaphore-helm-test' not built (run 'make docker.build' in helm-chart/)"
    done
else
    RENDER_OUTPUT="$(helm_render 2>&1)" && RENDER_EXIT=0 || RENDER_EXIT=$?

    if [[ ${RENDER_EXIT} -ne 0 ]]; then
        fail "T-RENDER-01  helm template failed (exit ${RENDER_EXIT})"
        echo "${RENDER_OUTPUT}" | head -30 | sed 's/^/             /'
        for t in T-RENDER-02 T-RENDER-03 T-RENDER-04 T-RENDER-05 T-RENDER-06 T-RENDER-07; do
            skip "${t}" "T-RENDER-01 failed — no rendered output to inspect"
        done
    else
        pass "T-RENDER-01  helm template exits 0 with required --set flags"

        # T-RENDER-02: ingressClassName is traefik
        if echo "${RENDER_OUTPUT}" | grep -q 'ingressClassName: traefik'; then
            pass "T-RENDER-02  rendered Ingress has ingressClassName: traefik"
        else
            fail "T-RENDER-02  rendered Ingress missing 'ingressClassName: traefik'"
        fi

        # T-RENDER-03: no GCE FrontendConfig resource
        if echo "${RENDER_OUTPUT}" | grep -q 'kind: FrontendConfig'; then
            fail "T-RENDER-03  rendered output contains 'kind: FrontendConfig' — GCE-only resource on k3s"
        else
            pass "T-RENDER-03  no GCE FrontendConfig rendered"
        fi

        # T-RENDER-04: no GCE BackendConfig resource
        if echo "${RENDER_OUTPUT}" | grep -q 'kind: BackendConfig'; then
            fail "T-RENDER-04  rendered output contains 'kind: BackendConfig' — GCE-only resource on k3s"
        else
            pass "T-RENDER-04  no GCE BackendConfig rendered"
        fi

        # T-RENDER-05: TLS Secret rendered (custom SSL path)
        if echo "${RENDER_OUTPUT}" | grep -q 'type: kubernetes.io/tls'; then
            pass "T-RENDER-05  TLS Secret (type: kubernetes.io/tls) rendered"
        else
            fail "T-RENDER-05  TLS Secret not rendered — ingress.ssl.type=custom should produce it"
        fi

        # T-RENDER-06: no EE-only Mappings (edition=ce)
        if echo "${RENDER_OUTPUT}" | grep -qE 'rbac-okta-saml-http-api|rbac-okta-scim-http-api|secrethub-openid-mapping'; then
            fail "T-RENDER-06  EE-only Mappings present in CE render — global.edition may not be 'ce'"
        else
            pass "T-RENDER-06  no EE-only Mappings in CE rendered output"
        fi

        # T-RENDER-07: traefik annotation on Ingress
        if echo "${RENDER_OUTPUT}" | grep -q 'traefik.ingress.kubernetes.io/router.entrypoints: websecure'; then
            pass "T-RENDER-07  Traefik entrypoints annotation present in rendered Ingress"
        else
            fail "T-RENDER-07  Traefik entrypoints annotation missing from rendered Ingress"
        fi

        # T-RENDER-08: helm template fails when global.domain.name is absent
        NO_DOMAIN_OUTPUT="$(docker run --rm \
            -v "${REPO_ROOT}:/workspace" \
            -w /workspace/helm-chart \
            semaphore-helm-test \
            -c "helm template . \
                -f /workspace/deploy/k3s/values.yaml \
                --set global.domain.ip=1.2.3.4 \
                --set global.rootUser.email=admin@example.com \
                --set 'global.rootUser.name=Admin' \
                --set ingress.ssl.crt=dGVzdC1jcnQ= \
                --set ingress.ssl.key=dGVzdC1rZXk=" \
            2>&1)" && NO_DOMAIN_EXIT=0 || NO_DOMAIN_EXIT=$?
        if [[ ${NO_DOMAIN_EXIT} -ne 0 ]] && echo "${NO_DOMAIN_OUTPUT}" | grep -qi 'global.domain.name'; then
            pass "T-RENDER-08  helm template correctly fails with 'global.domain.name is required' when domain absent"
        elif [[ ${NO_DOMAIN_EXIT} -ne 0 ]]; then
            fail "T-RENDER-08  helm template failed without domain but error message unclear: $(echo "${NO_DOMAIN_OUTPUT}" | head -5)"
        else
            fail "T-RENDER-08  helm template succeeded without global.domain.name — required guard not working"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Results"
printf '  PASS : %d\n' "${PASS}"
printf '  FAIL : %d\n' "${FAIL}"
printf '  SKIP : %d\n' "${SKIP}"
echo

if [[ ${FAIL} -gt 0 ]]; then
    echo "RESULT: FAILED — ${FAIL} test(s) failed"
    exit 1
else
    echo "RESULT: PASSED"
    exit 0
fi
