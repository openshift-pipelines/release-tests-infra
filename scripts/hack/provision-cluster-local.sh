#!/usr/bin/env bash
# Provision an OCP cluster from a local Mac using openshift-install.
# Supports amd64 and arm64 targets, FIPS mode, and multi-arch release images.
#
# Usage:
#   ./scripts/hack/provision-cluster-local.sh
#   ARCH=arm64 FIPS=true ./scripts/hack/provision-cluster-local.sh
#   ./scripts/hack/provision-cluster-local.sh --destroy
#
# Reads configuration from env/.env. Required vars:
#   AWS_ACCESS_KEY, AWS_ACCESS_SECRET (or aws credentials configured)
#   PULL_SECRET (or extracted from Vault / existing cluster)
#
# Optional env/.env vars:
#   ARCH             — target arch: amd64 (default) or arm64
#   FIPS             — true to enable FIPS mode (default: false)
#   CLUSTER_NAME     — prefix for cluster name (default: ocp)
#   OPENSHIFT_VERSION — OCP version (default: stable-4.20)
#   AWS_REGION       — AWS region (default: us-east-2)
#   BASE_DOMAIN      — Route53 base domain (default: aws.ospqa.com)
#   WORKER_REPLICAS  — number of workers (default: 3)
#   WORKER_TYPE      — worker instance type (auto-mapped for arm64)
#   MASTER_TYPE      — master instance type (auto-mapped for arm64)
#   CLUSTER_LIFETIME — tag for orphan cleanup (default: 6h)
#   KEEP_CLUSTER     — true to skip auto-destroy (default: false)
#   SSH_PUBLIC_KEY   — SSH public key for node access

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/env/.env}"

die() { echo "ERROR: $*" >&2; exit 1; }

# Save command-line overrides before sourcing env/.env
_CLI_ARCH="${ARCH:-}" _CLI_FIPS="${FIPS:-}" _CLI_NAME="${CLUSTER_NAME:-}"
_CLI_VER="${OPENSHIFT_VERSION:-}" _CLI_REGION="${AWS_REGION:-}" _CLI_DOMAIN="${BASE_DOMAIN:-}"
_CLI_WORKERS="${WORKER_REPLICAS:-}" _CLI_WORKER="${WORKER_TYPE:-}" _CLI_MASTER="${MASTER_TYPE:-}"
_CLI_LIFETIME="${CLUSTER_LIFETIME:-}"

