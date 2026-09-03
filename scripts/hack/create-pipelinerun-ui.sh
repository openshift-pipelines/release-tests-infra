#!/usr/bin/env bash
# Create an acceptance-ui-tests PipelineRun from env/.env.acceptance-ui
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/env/.env.acceptance-ui}"
export ENV_FILE

die() { echo "ERROR: $*" >&2; exit 1; }

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

load_post_test_flags() {
  SEND_SLACK_NOTIFICATION=$(normalize_bool "$(env_file_get SEND_SLACK_NOTIFICATION "$ENV_FILE")")
  INSTALL_PIPELINES_OPERATOR=$(normalize_bool "$(env_file_get INSTALL_PIPELINES_OPERATOR "$ENV_FILE")")
  UNINSTALL_PIPELINES_OPERATOR=$(normalize_bool "$(env_file_get UNINSTALL_PIPELINES_OPERATOR "$ENV_FILE")")
  SETUP_TESTING_ACCOUNTS=$(normalize_bool "$(env_file_get SETUP_TESTING_ACCOUNTS "$ENV_FILE")")
  export SEND_SLACK_NOTIFICATION INSTALL_PIPELINES_OPERATOR UNINSTALL_PIPELINES_OPERATOR SETUP_TESTING_ACCOUNTS
}

_SAVED_MARKERS="" _HAS_MARKERS=""
_save_cli_overrides() {
  if [[ -n "${MARKERS+x}" ]]; then _SAVED_MARKERS="$MARKERS"; _HAS_MARKERS=1; fi
}
_restore_cli_overrides() {
  if [[ -n "$_HAS_MARKERS" ]]; then export MARKERS="$_SAVED_MARKERS"; fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE (cp env/env.acceptance-ui.template env/.env.acceptance-ui)"
  _save_cli_overrides
  set -a; source "$ENV_FILE"; set +a
  _restore_cli_overrides
  load_post_test_flags
  # shellcheck source=cluster-login.sh
  source "$SCRIPT_DIR/cluster-login.sh"
}

ci_config_get() {
  local ver="$1" key="$2" cfg="${REPO_ROOT}/ci-config.yaml"
  [[ -f "$cfg" ]] || return 1
  python3 -c "
import yaml, sys
with open('$cfg') as f:
    c = yaml.safe_load(f)
ver = '$ver'
keys = '$key'.split('.')
v = c.get(ver)
if v is None:
    sys.exit(1)
for k in keys:
    if isinstance(v, dict):
        v = v.get(k)
    else:
        sys.exit(1)
if v is None:
    sys.exit(1)
print(v, end='')
" 2>/dev/null
}

detect_ocp_minor() {
  local raw=""
  if [[ "${OPENSHIFT_VERSION:-}" =~ ^([0-9]+)\.([0-9]+) ]]; then
    printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  if command -v oc &>/dev/null; then
    raw=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
    if [[ "$raw" =~ ^([0-9]+)\.([0-9]+) ]]; then
      printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      return 0
    fi
  fi
  return 1
}

