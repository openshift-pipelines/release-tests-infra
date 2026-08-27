#!/usr/bin/env bash
# Create an acceptance-tests PipelineRun from env/.env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/env/.env}"
export ENV_FILE

die() { echo "ERROR: $*" >&2; exit 1; }

# Read a single key from env/.env (ignores shell exports — file is source of truth for post-test flags).
env_file_get() {
  local key=$1 file=$2 line val
  [[ -f "$file" ]] || return 1
  line=$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1) || return 1
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

normalize_bool() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1|on) printf '%s' true ;;
    *) printf '%s' false ;;
  esac
}

is_enabled() {
  [[ "$(normalize_bool "${1:-false}")" == true ]]
}

# Post-test flags always come from env/.env, never from a stale shell export.
load_post_test_flags() {
  SEND_SLACK_NOTIFICATION=$(normalize_bool "$(env_file_get SEND_SLACK_NOTIFICATION "$ENV_FILE")")
  INSTALL_PIPELINES_OPERATOR=$(normalize_bool "$(env_file_get INSTALL_PIPELINES_OPERATOR "$ENV_FILE")")
  UNINSTALL_PIPELINES_OPERATOR=$(normalize_bool "$(env_file_get UNINSTALL_PIPELINES_OPERATOR "$ENV_FILE")")
  export SEND_SLACK_NOTIFICATION INSTALL_PIPELINES_OPERATOR UNINSTALL_PIPELINES_OPERATOR
}

# Preserve vars set on the command line before env/.env is sourced (e.g. TEST_SUITES=foo ./script).
# Post-test flags (SEND_SLACK_NOTIFICATION, INSTALL_PIPELINES_OPERATOR) are read from env/.env only.
_SAVED_TEST_SUITES="" _SAVED_TAGS="" _HAS_TEST_SUITES="" _HAS_TAGS=""
_save_cli_overrides() {
  if [[ -n "${TEST_SUITES+x}" ]]; then _SAVED_TEST_SUITES="$TEST_SUITES"; _HAS_TEST_SUITES=1; fi
  if [[ -n "${TAGS+x}" ]]; then _SAVED_TAGS="$TAGS"; _HAS_TAGS=1; fi
}
_restore_cli_overrides() {
  if [[ -n "$_HAS_TEST_SUITES" ]]; then export TEST_SUITES="$_SAVED_TEST_SUITES"; fi
  if [[ -n "$_HAS_TAGS" ]]; then export TAGS="$_SAVED_TAGS"; fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE (cp env/env.template env/.env)"
  _save_cli_overrides
  set -a; source "$ENV_FILE"; set +a
  _restore_cli_overrides
  load_post_test_flags
  # shellcheck source=cluster-login.sh
  source "$SCRIPT_DIR/cluster-login.sh"
}

