#!/usr/bin/env bash
# K8s secrets from env/.env (CRED_SOURCE=local) or Vault (CRED_SOURCE=vault / --vault-login).
[[ -z "${BASH_VERSION:-}" ]] && exec /usr/bin/env bash "$0" "$@"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SECRETS_DIR="$REPO_ROOT/secrets"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/env/.env}"
NAMESPACE="${NAMESPACE:-pipelines-ci}"
FORCE_VAULT_LOGIN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-login) FORCE_VAULT_LOGIN=true; CRED_SOURCE=vault; shift ;;
    -h|--help)
      echo "Usage: $0 [--vault-login]"
      echo "  local:  CRED_SOURCE=local — secrets from non-empty env/.env vars"
      echo "  vault:  CRED_SOURCE=vault or --vault-login — OIDC login + Vault KV"
      exit 0 ;;
    *) echo "ERROR: unknown arg: $1 (try --help)" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
need() { for v in "$@"; do [[ -n "${!v:-}" ]] || return 1; done; }
need_any() { for v in "$@"; do [[ -n "${!v:-}" ]] && return 0; done; return 1; }
b64() { [[ "$OSTYPE" == darwin* ]] && base64 || base64 -w 0; }

update_env_var() {
  local key="$1" val="$2" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/env.XXXXXX")
  if grep -q "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v line="${key}=${val}" 'BEGIN{d=0} $0~"^"k"="{print line;d=1;next} {print} END{if(!d)print line}' "$ENV_FILE" >"$tmp"
  else
    cp "$ENV_FILE" "$tmp" && printf '\n%s=%s\n' "$key" "$val" >>"$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
}

apply_secret() { "$@" | oc apply -n "$NAMESPACE" -f -; CREATED=$((CREATED + 1)); }

unset_env_secret_vars() {
  local var
  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    case "$var" in
      CRED_SOURCE|VAULT_ADDR|VAULT_TOKEN|VAULT_KV_MOUNT|VAULT_KV_PATH) continue ;;
    esac
    unset "$var" 2>/dev/null || true
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | sed -n '/^GITHUB_TOKEN=/,$p' | cut -d= -f1)
  unset ssh_privatekey ENCODED_GITHUB_APP_ID ENCODED_GITHUB_APP_PRIVATE_KEY \
        ENCODED_GITHUB_WEBHOOK_SECRET GITHUB_WEBHOOK_TOKEN 2>/dev/null || true
}

apply_pac_aliases() {
  : "${PAC_GITHUB_TOKEN:=${GITHUB_TOKEN:-}}"
  : "${PAC_GITHUB_WEBHOOK_TOKEN:=${PAC_GITHUB_WEBHOOK_TOKEN:-${GITHUB_WEBHOOK_TOKEN:-}}}"
}

vault_sync() {
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.ci.openshift.org}"
  export VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-kv}"
  export VAULT_KV_PATH="${VAULT_KV_PATH:-selfservice/openshift-pipelines/osp-ci-secrets}"
  local kv="${VAULT_KV_MOUNT}/${VAULT_KV_PATH}" json errf

  if [[ "$FORCE_VAULT_LOGIN" == true || -z "${VAULT_TOKEN:-}" ]] \
     || ! vault kv get -format=json "$kv" >/dev/null 2>&1; then
    command -v vault >/dev/null || die "vault CLI required — https://developer.hashicorp.com/vault/install"
    unset VAULT_TOKEN
    echo "=== Vault OIDC (${VAULT_ADDR}) ===" >&2
    VAULT_TOKEN=$(vault login -method=oidc -field=token) || die "vault login failed"
    [[ -n "$VAULT_TOKEN" ]] || die "vault login returned no token"
    export VAULT_TOKEN CRED_SOURCE=vault
    vault kv get -format=json "$kv" >/dev/null || die "cannot read $kv — request openshift-pipelines Vault access"
    for k in VAULT_ADDR VAULT_TOKEN CRED_SOURCE VAULT_KV_MOUNT VAULT_KV_PATH; do update_env_var "$k" "${!k}"; done
    echo "Vault OK; token saved to ${ENV_FILE}" >&2
  fi
  export VAULT_TOKEN

  errf=$(mktemp "${TMPDIR:-/tmp}/v.XXXXXX")
  json=$(vault kv get -format=json "$kv" 2>"$errf") || {
    echo "ERROR: vault kv get $kv failed" >&2; [[ -s "$errf" ]] && cat "$errf" >&2
    rm -f "$errf"; return 1
  }
  rm -f "$errf"
  unset_env_secret_vars
  VAULT_JSON="$json" python3 <<'PY'
