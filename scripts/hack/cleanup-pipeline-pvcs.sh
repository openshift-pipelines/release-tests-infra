#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/env/.env}"

NAMESPACE="${NAMESPACE:-pipelines-ci}"
ALL_NAMESPACES=false
DRY_RUN=false
FORCE=false
MODE=""
PIPELINERUN=""
INCLUDE_LEGACY=false
PRUNE_COMPLETED_PODS=false
INCLUDE_PLATFORM_NAMESPACES=false
PVC_WAIT_TIMEOUT="${PVC_WAIT_TIMEOUT:-180s}"
VERIFY=true

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes) return 0 ;;
    *) return 1 ;;
  esac
}

scope_message() {
  if is_true "$ALL_NAMESPACES"; then
    echo "cluster-wide"
  else
    echo "in namespace ${NAMESPACE}"
  fi
}

usage() {
  cat <<EOF
Usage: $0 [options]

Delete PVCs from acceptance-tests PipelineRuns (per-run volumeClaimTemplate).

  --archive              Wait for completion, delete PipelineRun, remove PVCs, verify
  --pipelinerun NAME     Delete workspace PVC(s) for a PipelineRun (PR may already be deleted)
  --finished             Archive completed PipelineRuns (delete PR + PVCs) in namespace
  --all                  Delete all PVCs in namespace (use --force to confirm)
  --include-legacy       Also delete release-tests-toolchain-cache if present
  --legacy-only          Delete release-tests-toolchain-cache only (deprecated shared PVC)
  --prune-completed-pods Delete Succeeded/Failed pods first (unblocks stuck PVCs)

Options:
  --namespace NS         Target namespace (default: pipelines-ci)
  --all-namespaces       With --all, scan every namespace (requires --force)
  --include-platform-namespaces
                         Also delete PVCs in openshift/kube platform namespaces
  --no-wait              With --archive, skip wait (PipelineRun already finished)
  --dry-run              Print actions without deleting
  --force                Required for --all and --all-namespaces
  --no-verify            Skip post-delete wait and verification (not recommended)
  -h, --help             Show this help

Examples:
  $0 --archive --pipelinerun acceptance-tests-ginkgo-abc12
  $0 --pipelinerun acceptance-tests-ginkgo-abc12
  $0 --finished
  $0 --all --force
  $0 --all-namespaces --all --force
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# PVC names for a PipelineRun (labels work even after the PipelineRun is deleted).
pipelinerun_pvcs() {
  local ns=$1 pr=$2 uid=${3:-}
  if [[ -z "$uid" ]]; then
    uid=$(oc get pipelinerun "$pr" -n "$ns" -o jsonpath='{.metadata.uid}' 2>/dev/null) || true
  fi
  oc get pvc -n "$ns" -o json | jq -r --arg pr "$pr" --arg uid "$uid" '
    .items[] | select(
      (.metadata.labels["tekton.dev/pipelineRun"] // "") == $pr
      or ((.metadata.ownerReferences // []) | any(.kind == "PipelineRun" and (.name == $pr or ($uid != "" and .uid == $uid))))
    ) | .metadata.name'
}

delete_pvcs() {
  local ns=$1; shift
  local pvc
  for pvc in "$@"; do
    [[ -n "$pvc" ]] || continue
    if is_true "$DRY_RUN"; then
      echo "  [dry-run] would delete pvc/${pvc} -n ${ns}"
    else
      echo "  deleting pvc/${pvc} -n ${ns}"
      oc delete pvc "$pvc" -n "$ns" --wait=false --ignore-not-found
      if is_true "$VERIFY"; then
        wait_for_pvc_gone "$ns" "$pvc" || failed_pvcs+=("${ns}/${pvc}")
      fi
    fi
  done
}

is_platform_namespace() {
  local ns=$1
  [[ "$ns" == openshift* || "$ns" == kube-* || "$ns" == "default" ]]
}

namespace_excluded() {
  local ns=$1
  if is_true "$INCLUDE_PLATFORM_NAMESPACES"; then
    return 1
  fi
  is_platform_namespace "$ns"
}

prune_pods_for_pvc() {
  local ns=$1 pvc=$2
  mapfile -t pods < <(
    oc get pods -n "$ns" -o json 2>/dev/null | jq -r --arg pvc "$pvc" '
      .items[] | select(
        (.spec.volumes // []) | any(.persistentVolumeClaim.claimName == $pvc)
      ) | .metadata.name'
  )
  [[ ${#pods[@]} -eq 0 ]] && return 0
  echo "    unblocking ${pvc}: deleting ${#pods[@]} pod(s) still referencing it"
  for pod in "${pods[@]}"; do
    oc delete pod "$pod" -n "$ns" --wait=false --ignore-not-found
  done
}

wait_for_pvc_gone() {
  local ns=$1 pvc=$2
  local attempt
  for attempt in 1 2 3; do
    if ! oc get pvc "$pvc" -n "$ns" &>/dev/null; then
      echo "    verified pvc/${pvc} removed from ${ns}"
      return 0
    fi
    if [[ attempt -eq 1 ]]; then
      echo "    waiting for pvc/${pvc} in ${ns} (timeout ${PVC_WAIT_TIMEOUT})..."
      oc wait --for=delete "pvc/${pvc}" -n "$ns" --timeout="$PVC_WAIT_TIMEOUT" 2>/dev/null && {
        echo "    verified pvc/${pvc} removed from ${ns}"
        return 0
      }
    fi
    prune_pods_for_pvc "$ns" "$pvc"
    sleep 3
  done
  if oc get pvc "$pvc" -n "$ns" &>/dev/null; then
    echo "    ERROR: pvc/${pvc} still present in ${ns}" >&2
    return 1
  fi
  echo "    verified pvc/${pvc} removed from ${ns}"
  return 0
}

namespaces_to_scan() {
  if is_true "$ALL_NAMESPACES"; then
    oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  else
    echo "$NAMESPACE"
  fi
}

list_namespace_pvcs() {
  local ns=$1
  oc get pvc -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

verify_pipelinerun_pvcs_gone() {
  local ns=$1 pr=$2 uid=${3:-}
  mapfile -t remaining < <(pipelinerun_pvcs "$ns" "$pr" "$uid")
  if [[ ${#remaining[@]} -gt 0 ]]; then
    die "PVC(s) still present for ${pr}: ${remaining[*]}"
  fi
  echo "  verified: all workspace PVCs removed for ${pr}"
}

verify_scope_clean() {
  local ns pvc remaining=0
  echo "=== Verifying no PVCs remain $(scope_message) ==="
  while IFS= read -r ns; do
    [[ -n "$ns" ]] || continue
    namespace_excluded "$ns" && continue
    mapfile -t pvcs < <(list_namespace_pvcs "$ns")
    mapfile -t pvcs < <(printf '%s\n' "${pvcs[@]:-}" | sed '/^$/d')
    for pvc in "${pvcs[@]}"; do
      echo "  REMAINING: ${ns}/${pvc}" >&2
      remaining=$((remaining + 1))
    done
  done < <(namespaces_to_scan)
  if [[ remaining -gt 0 ]]; then
    die "${remaining} PVC(s) still present after cleanup"
  fi
  echo "Verified: no PVCs remain in scope."
}

cleanup_pipelinerun() {
  local ns=$1 pr=$2 uid=${3:-}
  mapfile -t pvcs < <(pipelinerun_pvcs "$ns" "$pr" "$uid")
  if [[ ${#pvcs[@]} -eq 0 ]]; then
    echo "  ${pr}: no workspace PVCs found"
    return 0
  fi
  echo "  ${pr}: ${#pvcs[@]} PVC(s): ${pvcs[*]}"
  delete_pvcs "$ns" "${pvcs[@]}"
}

wait_pipelinerun_terminal() {
  local ns=$1 pr=$2 timeout=${3:-2h}
  echo "Waiting for PipelineRun ${pr} (timeout ${timeout})..."
  if oc wait "pipelinerun/${pr}" -n "$ns" --for=condition=Succeeded --timeout="$timeout" 2>/dev/null; then
    echo "PipelineRun ${pr}: Succeeded"
    return 0
  fi
  local status reason
  status=$(oc get "pipelinerun/${pr}" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)
  reason=$(oc get "pipelinerun/${pr}" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || true)
  if [[ -n "$status" && ( "$reason" == "Completed" || "$reason" == "Failed" || "$reason" == "Cancelled" ) ]]; then
    echo "PipelineRun ${pr}: finished (Succeeded=${status}, reason=${reason})"
    return 0
  fi
  if oc get "pipelinerun/${pr}" -n "$ns" -o jsonpath='{.status.completionTime}' 2>/dev/null | grep -q .; then
    echo "PipelineRun ${pr}: finished (completionTime set)"
    return 0
  fi
  die "PipelineRun ${pr} did not reach a terminal state (Succeeded status=${status:-unknown}, reason=${reason:-unknown})"
}

archive_pipelinerun() {
  local ns=$1 pr=$2
  local uid
  failed_pvcs=()

  if is_true "${ARCHIVE_WAIT:-true}"; then
    wait_pipelinerun_terminal "$ns" "$pr" "${PIPELINERUN_TIMEOUT:-2h}"
  fi

  uid=$(oc get pipelinerun "$pr" -n "$ns" -o jsonpath='{.metadata.uid}' 2>/dev/null) \
    || die "PipelineRun ${pr} not found in ${ns}"
  mapfile -t pvcs < <(pipelinerun_pvcs "$ns" "$pr" "$uid")

  echo "=== Archiving PipelineRun ${pr} in ${ns} ==="
  if [[ ${#pvcs[@]} -gt 0 ]]; then
    echo "  workspace PVC(s): ${pvcs[*]}"
  else
    echo "  no workspace PVCs found"
  fi

  if is_true "$DRY_RUN"; then
    echo "  [dry-run] would delete pipelinerun/${pr} -n ${ns}"
    delete_pvcs "$ns" "${pvcs[@]}"
    return 0
  fi

  echo "  deleting pipelinerun/${pr} -n ${ns}"
  oc delete pipelinerun "$pr" -n "$ns" --wait=false
  oc wait --for=delete "pipelinerun/${pr}" -n "$ns" --timeout=120s 2>/dev/null || true
  echo "  archived pipelinerun/${pr}"

  if [[ ${#pvcs[@]} -gt 0 ]]; then
    echo "=== Removing workspace PVCs for ${pr} ==="
    delete_pvcs "$ns" "${pvcs[@]}"
  fi

  if [[ ${#failed_pvcs[@]} -gt 0 ]]; then
    die "failed to remove PVCs: ${failed_pvcs[*]}"
  fi
  if is_true "$VERIFY"; then
    verify_pipelinerun_pvcs_gone "$ns" "$pr" "$uid"
  fi
}

prune_completed_pods() {
  local ns=$1
  mapfile -t pods < <(
    oc get pods -n "$ns" -o json 2>/dev/null | jq -r '
      .items[] | select(.status.phase == "Succeeded" or .status.phase == "Failed") | .metadata.name'
  )
  [[ ${#pods[@]} -eq 0 ]] && return 0
  echo "  pruning ${#pods[@]} completed pod(s) in ${ns}"
  if is_true "$DRY_RUN"; then
    echo "  [dry-run] would delete ${#pods[@]} completed pod(s) in ${ns}"
    return 0
  fi
  for pod in "${pods[@]}"; do
    oc delete pod "$pod" -n "$ns" --wait=false --ignore-not-found
  done
}

_run_main() {
  ARCHIVE_WAIT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pipelinerun) PIPELINERUN=$2; MODE="${MODE:-pipelinerun}"; shift 2 ;;
      --archive) MODE=archive; shift ;;
      --finished) MODE=finished; shift ;;
      --all) MODE=all; shift ;;
      --include-legacy) INCLUDE_LEGACY=true; shift ;;
      --legacy-only) MODE=legacy; shift ;;
      --prune-completed-pods) PRUNE_COMPLETED_PODS=true; shift ;;
      --include-platform-namespaces) INCLUDE_PLATFORM_NAMESPACES=true; shift ;;
      --no-wait) ARCHIVE_WAIT=false; shift ;;
      --no-verify) VERIFY=false; shift ;;
      --namespace) NAMESPACE=$2; shift 2 ;;
      --all-namespaces) ALL_NAMESPACES=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --force) FORCE=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown arg: $1 (try --help)" ;;
    esac
  done

  [[ -n "$MODE" ]] || die "specify --archive, --pipelinerun, --finished, --all, or --legacy-only"
  [[ "$MODE" != "archive" || -n "$PIPELINERUN" ]] || die "--archive requires --pipelinerun NAME"
  [[ "$MODE" != "pipelinerun" || -n "$PIPELINERUN" ]] || die "--pipelinerun NAME required"

  if [[ "$MODE" == "archive" && -z "$ARCHIVE_WAIT" ]]; then
    ARCHIVE_WAIT=true
  fi

  if is_true "$ALL_NAMESPACES" && [[ "$MODE" == "all" ]]; then
    PRUNE_COMPLETED_PODS=true
  fi

  command -v oc >/dev/null || die "oc CLI required"
  command -v jq >/dev/null || die "jq required"

  case "$MODE" in
    archive)
      archive_pipelinerun "$NAMESPACE" "$PIPELINERUN"
      ;;
    pipelinerun)
      failed_pvcs=()
      echo "=== PVC cleanup: ${PIPELINERUN} (${NAMESPACE}) ==="
      cleanup_pipelinerun "$NAMESPACE" "$PIPELINERUN"
      if ! is_true "$DRY_RUN" && is_true "$VERIFY"; then
        verify_pipelinerun_pvcs_gone "$NAMESPACE" "$PIPELINERUN"
        [[ ${#failed_pvcs[@]} -gt 0 ]] && die "failed to remove: ${failed_pvcs[*]}"
      fi
      ;;
    finished)
      echo "=== Archiving completed PipelineRuns in ${NAMESPACE} ==="
      mapfile -t prs < <(
        oc get pipelinerun -n "$NAMESPACE" -o json | jq -r '
          .items[] | select(.status.completionTime != null) | .metadata.name' | sort -u
      )
      if [[ ${#prs[@]} -eq 0 ]]; then
        echo "No completed PipelineRuns in ${NAMESPACE}"
      else
        for pr in "${prs[@]}"; do
          ARCHIVE_WAIT=false archive_pipelinerun "$NAMESPACE" "$pr"
        done
      fi
      ;;
    legacy)
      legacy="${TOOLCHAIN_CACHE_PVC:-release-tests-toolchain-cache}"
      failed_pvcs=()
      if oc get pvc "$legacy" -n "$NAMESPACE" &>/dev/null; then
        echo "=== Deleting legacy PVC ${legacy} in ${NAMESPACE} ==="
        delete_pvcs "$NAMESPACE" "$legacy"
        [[ ${#failed_pvcs[@]} -gt 0 ]] && die "failed to remove legacy PVC: ${failed_pvcs[*]}"
      else
        echo "No legacy PVC ${legacy} in ${NAMESPACE}"
      fi
      ;;
    all)
      is_true "$FORCE" || die "--all requires --force"
      failed_pvcs=()
      if is_true "$ALL_NAMESPACES" && ! is_true "$INCLUDE_PLATFORM_NAMESPACES"; then
        echo "Skipping platform namespaces (openshift-*, kube-*, default). Use --include-platform-namespaces to include them."
      fi
      echo "=== Deleting PVCs $(scope_message)$(is_true "$DRY_RUN" && echo ' [dry-run]' || true) ==="
      total=0
      while IFS= read -r ns; do
        [[ -n "$ns" ]] || continue
        namespace_excluded "$ns" && continue
        is_true "$PRUNE_COMPLETED_PODS" && prune_completed_pods "$ns"
        mapfile -t pvcs < <(list_namespace_pvcs "$ns")
        mapfile -t pvcs < <(printf '%s\n' "${pvcs[@]:-}" | sed '/^$/d')
        [[ ${#pvcs[@]} -eq 0 ]] && continue
        echo "Namespace ${ns}: ${#pvcs[@]} PVC(s)"
        total=$((total + ${#pvcs[@]}))
        delete_pvcs "$ns" "${pvcs[@]}"
      done < <(namespaces_to_scan)
      if [[ total -eq 0 ]]; then
        echo "No PVCs found $(scope_message)."
        is_true "$ALL_NAMESPACES" || echo "Tip: use --all-namespaces --all --force to scan every namespace."
        if ! is_true "$DRY_RUN" && is_true "$VERIFY"; then
          verify_scope_clean
        fi
      elif is_true "$DRY_RUN"; then
        echo "Total: ${total} PVC(s) would be deleted."
      else
        echo "Total: ${total} PVC(s) deleted."
        [[ ${#failed_pvcs[@]} -gt 0 ]] && die "failed to remove: ${failed_pvcs[*]}"
        is_true "$VERIFY" && verify_scope_clean
      fi
      ;;
  esac

  if is_true "$INCLUDE_LEGACY" && [[ "$MODE" != "all" ]]; then
    legacy="${TOOLCHAIN_CACHE_PVC:-release-tests-toolchain-cache}"
    if oc get pvc "$legacy" -n "$NAMESPACE" &>/dev/null; then
      echo "=== Deleting legacy PVC ${legacy} ==="
      failed_pvcs=()
      delete_pvcs "$NAMESPACE" "$legacy"
      [[ ${#failed_pvcs[@]} -gt 0 ]] && die "failed to remove legacy PVC: ${failed_pvcs[*]}"
    fi
  fi

  echo "Done."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _run_main "$@"
fi
