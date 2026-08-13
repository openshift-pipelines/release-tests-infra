#!/usr/bin/env bash

is_existing_cluster() {
  case "$(printf '%s' "${INSTALLER:-none}" | tr '[:upper:]' '[:lower:]')" in
    none|cluster-platforms|cluster-platform|cp) return 0 ;; *) return 1 ;; esac
}

is_provisioned_installer() {
  case "$(printf '%s' "${INSTALLER:-none}" | tr '[:upper:]' '[:lower:]')" in
    aws-ipi|rosa|aro|flexy) return 0 ;; *) return 1 ;; esac
}

validate_cluster_env() {
  [[ -n "${APISERVER:-}" ]] || { echo "ERROR: APISERVER required in env/.env" >&2; return 1; }
  [[ -n "${KUBEADMIN_PASSWORD:-}" || -n "${OC_TOKEN:-}" ]] || {
    echo "ERROR: KUBEADMIN_PASSWORD or OC_TOKEN required in env/.env" >&2
    return 1
  }
}

validate_cluster_env_or_provisioned() {
  if is_provisioned_installer; then
    echo "INSTALLER=${INSTALLER} — cluster will be provisioned by pipeline"
    return 0
  fi
  validate_cluster_env
}

cluster_login() {
  validate_cluster_env || return 1
  if [[ -n "${KUBEADMIN_PASSWORD:-}" ]]; then
    echo "Logging in to ${APISERVER} as ${KUBEADMIN_USER:-kubeadmin}..."
    oc login -u "${KUBEADMIN_USER:-kubeadmin}" -p "$KUBEADMIN_PASSWORD" \
      "$APISERVER" --insecure-skip-tls-verify=true
  elif [[ -n "${OC_TOKEN:-}" ]]; then
    echo "Logging in to ${APISERVER} with OC_TOKEN..."
    oc login --server="${APISERVER}" --token="${OC_TOKEN}" --insecure-skip-tls-verify=true
  fi
  echo "  Authenticated as $(oc whoami)"
}

cluster_admin_name() {
  echo "${KUBEADMIN_USER:-kubeadmin}"
}

cluster_admin_token() {
  validate_cluster_env || return 1
  if [[ -n "${OC_TOKEN:-}" ]]; then
    printf '%s' "$OC_TOKEN"
  else
    oc whoami -t
  fi
}

validate_operator_env() {
  local env="${OPERATOR_ENVIRONMENT:-prod}" src="${CATALOG_SOURCE:-redhat-operators}"
  local idx="${KONFLUX_INDEX_IMAGE:-}"
  case "${env,,}" in
    prod)
      if [[ "$src" != "redhat-operators" ]]; then
        echo "ERROR: OPERATOR_ENVIRONMENT=prod requires CATALOG_SOURCE=redhat-operators (got: ${src})" >&2
        return 1
      fi
      ;;
    stage|pre-stage)
      if [[ "$src" == "redhat-operators" ]]; then
        echo "ERROR: OPERATOR_ENVIRONMENT=${env} requires CATALOG_SOURCE=custom-operators (got: ${src})" >&2
        return 1
      fi
      if [[ -z "$idx" ]]; then
        echo "ERROR: OPERATOR_ENVIRONMENT=${env} requires KONFLUX_INDEX_IMAGE to be set" >&2
        return 1
      fi
      ;;
    *)
      echo "ERROR: OPERATOR_ENVIRONMENT must be prod, stage, or pre-stage (got: ${env})" >&2
      return 1
      ;;
  esac
}

cluster_secret_name() {
  [[ -n "${CLUSTER_NAME:-}" ]] || return 1
  printf 'cluster-%s' "${CLUSTER_NAME#cluster-}"
}

cluster_secret_exists() {
  local secret ns="${1:-${NAMESPACE:-pipelines-ci}}"
  secret="$(cluster_secret_name)" || return 1
  oc get secret "$secret" -n "$ns" &>/dev/null
}