[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

# Command-line env vars override env/.env values
TARGET_ARCH="${_CLI_ARCH:-${ARCH:-amd64}}"
[[ "$TARGET_ARCH" == linux/* ]] && TARGET_ARCH="${TARGET_ARCH#linux/}"
FIPS="${_CLI_FIPS:-${FIPS:-false}}"
CLUSTER_PREFIX="${_CLI_NAME:-${CLUSTER_NAME:-ocp}}"
OCP_VERSION="${_CLI_VER:-${OPENSHIFT_VERSION:-stable-4.20}}"
REGION="${_CLI_REGION:-${AWS_REGION:-us-east-2}}"
DOMAIN="${_CLI_DOMAIN:-${BASE_DOMAIN:-aws.ospqa.com}}"
WORKERS="${_CLI_WORKERS:-${WORKER_REPLICAS:-2}}"
WORKER="${_CLI_WORKER:-${WORKER_TYPE:-m5.xlarge}}"
MASTER="${_CLI_MASTER:-${MASTER_TYPE:-m5.xlarge}}"
LIFETIME="${_CLI_LIFETIME:-${CLUSTER_LIFETIME:-6h}}"

# Map instance types for arm64
if [[ "$TARGET_ARCH" == "arm64" ]]; then
  [[ "$WORKER" == m5.* ]] && WORKER="${WORKER/m5./m6g.}"
  [[ "$MASTER" == m5.* ]] && MASTER="${MASTER/m5./m6g.}"
fi

# Detect local Mac architecture
LOCAL_ARCH=$(uname -m)
case "$LOCAL_ARCH" in
  arm64|aarch64) LOCAL_ARCH_OCP="aarch64"; LOCAL_ARCH_SHORT="arm64" ;;
  x86_64)        LOCAL_ARCH_OCP="x86_64";  LOCAL_ARCH_SHORT="amd64" ;;
  *) die "Unsupported local architecture: $LOCAL_ARCH" ;;
esac

CLUSTER_SUFFIX="$(date +%m%d%H%M | cut -c1-6)"
CLUSTER_NAME="$(echo "${CLUSTER_PREFIX}${CLUSTER_SUFFIX}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
INSTALL_DIR="${REPO_ROOT}/.clusters/${CLUSTER_NAME}"

# --- Destroy mode ---
if [[ "${1:-}" == "--destroy" ]]; then
  # Find the cached openshift-install binary
  OI_BIN=$(ls -t "$REPO_ROOT/.clusters/bin/openshift-install-"* 2>/dev/null | grep -v fips-wrapper | grep -v rhel9 | head -1)
  [[ -z "$OI_BIN" ]] && OI_BIN=$(ls -t "$REPO_ROOT/.clusters/bin/openshift-install-"* 2>/dev/null | head -1)
  [[ -x "$OI_BIN" ]] || die "openshift-install not found in .clusters/bin/ — run a provision first or install it manually"

  local_dir="${2:-}"
  if [[ -n "$local_dir" && -d "$local_dir" ]]; then
    target="$local_dir"
  elif [[ -d "$INSTALL_DIR" ]]; then
    target="$INSTALL_DIR"
  else
    target=$(ls -td "$REPO_ROOT/.clusters/"*/ 2>/dev/null | grep -v bin | grep -v ssh | head -1)
    [[ -n "$target" ]] || die "No cluster install directory found in .clusters/"
  fi
  echo "=== Destroying cluster: $(basename "$target") ==="
  echo "  Binary: $OI_BIN"
  echo "  Dir:    $target"
  "$OI_BIN" destroy cluster --dir="$target" --log-level=info
  echo "Cluster destroyed."
  rm -rf "$target"
  echo "Removed install directory: $target"
  # Remove MCP config pointing to destroyed cluster
  [[ -x "$SCRIPT_DIR/configure-mcp.sh" ]] && "$SCRIPT_DIR/configure-mcp.sh" --remove 2>/dev/null || true
  exit 0
fi

# --- Validate prerequisites ---
command -v curl >/dev/null || die "curl required"

if [[ -n "${AWS_ACCESS_KEY:-${AWS_ACCESS_KEY_ID:-}}" ]]; then
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY:-${AWS_ACCESS_KEY_ID:-}}"
  export AWS_SECRET_ACCESS_KEY="${AWS_ACCESS_SECRET:-${AWS_SECRET_ACCESS_KEY:-}}"
elif [[ -f ~/.aws/credentials ]]; then
  echo "Using AWS credentials from ~/.aws/credentials"
  if [[ -z "${AWS_PROFILE:-}" ]]; then
    AWS_PROFILE=$(sed -n 's/^\[//;s/\]//p' ~/.aws/credentials | head -1)
    [[ "$AWS_PROFILE" != "default" && -n "$AWS_PROFILE" ]] && export AWS_PROFILE
  fi
else
  die "AWS credentials required: set AWS_ACCESS_KEY in env/.env or configure ~/.aws/credentials"
fi

# Pull secret
if [[ -z "${PULL_SECRET:-}" ]]; then
  for ps in "$REPO_ROOT/.pull-secret.json" ~/.aws/pull-secret.txt ~/.pull-secret.json; do
    [[ -f "$ps" ]] && { PULL_SECRET=$(cat "$ps"); echo "Using pull secret from $ps"; break; }
  done
  [[ -n "${PULL_SECRET:-}" ]] || die "PULL_SECRET required (set in env/.env or save to ~/.aws/pull-secret.txt)"
fi

# SSH key (FIPS only allows RSA or ECDSA, not ed25519)
if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
  OCP_KEY="$REPO_ROOT/.clusters/ssh/id_ecdsa_aws"
  if [[ "$FIPS" == true ]]; then
    for key in "$OCP_KEY.pub" ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
      [[ -f "$key" ]] && { SSH_PUBLIC_KEY=$(cat "$key"); echo "Using FIPS-compatible SSH key: $key"; break; }
    done
  else
    for key in ~/.ssh/id_ed25519.pub "$OCP_KEY.pub" ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
      [[ -f "$key" ]] && { SSH_PUBLIC_KEY=$(cat "$key"); break; }
    done
  fi
  if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
    echo "No SSH key found — generating ECDSA key for cluster provisioning"
    mkdir -p "$(dirname "$OCP_KEY")"
    ssh-keygen -t ecdsa -b 521 -f "$OCP_KEY" -N "" -q
    SSH_PUBLIC_KEY=$(cat "$OCP_KEY.pub")
    echo "Generated: $OCP_KEY.pub (reused for future provisions)"
  fi
fi

echo "============================================================"
echo "  Provisioning OCP Cluster"
echo "============================================================"
echo "  Cluster:      ${CLUSTER_NAME}"
echo "  OCP version:  ${OCP_VERSION}"
echo "  Architecture: ${TARGET_ARCH}"
echo "  FIPS:         ${FIPS}"
echo "  Region:       ${REGION}"
echo "  Domain:       ${DOMAIN}"
echo "  Workers:      ${WORKERS} × ${WORKER}"
echo "  Masters:      3 × ${MASTER}"
echo "  Local arch:   ${LOCAL_ARCH} (${LOCAL_ARCH_SHORT})"
echo "  Install dir:  ${INSTALL_DIR}"
echo "============================================================"

# --- Download openshift-install ---
MIRROR="https://mirror.openshift.com/pub/openshift-v4"
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

if [[ "$FIPS" == true ]]; then
  INSTALL_BIN="${REPO_ROOT}/.clusters/bin/openshift-install-rhel9-${LOCAL_ARCH_SHORT}"
  [[ "$OS" == darwin ]] && USE_CONTAINER_FIPS=true
else
  INSTALL_BIN="${REPO_ROOT}/.clusters/bin/openshift-install-${LOCAL_ARCH_SHORT}"
fi

if [[ ! -x "$INSTALL_BIN" ]] || [[ "${FORCE_DOWNLOAD:-}" == true ]]; then
  mkdir -p "$(dirname "$INSTALL_BIN")"

  if [[ "$FIPS" == true ]]; then
    echo "Downloading FIPS-capable RHEL9 installer"
    ARCHIVE="openshift-install-rhel9-${LOCAL_ARCH_SHORT}.tar.gz"
  else
    case "${OS}-${LOCAL_ARCH_SHORT}" in
      darwin-arm64) ARCHIVE="openshift-install-mac-arm64.tar.gz" ;;
      darwin-amd64) ARCHIVE="openshift-install-mac.tar.gz" ;;
      linux-*)      ARCHIVE="openshift-install-linux.tar.gz" ;;
      *) die "Unsupported OS/arch: ${OS}/${LOCAL_ARCH_SHORT}" ;;
    esac
  fi

  DL_URL="${MIRROR}/${LOCAL_ARCH_SHORT}/clients/ocp/${OCP_VERSION}/${ARCHIVE}"
  echo "=== Downloading openshift-install ==="
  echo "  URL: ${DL_URL}"
  if [[ "$FIPS" == true ]]; then
    curl -sfL "$DL_URL" | tar xz -C "$(dirname "$INSTALL_BIN")" openshift-install-fips
    mv "$(dirname "$INSTALL_BIN")/openshift-install-fips" "$INSTALL_BIN"
  else
    curl -sfL "$DL_URL" | tar xz -C "$(dirname "$INSTALL_BIN")" openshift-install
    mv "$(dirname "$INSTALL_BIN")/openshift-install" "$INSTALL_BIN"
  fi
  chmod +x "$INSTALL_BIN"