import json, os, re
data = json.loads(os.environ["VAULT_JSON"]).get("data", {}).get("data") or {}
if not data: raise SystemExit("ERROR: Vault returned no data keys")
ident = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
for key, val in sorted(data.items()):
    if val is None or not ident.match(key): continue
    s = str(val).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    print(f'export {key}="{s}"')
PY
}

[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE (cp env/env.template env/.env)"
set -a; source "$ENV_FILE"; set +a
[[ "$FORCE_VAULT_LOGIN" == true ]] && CRED_SOURCE=vault

CRED_SOURCE=$(printf '%s' "${CRED_SOURCE:-local}" | tr '[:upper:]' '[:lower:]')
case "$CRED_SOURCE" in local|vault) ;; *) die "CRED_SOURCE must be local or vault (got: $CRED_SOURCE)" ;; esac

if [[ "$CRED_SOURCE" == vault ]]; then
  eval "$(vault_sync)" || die "failed to load secrets from Vault"
fi
apply_pac_aliases

command -v oc >/dev/null || die "oc CLI required"
if oc get namespace "$NAMESPACE" &>/dev/null; then
  echo "Namespace ${NAMESPACE} exists"
else
  echo "Creating namespace ${NAMESPACE}..."
  oc new-project "$NAMESPACE"
fi

CREATED=0
echo "=== Creating secrets in $NAMESPACE (CRED_SOURCE=$CRED_SOURCE) ==="

need AWS_ACCESS_KEY AWS_ACCESS_SECRET && apply_secret sed \
  -e "s/\$AWS_ACCESS_KEY_ID/${AWS_ACCESS_KEY}/" -e "s/\$AWS_SECRET_ACCESS_KEY/${AWS_ACCESS_SECRET}/" \
  "$SECRETS_DIR/aws.yaml"

need GITHUB_TOKEN && apply_secret sed -e "s|\$GITHUB_TOKEN|${GITHUB_TOKEN}|" "$SECRETS_DIR/github.yaml"

need_any PAC_GITHUB_TOKEN PAC_GITHUB_ORG PAC_GITHUB_WEBHOOK_TOKEN && apply_secret sed \
  -e "s|\$PAC_GITHUB_TOKEN|${PAC_GITHUB_TOKEN:-}|" -e "s|\$PAC_GITHUB_ORG|${PAC_GITHUB_ORG:-}|" \
  -e "s|\$PAC_GITHUB_WEBHOOK_TOKEN|${PAC_GITHUB_WEBHOOK_TOKEN:-}|" "$SECRETS_DIR/pac-github-token.yaml"

need_any GITLAB_TOKEN GITLAB_GROUP_NAMESPACE GITLAB_PROJECT_ID GITLAB_WEBHOOK_TOKEN && apply_secret sed \
  -e "s/\$GITLAB_TOKEN/${GITLAB_TOKEN:-}/" -e "s/\$GITLAB_GROUP_NAMESPACE/${GITLAB_GROUP_NAMESPACE:-}/" \
  -e "s/\$GITLAB_PROJECT_ID/${GITLAB_PROJECT_ID:-}/" -e "s/\$GITLAB_WEBHOOK_TOKEN/${GITLAB_WEBHOOK_TOKEN:-}/" \
  "$SECRETS_DIR/pac-gitlab.yaml"

need ssh_privatekey && apply_secret sed \
  -e "s/\$ENCODED_GITLAB_SSH_PRIVATE_KEY/$(echo -n "$ssh_privatekey" | b64)/" \
  "$SECRETS_DIR/gitlab-ssh-private-key.yaml"