# Comma/space-separated TEST_SUITES → YAML list items (8-space indent under value:).
parse_test_suites() {
  local raw="${TEST_SUITES:-release-tests-versions}" s
  TEST_SUITE_ITEMS=()
  raw="${raw// /,}"
  IFS=',' read -ra parts <<< "$raw"
  for s in "${parts[@]}"; do
    s="${s// /}"
    [[ -n "$s" ]] && TEST_SUITE_ITEMS+=("$s")
  done
  ((${#TEST_SUITE_ITEMS[@]})) || TEST_SUITE_ITEMS=(release-tests-versions)
}

ci_config_major_minor() {
  local v="${1#v}"
  v="${v%%-*}"
  printf '%s' "$v" | awk -F. '{ if (NF >= 2) printf "%s.%s", $1, $2; else printf "%s", $0 }'
}

ci_config_get() {
  local ver="$1" key="$2" cfg="${REPO_ROOT}/ci-config.yaml"
  [[ -f "$cfg" ]] || return 1
  python3 - "$cfg" "$ver" "$key" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required to read ci-config.yaml (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)
cfg, ver, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cfg) as f:
    c = yaml.safe_load(f) or {}
node = c.get(ver)
if node is None:
    for k, val in c.items():
        if str(k) == str(ver):
            node = val
            break
if node is None:
    sys.exit(1)
for k in key.split("."):
    if not isinstance(node, dict):
        sys.exit(1)
    node = node.get(k)
    if node is None:
        sys.exit(1)
print(node, end="")
PY
}

# True (exit 0) if ci-config.yaml has a top-level entry for the given major.minor.
ci_config_has_version() {
  local ver="$1" cfg="${REPO_ROOT}/ci-config.yaml"
  [[ -f "$cfg" ]] || return 1
  python3 - "$cfg" "$ver" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required to read ci-config.yaml (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)
cfg, ver = sys.argv[1], sys.argv[2]
with open(cfg) as f:
    c = yaml.safe_load(f) or {}
sys.exit(0 if str(ver) in {str(k) for k in c} else 1)
PY
}

# Space-separated list of major.minor versions declared in ci-config.yaml (for error messages).
ci_config_versions() {
  local cfg="${REPO_ROOT}/ci-config.yaml"
  [[ -f "$cfg" ]] || return 1
  python3 - "$cfg" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit(2)
with open(sys.argv[1]) as f:
    c = yaml.safe_load(f) or {}
print(" ".join(str(k) for k in c))
PY
}

resolve_from_ci_config() {
  [[ -n "${OPERATOR_VERSION:-}" ]] || die "OPERATOR_VERSION required in env/.env"
  local ver
  ver="$(ci_config_major_minor "$OPERATOR_VERSION")"
  [[ -z "${GIT_RELEASE_TESTS_BRANCH:-}" ]] && unset GIT_RELEASE_TESTS_BRANCH
  [[ -z "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]] && unset GIT_RELEASE_TESTS_GINKGO_BRANCH

  # Require a ci-config.yaml entry for this operator version, unless the
  # framework-required branch is already provided explicitly in env/.env.
  if ! ci_config_has_version "$ver"; then
    local branch_var have_branch=false
    if [[ "$FW" == ginkgo ]]; then
      branch_var=GIT_RELEASE_TESTS_GINKGO_BRANCH
      [[ -n "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]] && have_branch=true
    else
      branch_var=GIT_RELEASE_TESTS_BRANCH
      [[ -n "${GIT_RELEASE_TESTS_BRANCH:-}" ]] && have_branch=true
    fi
    if [[ "$have_branch" != true ]]; then
      die "OPERATOR_VERSION=${OPERATOR_VERSION} (${ver}) has no entry in ci-config.yaml (available: $(ci_config_versions)). Add a '${ver}:' block to ci-config.yaml, or set ${branch_var} (and CHANNEL) in env/.env."
    fi
    echo "WARNING: ci-config.yaml has no '${ver}' entry; using ${branch_var} from env/.env"
  fi

  if [[ -z "${CHANNEL:-}" || "${CHANNEL}" == latest ]]; then
    CHANNEL=$(ci_config_get "$ver" channel) \
      || CHANNEL="pipelines-${ver}"
    export CHANNEL
  fi

  if [[ -z "${GIT_RELEASE_TESTS_BRANCH:-}" ]]; then
    GIT_RELEASE_TESTS_BRANCH=$(ci_config_get "$ver" release-tests.revision) || true
    export GIT_RELEASE_TESTS_BRANCH
    [[ -n "${GIT_RELEASE_TESTS_BRANCH:-}" ]] \
      && echo "Auto-resolved GIT_RELEASE_TESTS_BRANCH=${GIT_RELEASE_TESTS_BRANCH} from ci-config.yaml (${ver})"
  fi

  if [[ -z "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]]; then
    GIT_RELEASE_TESTS_GINKGO_BRANCH=$(ci_config_get "$ver" release-tests-ginkgo.revision) || true
    export GIT_RELEASE_TESTS_GINKGO_BRANCH
    [[ -n "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]] \
      && echo "Auto-resolved GIT_RELEASE_TESTS_GINKGO_BRANCH=${GIT_RELEASE_TESTS_GINKGO_BRANCH} from ci-config.yaml (${ver})"
  fi

  # Guard against set -e: a trailing "[[ ... ]] && echo" above can leave the
  # function's exit status at 1, which would abort the script silently.
  return 0
}

write_workspace_spec() {
  local size="${PIPELINE_WORKSPACE_SIZE:-5Gi}"
  local mode="${PIPELINE_WORKSPACE_ACCESS_MODE:-ReadWriteOnce}"
  local sc="${PIPELINE_WORKSPACE_STORAGE_CLASS:-}"
  cat <<EOF
    - name: data
      volumeClaimTemplate:
        metadata:
          labels:
            app: release-tests-infra
            release-tests-infra/pvc-role: pipelinerun-workspace
        spec:
          accessModes:
            - ${mode}
          resources:
            requests:
              storage: ${size}
EOF
  if [[ -n "$sc" ]]; then
    printf '          storageClassName: %s\n' "$sc"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<EOF
Usage: $0

Creates the PipelineRun and exits immediately.
The pipeline finally task cleanup-pipelinerun removes the PipelineRun after optional slack notification.
Workspace PVC cleanup: ./scripts/hack/cleanup-pipeline-pvcs.sh --finished
EOF
      exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

write_pipelinerun() {
  local pr pr_name
  pr="$(mktemp "${TMPDIR:-/tmp}/pipelinerun.XXXXXX")"
  trap 'rm -f "$pr"' RETURN

  cat > "$pr" <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: ${PREFIX}
spec:
  pipelineRef:
    name: acceptance-tests
  params:
    - name: INSTALLER
      value: "${INSTALLER:-cluster-platforms}"
    - name: BASE_DOMAIN
      value: "${BASE_DOMAIN:-aws.ospqa.com}"
    - name: AWS_REGION
      value: "${AWS_REGION:-us-east-2}"
    - name: OPENSHIFT_VERSION
      value: "${OPENSHIFT_VERSION:-stable}"
    - name: KEEP_CLUSTER
      value: "${KEEP_CLUSTER:-false}"
    - name: CLUSTER_LIFETIME
      value: "${CLUSTER_LIFETIME:-6h}"
    - name: ARCH
      value: "${ARCH:-linux/amd64}"
    - name: CATALOG_SOURCE
      value: "${CATALOG_SOURCE:-custom-operators}"
    - name: CHANNEL
      value: "${CHANNEL}"
    - name: CLUSTER_NAME
      value: "${CLUSTER_NAME}"
    - name: GIT_RELEASE_TESTS_URI
      value: "${GIT_RELEASE_TESTS_URI:-https://github.com/openshift-pipelines/release-tests.git}"
    - name: GIT_RELEASE_TESTS_BRANCH
      value: "${GIT_RELEASE_TESTS_BRANCH:-}"
    - name: GIT_RELEASE_TESTS_GINKGO_URI
      value: "${GIT_RELEASE_TESTS_GINKGO_URI:-https://github.com/openshift-pipelines/release-tests-ginkgo.git}"
    - name: GIT_RELEASE_TESTS_GINKGO_BRANCH
      value: "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}"
    - name: TEST_FRAMEWORK
      value: "${FW}"
    - name: IMAGE
      value: "${IMAGE:-quay.io/openshift-pipeline/ci:latest}"
    - name: TKN_DOWNLOAD_URL
      value: "${TKN_DOWNLOAD_URL:-}"
    - name: INSTALL_PIPELINES_OPERATOR
      value: "${INSTALL_PIPELINES_OPERATOR:-true}"
    - name: KONFLUX_INDEX_IMAGE
      value: "${KONFLUX_INDEX_IMAGE:-}"
    - name: OPERATOR_ENVIRONMENT
      value: "${OPERATOR_ENVIRONMENT:-pre-stage}"
    - name: OPERATOR_VERSION
      value: "${OPERATOR_VERSION}"
    - name: GIT_INFRA_BRANCH
      value: "${GIT_INFRA_BRANCH:-main}"
    - name: GIT_INFRA_URI
      value: "${GIT_INFRA_URI:-}"
    - name: TAGS
      value: "${TAGS}"
    - name: TEST_SUITES
      value:
EOF

  for s in "${TEST_SUITE_ITEMS[@]}"; do
    printf '        - %s\n' "$s" >> "$pr"
  done

  cat >> "$pr" <<EOF
    - name: UNINSTALL_PIPELINES_OPERATOR
      value: "${UNINSTALL_PIPELINES_OPERATOR:-false}"
    - name: SEND_SLACK_NOTIFICATION
      value: "${SEND_SLACK_NOTIFICATION}"
    - name: IS_DISCONNECTED
      value: "${IS_DISCONNECTED:-false}"
    - name: TEMPLATE
      value: "${TEMPLATE:-}"
    - name: LAUNCHER_VARS
      value: '${LAUNCHER_VARS:-}'
    - name: GIT_PRIVATE_TEMPLATES_BRANCH
      value: "${GIT_PRIVATE_TEMPLATES_BRANCH:-master}"
    - name: GIT_PRIVATE_TEMPLATES_URI
      value: "${GIT_PRIVATE_TEMPLATES_URI:-https://gitlab.cee.redhat.com/aosqe/flexy-templates.git}"
  timeouts:
    pipeline: 3h
  taskRunTemplate:
    podTemplate:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        fsGroup: 0
  workspaces:
EOF
  write_workspace_spec >> "$pr"

  pr_name=$(oc create -f "$pr" -n "$NS" -o jsonpath='{.metadata.name}') &&
  echo "PipelineRun: pipelinerun.tekton.dev/${pr_name}" &&
  echo "    SEND_SLACK_NOTIFICATION=$(oc get pipelinerun "$pr_name" -n "$NS" -o jsonpath='{.spec.params[?(@.name=="SEND_SLACK_NOTIFICATION")].value}')"
}

preflight() {
  command -v oc >/dev/null || die "oc CLI required"

  NS="${NAMESPACE:-pipelines-ci}"
  FW="$(printf '%s' "${TEST_FRAMEWORK:-gauge}" | tr '[:upper:]' '[:lower:]')"

  for v in CLUSTER_NAME OPERATOR_VERSION; do
    [[ -n "${!v:-}" ]] || die "$v required in env/.env"
  done

  case "$FW" in gauge|ginkgo) ;; *) die "TEST_FRAMEWORK must be gauge or ginkgo (got: ${TEST_FRAMEWORK})" ;; esac

  validate_operator_env || exit 1

  if ! is_provisioned_installer; then
    cluster_secret_exists "$NS" \
      || die "secret $(cluster_secret_name) missing in $NS (run ./scripts/hack/setup-pipelines-ci.sh)"
  fi

  # Auto-create test secrets if missing
  if ! oc get secret github -n "$NS" &>/dev/null; then
    echo "    test secrets missing — running create-secrets.sh"
    bash "$SCRIPT_DIR/create-secrets.sh" || die "create-secrets.sh failed"
  fi

  oc get pipeline acceptance-tests -n "$NS" &>/dev/null \
    || die "pipeline acceptance-tests missing in $NS (run ./scripts/hack/setup-pipelines-ci.sh)"

  if is_enabled "${SEND_SLACK_NOTIFICATION}"; then
    oc get secret coreos-tektondev-webhook -n "$NS" &>/dev/null \
      || die "slack webhook secret missing in $NS (run ./scripts/hack/create-secrets.sh)"
    echo "    slack notification: enabled"
  else
    echo "    slack notification: disabled (SEND_SLACK_NOTIFICATION=${SEND_SLACK_NOTIFICATION})"
  fi
}

load_env
preflight

parse_test_suites
resolve_from_ci_config

[[ "$FW" != ginkgo || -n "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]] \
  || die "GIT_RELEASE_TESTS_GINKGO_BRANCH required for ginkgo (set in env/.env or add to ci-config.yaml)"
[[ "$FW" != gauge || -n "${GIT_RELEASE_TESTS_BRANCH:-}" ]] \
  || die "GIT_RELEASE_TESTS_BRANCH required for gauge (set in env/.env or add to ci-config.yaml)"

TAGS="${TAGS:-$([ "$FW" = ginkgo ] && echo sanity || echo e2e)}"

# Build descriptive PipelineRun name: acceptance-tests-aro-1222-prod-on-420-
case "${INSTALLER,,}" in
  none|cluster-platforms|cluster-platform|cp) _installer_tag="cp-" ;;
  aws-ipi|aro|rosa|flexy) _installer_tag="${INSTALLER,,}-" ;;
  *) _installer_tag="" ;;
esac
_osp_short=$(echo "${OPERATOR_VERSION}" | sed 's/\.//g')
_env_short="${OPERATOR_ENVIRONMENT:-prod}"
_ocp_short=""
if command -v oc &>/dev/null; then
  _ocp_short=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null \
    | sed 's/\([0-9]*\)\.\([0-9]*\).*/\1\2/' || true)
fi
[[ -z "$_ocp_short" ]] && _ocp_short="ocp"
_fw_tag="$([ "$FW" = ginkgo ] && echo ginkgo- || echo "")"
PREFIX="acceptance-tests-${_installer_tag}${_fw_tag}${_osp_short}-${_env_short}-on-${_ocp_short}-"

echo "=== PipelineRun → ${NS}  framework=${FW}  cluster=${CLUSTER_NAME}  operator=${OPERATOR_VERSION}  channel=${CHANNEL} ==="
echo "    install via pipeline: ${INSTALL_PIPELINES_OPERATOR:-true}"
echo "    slack notification: ${SEND_SLACK_NOTIFICATION}"
echo "    suites: ${TEST_SUITE_ITEMS[*]}"

write_pipelinerun