fi

# FIPS on Mac: the RHEL9 binary is Linux ELF, needs podman/docker to run
if [[ "${USE_CONTAINER_FIPS:-}" == true ]]; then
  CONTAINER_RT=$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)
  [[ -n "$CONTAINER_RT" ]] || die "FIPS on macOS requires podman or docker"
  echo "=== FIPS: will run RHEL9 binary via ${CONTAINER_RT} ==="
fi

run_installer() {
  if [[ "${USE_CONTAINER_FIPS:-}" == true ]]; then
    local mounts=(-v "$INSTALL_BIN:/usr/local/bin/openshift-install:Z")
    [[ -d "${INSTALL_DIR:-}" ]] && mounts+=(-v "$INSTALL_DIR:/install-dir:Z")
    local fips_flag="${REPO_ROOT}/.clusters/bin/.fips_enabled"
    echo 1 > "$fips_flag"
    local aws_env=()
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && aws_env+=(-e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}")
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && aws_env+=(-e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}")
    if [[ -f ~/.aws/credentials ]]; then
      aws_env+=(-v "$HOME/.aws:/root/.aws:ro")
      local aws_profile="${AWS_PROFILE:-$(sed -n 's/^\[//;s/\]//p' ~/.aws/credentials | head -1)}"
      [[ "$aws_profile" != "default" && -n "$aws_profile" ]] && aws_env+=(-e "AWS_PROFILE=${aws_profile}")
    fi
    $CONTAINER_RT run --rm "${mounts[@]}" \
      -v "$fips_flag:/proc/sys/crypto/fips_enabled:ro" \
      "${aws_env[@]}" \
      -e "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" \
      --platform "linux/${LOCAL_ARCH_SHORT}" \
      registry.access.redhat.com/ubi9/ubi-minimal:latest \
      /usr/local/bin/openshift-install "$@"
  else
    "$INSTALL_BIN" "$@"
  fi
}

