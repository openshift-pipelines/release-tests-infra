#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HACK_DIR="$SCRIPT_DIR/hack"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/env/.env.acceptance-ui}"

[[ -f "$ENV_FILE" ]] || {
  echo "ERROR: $ENV_FILE not found (cp env/env.acceptance-ui.template env/.env.acceptance-ui)" >&2
  exit 1
}
export ENV_FILE
set -a; source "$ENV_FILE"; set +a

# shellcheck source=hack/cluster-login.sh
source "$HACK_DIR/cluster-login.sh"
validate_cluster_env || exit 1

echo "============================================================"
echo "  release-tests-infra UI workflow"
echo "  Operator: ${OPERATOR_VERSION}  Catalog: ${CATALOG_SOURCE}/${CHANNEL:-pipelines-${OPERATOR_VERSION%.*}}}"
echo "  Environment: ${OPERATOR_ENVIRONMENT:-pre-stage}"
echo "  Framework: ${TEST_FRAMEWORK:-gauge}  Markers: ${MARKERS:-sanity}"
echo "============================================================"

cluster_login

echo "=== Step 1: Create secrets ==="
"$HACK_DIR/create-secrets.sh"

is_enabled() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1|on) return 0 ;; *) return 1 ;; esac
}

if is_enabled "${INSTALL_LOGGING_OPERATOR:-false}"; then
  echo "=== Installing Logging operator ==="
  bash "$REPO_ROOT/config/operators/install-logging.sh"
fi

if is_enabled "${INSTALL_SERVERLESS_OPERATOR:-false}"; then
  echo "=== Installing Serverless operator ==="
  bash "$REPO_ROOT/config/operators/install-serverless.sh"
fi

echo "=== Setting up Tekton pipelines-ci ==="
"$HACK_DIR/setup-pipelines-ci.sh"

echo "=== Creating UI acceptance PipelineRun ==="
"$HACK_DIR/create-pipelinerun-ui.sh"

echo "=== UI workflow complete ==="