need_any ENCODED_GITHUB_APP_ID ENCODED_GITHUB_APP_PRIVATE_KEY ENCODED_GITHUB_WEBHOOK_SECRET && apply_secret sed \
  -e "s/\$ENCODED_GITHUB_APP_PRIVATE_KEY/${ENCODED_GITHUB_APP_PRIVATE_KEY:-}/" \
  -e "s/\$ENCODED_GITHUB_WEBHOOK_SECRET/${ENCODED_GITHUB_WEBHOOK_SECRET:-}/" \
  -e "s/\$ENCODED_GITHUB_APP_ID/${ENCODED_GITHUB_APP_ID:-}/" "$SECRETS_DIR/pac-github.yaml"

need_any BREW_USER BREW_PASS QUAY_USER QUAY_PASS QUAY_API_TOKEN && apply_secret sed \
  -e "s/\$BREW_USER/${BREW_USER:-}/" -e "s/\$BREW_PASS/${BREW_PASS:-}/" \
  -e "s/\$QUAY_USER/${QUAY_USER:-}/" -e "s/\$QUAY_PASS/${QUAY_PASS:-}/" \
  -e "s/\$QUAY_API_TOKEN/${QUAY_API_TOKEN:-}/" "$SECRETS_DIR/p12n.yaml"

if need QUAY_USER QUAY_PASS; then
  QUAY_AUTH=$(echo -n "${QUAY_USER}:${QUAY_PASS}" | b64)
  apply_secret sed -e "s/\$QUAY_AUTH/${QUAY_AUTH}/" "$SECRETS_DIR/quay-io-dockerconfig.yaml"
  apply_secret sed -e "s/\$QUAY_USER/${QUAY_USER}/" -e "s/\$QUAY_PASS/${QUAY_PASS}/" \
    "$SECRETS_DIR/skopeo-copy-quay-creds.yaml"
fi

need MAC_HOSTNAME MAC_USERNAME MAC_PASSWORD && apply_secret sed \
  -e "s|\$MAC_HOSTNAME|${MAC_HOSTNAME}|" -e "s|\$MAC_USERNAME|${MAC_USERNAME}|" \
  -e "s|\$MAC_PASSWORD|${MAC_PASSWORD}|" "$SECRETS_DIR/mac-mini.yaml"

need POLARION_USERNAME POLARION_PASSWORD POLARION_PROJECT && apply_secret sed \
  -e "s/\$POLARION_USERNAME/${POLARION_USERNAME}/" -e "s/\$POLARION_PASSWORD/${POLARION_PASSWORD}/" \
  -e "s/\$POLARION_PROJECT/${POLARION_PROJECT}/" "$SECRETS_DIR/polarion.yaml"

need RP_URL RP_PROJECT RP_ROBOT_UUID && apply_secret sed \
  -e "s|\$RP_URL|${RP_URL}|" -e "s|\$RP_ROBOT_UUID|${RP_ROBOT_UUID}|" \
  -e "s|\$RP_PROJECT|${RP_PROJECT}|" -e "s|\$RP_SUPERADMIN_UUID|${RP_SUPERADMIN_UUID:-}|" \
  "$SECRETS_DIR/reportportal.yaml"

need SUBSCRIPTION_USERNAME SUBSCRIPTION_PASSWORD && apply_secret sed \
  -e "s|\$SUBSCRIPTION_USERNAME|${SUBSCRIPTION_USERNAME}|" \
  -e "s|\$SUBSCRIPTION_PASSWORD|${SUBSCRIPTION_PASSWORD}|" "$SECRETS_DIR/rhel-subscription.yaml"

need SLACK_WEBHOOK_URL && apply_secret sed -e "s|\$SLACK_WEBHOOK_URL|${SLACK_WEBHOOK_URL}|" "$SECRETS_DIR/slack.yaml"