echo "=== openshift-install version ==="
run_installer version 2>&1

# --- Set multi-arch release override for cross-arch provisioning ---
if [[ "$TARGET_ARCH" != "$LOCAL_ARCH_SHORT" ]]; then
  echo ""
  echo "=== Cross-arch provisioning: ${LOCAL_ARCH_SHORT} → ${TARGET_ARCH} ==="
  OCP_VER=$(curl -sL "${MIRROR}/${LOCAL_ARCH_SHORT}/clients/ocp/${OCP_VERSION}/release.txt" \
    | sed -n 's/^Name:[[:space:]]*//p' | head -1) || true
  if [[ -n "$OCP_VER" ]]; then
    MULTI_IMAGE="quay.io/openshift-release-dev/ocp-release:${OCP_VER}-multi"
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$MULTI_IMAGE"
    echo "  Using multi-arch release: ${MULTI_IMAGE}"
  else
    die "Could not determine OCP version for multi-arch release"
  fi
fi

# --- Generate install-config.yaml ---
mkdir -p "$INSTALL_DIR"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$INSTALL_DIR/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
- architecture: ${TARGET_ARCH}
  hyperthreading: Enabled
  name: worker
  replicas: ${WORKERS}
  platform:
    aws:
      type: ${WORKER}
controlPlane:
  architecture: ${TARGET_ARCH}
  hyperthreading: Enabled
  name: master
  replicas: 3
  platform:
    aws:
      type: ${MASTER}
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${REGION}
    userTags:
      pipelines-ci: "true"
      installer: local-provision
      cluster-name: "${CLUSTER_NAME}"
      created-at: "${CREATED_AT}"
      created-by: "$(whoami)@$(hostname -s)"
      owner: "$(whoami)"
      cluster-lifetime: "${LIFETIME}"
fips: ${FIPS}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_PUBLIC_KEY}'
EOF

# Save a backup of install-config (openshift-install consumes it)
cp "$INSTALL_DIR/install-config.yaml" "$INSTALL_DIR/install-config.yaml.bak"

echo ""
echo "=== install-config.yaml ==="
grep -E "baseDomain|name:|architecture|type:|region|fips|replicas" "$INSTALL_DIR/install-config.yaml"

echo ""
echo "=== Creating cluster ${CLUSTER_NAME} ==="
if [[ "${USE_CONTAINER_FIPS:-}" == true ]]; then
  run_installer create cluster --dir=/install-dir --log-level=info 2>&1 | tee "$INSTALL_DIR/install.log"
else
  run_installer create cluster --dir="$INSTALL_DIR" --log-level=info 2>&1 | tee "$INSTALL_DIR/install.log"
fi

# --- Post-install summary ---
echo ""
echo "============================================================"
echo "  Cluster Ready!"
echo "============================================================"
KUBECONFIG_PATH="$INSTALL_DIR/auth/kubeconfig"
export KUBECONFIG="$KUBECONFIG_PATH"

API_URL=$(oc whoami --show-server 2>/dev/null || grep -o 'https://api\.[^ ]*' "$INSTALL_DIR/install.log" | head -1)
CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "unknown")
KUBEADMIN_PASS=$(cat "$INSTALL_DIR/auth/kubeadmin-password" 2>/dev/null || echo "unknown")

echo "  API:        ${API_URL}"
echo "  Console:    ${CONSOLE_URL}"
echo "  kubeadmin:  ${KUBEADMIN_PASS}"
echo "  KUBECONFIG: ${KUBECONFIG_PATH}"
echo ""
echo "  Login:  oc login -u kubeadmin -p '${KUBEADMIN_PASS}' ${API_URL} --insecure-skip-tls-verify"
echo ""
echo "  Destroy: $0 --destroy"
echo "    or:    openshift-install destroy cluster --dir=${INSTALL_DIR}"
echo ""

# Write connection info for env/.env
cat > "$INSTALL_DIR/cluster.env" <<EOF
# Generated by provision-cluster-local.sh on $(date)
APISERVER=${API_URL}
KUBEADMIN_PASSWORD=${KUBEADMIN_PASS}
KUBEADMIN_USER=kubeadmin
CLUSTER_NAME=${CLUSTER_NAME}
INSTALLER=none
EOF

echo "  Cluster .env snippet saved to: ${INSTALL_DIR}/cluster.env"
echo "  Copy into env/.env:  cat ${INSTALL_DIR}/cluster.env >> env/.env"
echo "============================================================"