resolve_from_ci_config() {
  [[ -n "${OPERATOR_VERSION:-}" ]] || die "OPERATOR_VERSION required in $ENV_FILE"
  local ver="${OPERATOR_VERSION%.*}"

  if [[ -z "${CHANNEL:-}" || "${CHANNEL}" == latest ]]; then
    CHANNEL=$(ci_config_get "$ver" channel) \
      || CHANNEL="pipelines-${ver}"
    export CHANNEL
  fi

  if [[ -z "${GIT_RELEASE_TESTS_BRANCH:-}" ]]; then
    GIT_RELEASE_TESTS_BRANCH=$(ci_config_get "$ver" release-tests.revision) || true
    export GIT_RELEASE_TESTS_BRANCH
  fi

  if [[ -z "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]]; then
    GIT_RELEASE_TESTS_GINKGO_BRANCH=$(ci_config_get "$ver" release-tests-ginkgo.revision) || true
    export GIT_RELEASE_TESTS_GINKGO_BRANCH
  fi

  if [[ -z "${GIT_UI_TESTS_BRANCH:-}" ]]; then
    local ocp_ver branch
    ocp_ver=$(detect_ocp_minor) || true
    if [[ -n "$ocp_ver" ]]; then
      branch=$(ci_config_get "$ocp_ver" release-ui-tests.revision) || true
      if [[ -n "$branch" ]]; then
        GIT_UI_TESTS_BRANCH="$branch"
        export GIT_UI_TESTS_BRANCH
        echo "    GIT_UI_TESTS_BRANCH=${GIT_UI_TESTS_BRANCH} (ci-config.yaml ocp ${ocp_ver})"
      else
        echo "WARNING: no release-ui-tests mapping for OCP ${ocp_ver} in ci-config.yaml" >&2
      fi
    else
      echo "WARNING: cannot detect OCP version — set OPENSHIFT_VERSION=4.xx in $ENV_FILE or GIT_UI_TESTS_BRANCH" >&2
    fi
  fi
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

Creates an acceptance-ui-tests PipelineRun and exits immediately.
Env file: ENV_FILE=env/.env.acceptance-ui (default)

The pipeline finally task cleanup-pipelinerun removes the PipelineRun after optional slack notification.
Workspace PVC cleanup: ./scripts/hack/cleanup-pipeline-pvcs.sh --finished
EOF
      exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

write_pipelinerun() {
  local pr pr_name
  pr="$(mktemp "${TMPDIR:-/tmp}/pipelinerun-ui.XXXXXX")"
  trap 'rm -f "$pr"' RETURN

  cat > "$pr" <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: ${PREFIX}
spec:
  pipelineRef:
    name: acceptance-ui-tests
  params:
    - name: INSTALLER
      value: "${INSTALLER:-cluster-platforms}"
    - name: BASE_DOMAIN
      value: "${BASE_DOMAIN:-aws.ospqa.com}"
    - name: AWS_REGION
      value: "${AWS_REGION:-us-east-2}"
    - name: AZURE_LOCATION
      value: "${AZURE_LOCATION:-eastus}"
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
    - name: GIT_RELEASE_TESTS_BRANCH
      value: "${GIT_RELEASE_TESTS_BRANCH:-}"
    - name: GIT_RELEASE_TESTS_GINKGO_BRANCH
      value: "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}"
    - name: GIT_UI_TESTS_URI
      value: "${GIT_UI_TESTS_URI:-https://github.com/openshift-pipelines/release-ui-tests.git}"
    - name: GIT_UI_TESTS_BRANCH
      value: "${GIT_UI_TESTS_BRANCH:-}"
    - name: TEST_FRAMEWORK
      value: "${FW}"
    - name: IMAGE
      value: "${IMAGE:-quay.io/openshift-pipeline/ci:latest}"
    - name: UI_IMAGE
      value: "${UI_IMAGE:-quay.io/openshift-pipeline/ui-ci:latest}"
    - name: TKN_DOWNLOAD_URL
      value: "${TKN_DOWNLOAD_URL:-}"
    - name: INSTALL_PIPELINES_OPERATOR
      value: "${INSTALL_PIPELINES_OPERATOR:-true}"
    - name: SETUP_TESTING_ACCOUNTS
      value: "${SETUP_TESTING_ACCOUNTS:-false}"
    - name: KONFLUX_INDEX_IMAGE
      value: "${KONFLUX_INDEX_IMAGE:-}"
    - name: OPERATOR_ENVIRONMENT
      value: "${OPERATOR_ENVIRONMENT:-pre-stage}"
    - name: OPERATOR_VERSION
      value: "${OPERATOR_VERSION}"
    - name: GIT_INFRA_BRANCH
      value: "${GIT_INFRA_BRANCH:-main}"
    - name: MARKERS
      value: "${MARKERS}"
    - name: PYTEST_ARGS
      value: "${PYTEST_ARGS:-}"
    - name: APP_TIMEOUT
      value: "${APP_TIMEOUT:-90000}"
    - name: CAPTURE_SCREENSHOTS
      value: "${CAPTURE_SCREENSHOTS:-true}"
    - name: CAPTURE_RECORDINGS
      value: "${CAPTURE_RECORDINGS:-true}"
    - name: UPLOAD_RECORDINGS_ON_FAILURE
      value: "${UPLOAD_RECORDINGS_ON_FAILURE:-false}"
    - name: UNINSTALL_PIPELINES_OPERATOR
      value: "${UNINSTALL_PIPELINES_OPERATOR:-false}"
    - name: SEND_SLACK_NOTIFICATION
      value: "${SEND_SLACK_NOTIFICATION}"
  timeouts:
    pipeline: 3h
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
    [[ -n "${!v:-}" ]] || die "$v required in $ENV_FILE"
  done

  case "$FW" in gauge|ginkgo) ;; *) die "TEST_FRAMEWORK must be gauge or ginkgo (got: ${TEST_FRAMEWORK})" ;; esac

  validate_operator_env || exit 1

  if ! is_provisioned_installer; then
    cluster_secret_exists "$NS" \
      || die "secret $(cluster_secret_name) missing in $NS (run ./scripts/hack/setup-pipelines-ci.sh)"
  fi

  # Auto-create test secrets if missing
  if ! oc get secret github -n "$NS" &>/dev/null; then
    bash "$SCRIPT_DIR/create-secrets.sh" || die "create-secrets.sh failed"
  fi

  oc get pipeline acceptance-ui-tests -n "$NS" &>/dev/null \
    || die "pipeline acceptance-ui-tests missing in $NS (run ./scripts/hack/setup-pipelines-ci.sh)"

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
resolve_from_ci_config

[[ "$FW" != ginkgo || -n "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]] \
  || die "GIT_RELEASE_TESTS_GINKGO_BRANCH required for ginkgo (set in $ENV_FILE or add to ci-config.yaml)"
[[ "$FW" != gauge || -n "${GIT_RELEASE_TESTS_BRANCH:-}" ]] \
  || die "GIT_RELEASE_TESTS_BRANCH required for gauge (set in $ENV_FILE or add to ci-config.yaml)"
[[ -n "${GIT_UI_TESTS_BRANCH:-}" ]] \
  || die "GIT_UI_TESTS_BRANCH required (set in $ENV_FILE, OPENSHIFT_VERSION=4.xx, or add to ci-config.yaml)"

MARKERS="${MARKERS:-sanity}"

case "${INSTALLER,,}" in
  none|cluster-platforms|cluster-platform|cp) _installer_tag="cp-" ;;
  aws-ipi|aro|rosa) _installer_tag="${INSTALLER,,}-" ;;
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
PREFIX="acceptance-ui-tests-${_installer_tag}${_fw_tag}${_osp_short}-${_env_short}-on-${_ocp_short}-"

echo "=== PipelineRun → ${NS}  pipeline=acceptance-ui-tests  framework=${FW}  installer=${INSTALLER:-cluster-platforms}  cluster=${CLUSTER_NAME}  operator=${OPERATOR_VERSION}  channel=${CHANNEL}  ui-tests-branch=${GIT_UI_TESTS_BRANCH} ==="
echo "    markers: ${MARKERS}"
echo "    app_timeout: ${APP_TIMEOUT:-90000}  capture_screenshots: ${CAPTURE_SCREENSHOTS:-true}  capture_recordings: ${CAPTURE_RECORDINGS:-true}  upload_recordings_on_failure: ${UPLOAD_RECORDINGS_ON_FAILURE:-false}"
echo "    install via pipeline: ${INSTALL_PIPELINES_OPERATOR:-true}"
echo "    setup testing accounts: ${SETUP_TESTING_ACCOUNTS:-false}"
echo "    slack notification: ${SEND_SLACK_NOTIFICATION}"

write_pipelinerun