need UPLOADER_USERNAME UPLOADER_PASSWORD UPLOADER_HOST && apply_secret sed \
  -e "s|\$UPLOADER_USERNAME|${UPLOADER_USERNAME}|" -e "s|\$UPLOADER_PASSWORD|${UPLOADER_PASSWORD}|" \
  -e "s|\$UPLOADER_HOST|${UPLOADER_HOST}|" "$SECRETS_DIR/uploader.yaml"

# GCS artifact storage — pulls SA key from env/.env (GCS_SA_KEY_JSON) or Vault (GCS-TOKEN)
_gcs_json=""
if [[ -n "${GCS_SA_KEY_JSON:-}" ]]; then
  _gcs_json="$GCS_SA_KEY_JSON"
elif command -v vault &>/dev/null && [[ -n "${VAULT_TOKEN:-}" ]]; then
  _gcs_json=$(vault kv get -format=json "${VAULT_KV_MOUNT:-kv}/${VAULT_KV_PATH:-selfservice/openshift-pipelines/osp-ci-secrets}" \
    2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data'].get('GCS-TOKEN',''))" 2>/dev/null) || true
fi

if [[ -n "$_gcs_json" ]]; then
  echo "Creating gcs-artifacts secret..."
  _tmpkey=$(mktemp)
  printf '%s' "$_gcs_json" > "$_tmpkey"
  oc create secret generic gcs-artifacts \
    --from-file=sa-key.json="$_tmpkey" \
    --from-literal=bucket="${GCS_BUCKET:-ospqa-ci-artifacts}" \
    --from-literal=project="${GCS_PROJECT:-pipelines-qe}" \
    --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -
  rm -f "$_tmpkey"
  CREATED=$((CREATED + 1))
else
  if oc get secret gcs-artifacts -n "$NAMESPACE" &>/dev/null; then
    echo "  gcs-artifacts secret already exists"
  else
    echo "  WARNING: GCS-TOKEN not found in Vault and GCS_SA_KEY_JSON not set"
    echo "  Add the GCS SA key JSON as GCS-TOKEN in Vault: ${VAULT_KV_MOUNT:-kv}/${VAULT_KV_PATH:-selfservice/openshift-pipelines/osp-ci-secrets}"
  fi
fi

# AWS IPI provisioning secrets (INSTALLER=aws-ipi)
if [[ "$(printf '%s' "${INSTALLER:-none}" | tr '[:upper:]' '[:lower:]')" == aws-ipi ]]; then
  need AWS_ACCESS_KEY AWS_ACCESS_SECRET || die "INSTALLER=aws-ipi requires AWS_ACCESS_KEY + AWS_ACCESS_SECRET (set in env/.env or Vault)"

  echo "Creating aws-creds secret for INSTALLER=aws-ipi..."
  oc create secret generic aws-creds \
    --from-literal=aws-access-key-id="${AWS_ACCESS_KEY}" \
    --from-literal=aws-secret-access-key="${AWS_ACCESS_SECRET}" \
    --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -
  CREATED=$((CREATED + 1))

  # Pull secret: .env → management cluster's openshift-config/pull-secret
  _PULL="${PULL_SECRET:-}"
  if [[ -z "$_PULL" ]]; then
    echo "  PULL_SECRET not in env/.env — extracting from cluster openshift-config/pull-secret..."
    _PULL=$(oc get secret pull-secret -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d) || true
  fi
  [[ -n "$_PULL" ]] || die "PULL_SECRET required: set in env/.env or ensure openshift-config/pull-secret exists on management cluster"

  # SSH public key: env/.env → Vault ssh-publickey
  _SSH="${SSH_PUBLIC_KEY:-}"
  if [[ -z "$_SSH" ]] && [[ -n "${ssh_publickey:-}" ]]; then
    _SSH="$ssh_publickey"
  fi
  # Vault stores it as ssh-publickey (with hyphen); try the env var that vault_sync would set
  if [[ -z "$_SSH" ]] && command -v vault &>/dev/null && [[ -n "${VAULT_TOKEN:-}" ]]; then
    echo "  SSH_PUBLIC_KEY not in env/.env — extracting from Vault ssh-publickey..."
    _SSH=$(vault kv get -format=json "${VAULT_KV_MOUNT:-kv}/${VAULT_KV_PATH:-selfservice/openshift-pipelines/osp-ci-secrets}" \
      2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['ssh-publickey'])" 2>/dev/null) || true
  fi
  [[ -n "$_SSH" ]] || die "SSH_PUBLIC_KEY required: set in env/.env or store ssh-publickey in Vault"

  echo "Creating aws-install-config secret (pull-secret: ${#_PULL} chars, ssh-key: ${#_SSH} chars)..."
  oc create secret generic aws-install-config \
    --from-literal=pull-secret="${_PULL}" \
    --from-literal=ssh-public-key="${_SSH}" \
    --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -
  CREATED=$((CREATED + 1))
fi

# ARO provisioning secrets (INSTALLER=aro)
if [[ "$(printf '%s' "${INSTALLER:-none}" | tr '[:upper:]' '[:lower:]')" == aro ]]; then
  # Azure creds: .env → Vault
  _AZ_TENANT="${AZURE_TENANT:-}"
  _AZ_USER="${AZURE_USERNAME:-}"
  _AZ_PASS="${AZURE_PASSWORD:-}"

  if [[ -z "$_AZ_TENANT" || -z "$_AZ_USER" || -z "$_AZ_PASS" ]] && command -v vault &>/dev/null && [[ -n "${VAULT_TOKEN:-}" ]]; then
    echo "Azure creds not in env/.env — extracting from Vault..."
    _vault_json=$(vault kv get -format=json "${VAULT_KV_MOUNT:-kv}/${VAULT_KV_PATH:-selfservice/openshift-pipelines/osp-ci-secrets}" 2>/dev/null || true)
    if [[ -n "$_vault_json" ]]; then
      [[ -z "$_AZ_TENANT" ]] && _AZ_TENANT=$(echo "$_vault_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data'].get('AZURE_TENANT',''))" 2>/dev/null || true)
      [[ -z "$_AZ_USER" ]] && _AZ_USER=$(echo "$_vault_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data'].get('AZURE_USERNAME',''))" 2>/dev/null || true)
      [[ -z "$_AZ_PASS" ]] && _AZ_PASS=$(echo "$_vault_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data'].get('AZURE_PASSWORD',''))" 2>/dev/null || true)
    fi
  fi
  [[ -n "$_AZ_TENANT" && -n "$_AZ_USER" && -n "$_AZ_PASS" ]] \
    || die "INSTALLER=aro requires AZURE_TENANT, AZURE_USERNAME, AZURE_PASSWORD (set in env/.env or Vault)"

  echo "Creating azure-creds secret..."
  oc create secret generic azure-creds \
    --from-literal=azure-tenant="${_AZ_TENANT}" \
    --from-literal=azure-username="${_AZ_USER}" \
    --from-literal=azure-password="${_AZ_PASS}" \
    --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -
  CREATED=$((CREATED + 1))

  # Pull secret for ARO (reuses same logic as aws-ipi)
  _PULL="${PULL_SECRET:-}"
  if [[ -z "$_PULL" ]]; then
    echo "  PULL_SECRET not in env/.env — extracting from cluster openshift-config/pull-secret..."
    _PULL=$(oc get secret pull-secret -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d) || true
  fi
  if [[ -n "$_PULL" ]]; then
    echo "Creating aws-install-config secret for pull-secret (${#_PULL} chars)..."
    oc create secret generic aws-install-config \
      --from-literal=pull-secret="${_PULL}" \
      --from-literal=ssh-public-key="" \
      --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -
    CREATED=$((CREATED + 1))
  fi
fi

# --- Cluster connection secret ---
source "$SCRIPT_DIR/cluster-login.sh"
if [[ -n "${CLUSTER_NAME:-}" && -n "${APISERVER:-}" ]]; then
  _secret="cluster-${CLUSTER_NAME#cluster-}"
  if oc get secret "$_secret" -n "$NAMESPACE" &>/dev/null; then
    echo "Cluster secret ${_secret} already exists"
  else
    validate_cluster_env || die "cluster env validation failed"
    cluster_login || die "cluster login failed"
    oc create secret generic "$_secret" \
      --from-literal=admin-name="$(cluster_admin_name)" \
      --from-literal=api-url="${APISERVER}" \
      --from-literal=admin-token="$(cluster_admin_token)" \
      --from-literal=kubeadmin-password="${KUBEADMIN_PASSWORD:-}" \
      --from-literal=user-password="${USER_PASSWORD:-user}" \
      --from-literal=insecure-skip-tls-verify=true \
      --from-literal=installer="${INSTALLER:-none}" \
      --from-literal=mirror-reg=quay.io \
      -n "$NAMESPACE"
    oc label secret "$_secret" keep-cluster=true -n "$NAMESPACE" --overwrite
    echo "Created cluster secret ${_secret}"
    CREATED=$((CREATED + 1))
  fi
fi

# --- Global pull-secret update (stage/pre-stage registries) ---
_env="${OPERATOR_ENVIRONMENT:-${UPGRADE_OPERATOR_ENVIRONMENT:-${PRE_UPGRADE_OPERATOR_ENVIRONMENT:-prod}}}"
if [[ "$_env" == stage || "$_env" == pre-stage ]]; then
  _tmpps=$(mktemp)
  oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
    | base64 -d > "$_tmpps" 2>/dev/null || true
  if [[ -s "$_tmpps" ]]; then
    _q_user="${QUAY_USER:-}" _q_pass="${QUAY_PASS:-}"
    _b_user="${BREW_USER:-}" _b_pass="${BREW_PASS:-}"
    _s_user="${STAGE_REGISTRY_USER:-${SUBSCRIPTION_USERNAME:-}}"
    _s_pass="${STAGE_REGISTRY_PASS:-${SUBSCRIPTION_PASSWORD:-}}"

    _result=$(_QU="$_q_user" _QP="$_q_pass" _BU="$_b_user" _BP="$_b_pass" \
      _SU="$_s_user" _SP="$_s_pass" _INST="${INSTALLER:-none}" \
      python3 - "$_tmpps" << 'PYEOF'
import json, os, base64, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
auths = d.setdefault('auths', {})
changed = False
installer = os.environ.get('_INST', 'none').lower()
def add_if_missing(reg, u, p):
    global changed
    if not u or not p: return
    if reg in auths: return
    a = base64.b64encode(f'{u}:{p}'.encode()).decode()
    auths[reg] = {'auth': a}
    changed = True
    print(f'  {reg}: configured')
def ensure_auth(reg, u, p):
    global changed
    if not u or not p: return
    a = base64.b64encode(f'{u}:{p}'.encode()).decode()
    if auths.get(reg, {}).get('auth') == a: return
    auths[reg] = {'auth': a}
    changed = True
    print(f'  {reg}: configured')
fn = add_if_missing if installer == 'cluster-bot' else ensure_auth
fn('brew.registry.redhat.io', os.environ.get('_BU',''), os.environ.get('_BP',''))
fn('registry.stage.redhat.io', os.environ.get('_SU',''), os.environ.get('_SP',''))
if changed:
    with open(sys.argv[1], 'w') as f: json.dump(d, f)
    print('UPDATED')
else:
    print('NO_CHANGE')
PYEOF
    )
    echo "$_result" | grep -v "UPDATED\|NO_CHANGE" || true
    if echo "$_result" | grep -q UPDATED; then
      oc set data secret/pull-secret -n openshift-config --from-file=".dockerconfigjson=$_tmpps" >/dev/null 2>&1 \
        && echo "  global pull-secret updated" \
        || echo "  WARNING: failed to update global pull-secret"
    fi
  fi
  rm -f "$_tmpps"
fi

[[ "$CREATED" -eq 0 ]] \
  && echo "No secrets created. Set CRED_SOURCE=local with secret vars in env/.env, or CRED_SOURCE=vault." \
  || echo "Created/updated $CREATED secret(s) in $NAMESPACE"
