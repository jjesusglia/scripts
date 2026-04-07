#!/usr/bin/env bash
#
# restore.sh
# Restores Karpenter resources to a cluster from a backup snapshot.
#
# Usage:
#   ./restore.sh --backup-dir <dir>  [--context <kube-context>] [--dry-run]
#   ./restore.sh --backup-file <file.tar.gz> [--context <kube-context>] [--dry-run]
#
set -euo pipefail

# defaults
KUBE_CONTEXT=""
BACKUP_DIR=""
BACKUP_FILE=""
DRY_RUN=false
TEMP_DIR=""
ROLLOUT_TIMEOUT="5m"

# arg parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir)   BACKUP_DIR="$2";  shift 2 ;;
    --backup-file)  BACKUP_FILE="$2"; shift 2 ;;
    --context)      KUBE_CONTEXT="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --backup-dir  <dir>       Path to extracted backup directory"
      echo "  --backup-file <file>      Path to .tar.gz backup archive (auto-extracted)"
      echo "  --context     <context>   kubectl context to use"
      echo "  --dry-run                 Print apply commands without executing"
      echo "  -h|--help                 Show this help"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

KUBECTL="kubectl"
[[ -n "${KUBE_CONTEXT}" ]] && KUBECTL="kubectl --context ${KUBE_CONTEXT}"

# helpers
log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARNING: $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

apply_dir() {
  local subdir="$1" label="$2"
  local path="${BACKUP_DIR}/${subdir}"

  if [[ ! -d "${path}" ]]; then
    warn "${label}: directory '${path}' not found, skipping"
    return
  fi

  local count
  count=$(find "${path}" -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ')
  if [[ "${count}" -eq 0 ]]; then
    warn "${label}: no YAML files found in '${path}', skipping"
    return
  fi

  log "Applying ${label} (${count} files) from ${path}"
  if [[ "${DRY_RUN}" == true ]]; then
    echo "  [dry-run] ${KUBECTL} apply -f ${path}/"
  else
    ${KUBECTL} apply -f "${path}/"
  fi
}

apply_file() {
  local file="$1" label="$2"

  if [[ ! -f "${file}" ]]; then
    warn "${label}: file '${file}' not found, skipping"
    return
  fi

  log "Applying ${label} from ${file}"
  if [[ "${DRY_RUN}" == true ]]; then
    echo "  [dry-run] ${KUBECTL} apply -f ${file}"
  else
    ${KUBECTL} apply -f "${file}"
  fi
}

wait_rollout() {
  local kind="$1" name="$2" ns="$3"
  log "Waiting for ${kind}/${name} in ${ns} (timeout: ${ROLLOUT_TIMEOUT})..."
  if [[ "${DRY_RUN}" == true ]]; then
    echo "  [dry-run] ${KUBECTL} rollout status ${kind}/${name} -n ${ns} --timeout=${ROLLOUT_TIMEOUT}"
    return 0
  fi
  if ! ${KUBECTL} rollout status "${kind}/${name}" -n "${ns}" --timeout="${ROLLOUT_TIMEOUT}"; then
    warn "${kind}/${name} in ${ns} did not become ready within ${ROLLOUT_TIMEOUT}"
    return 1
  fi
}

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    log "Cleaning up temp dir: ${TEMP_DIR}"
    rm -rf "${TEMP_DIR}"
  fi
}
trap cleanup EXIT

# preflight
if ! command -v kubectl &>/dev/null; then
  die "kubectl not found in PATH"
fi

if [[ -z "${BACKUP_DIR}" && -z "${BACKUP_FILE}" ]]; then
  die "One of --backup-dir or --backup-file is required. Run with -h for usage."
fi

if [[ -n "${BACKUP_DIR}" && -n "${BACKUP_FILE}" ]]; then
  die "--backup-dir and --backup-file are mutually exclusive"
fi

# extract tarball if provided
if [[ -n "${BACKUP_FILE}" ]]; then
  [[ -f "${BACKUP_FILE}" ]] || die "Backup file not found: ${BACKUP_FILE}"
  TEMP_DIR=$(mktemp -d)
  log "Extracting ${BACKUP_FILE} to ${TEMP_DIR}..."
  tar -xzf "${BACKUP_FILE}" -C "${TEMP_DIR}"
  BACKUP_DIR=$(find "${TEMP_DIR}" -mindepth 1 -maxdepth 1 -type d | head -1)
  [[ -n "${BACKUP_DIR}" ]] || die "Could not find extracted directory inside archive"
  log "Using extracted backup: ${BACKUP_DIR}"
fi

# validate backup directory
[[ -d "${BACKUP_DIR}" ]] || die "Backup directory not found: ${BACKUP_DIR}"

MISSING=()
[[ -d "${BACKUP_DIR}/crds" ]]                                    || MISSING+=("crds/")
[[ -d "${BACKUP_DIR}/cluster-resources/nodepools" ]]             || MISSING+=("cluster-resources/nodepools/")
[[ -d "${BACKUP_DIR}/cluster-resources/ec2nodeclasses" ]]        || MISSING+=("cluster-resources/ec2nodeclasses/")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  die "Backup directory is missing required subdirectories: ${MISSING[*]}"
fi

echo ""
echo "============================================="
echo " Karpenter Restore"
echo " Backup    : ${BACKUP_DIR}"
[[ -n "${KUBE_CONTEXT}" ]] && echo " Context   : ${KUBE_CONTEXT}"
[[ "${DRY_RUN}" == true ]]  && echo " Mode      : DRY RUN"
echo "============================================="

# 1. CRDs — must come first
echo ""
log "Step 1/6: Restoring CRDs..."
apply_dir "crds" "Karpenter CRDs"

if [[ "${DRY_RUN}" == false ]]; then
  log "Waiting for CRDs to reach Established condition (timeout: 120s)..."
  ${KUBECTL} wait crd \
    nodepools.karpenter.sh \
    nodeclaims.karpenter.sh \
    ec2nodeclasses.karpenter.k8s.aws \
    --for=condition=Established --timeout=120s
  log "All Karpenter CRDs established."
else
  echo "  [dry-run] ${KUBECTL} wait crd nodepools.karpenter.sh nodeclaims.karpenter.sh ec2nodeclasses.karpenter.k8s.aws --for=condition=Established --timeout=120s"
fi

# 2. RBAC
echo ""
log "Step 2/6: Restoring RBAC..."
apply_dir "rbac" "RBAC"

# 3. Namespace + namespaced resources
echo ""
log "Step 3/6: Restoring karpenter namespace and workloads..."
apply_file "${BACKUP_DIR}/namespaces/karpenter.yaml" "namespace/karpenter"
apply_dir "namespaced/serviceaccounts" "ServiceAccounts"
apply_dir "namespaced/configmaps"      "ConfigMaps"
apply_dir "namespaced/secrets"         "Secrets"
apply_dir "namespaced/deployments"     "Deployments"

# 4. NodePools + EC2NodeClasses
echo ""
log "Step 4/6: Restoring EC2NodeClasses..."
apply_dir "cluster-resources/ec2nodeclasses" "EC2NodeClasses"

echo ""
log "Step 5/6: Restoring NodePools..."
apply_dir "cluster-resources/nodepools" "NodePools"

# 5. NodeClaims (last — depend on NodePools + EC2NodeClasses)
echo ""
log "Step 6/6: Restoring NodeClaims..."
apply_dir "cluster-resources/nodeclaims" "NodeClaims"

# wait for karpenter controller
ROLLOUT_FAILURES=0
echo ""
log "Waiting for Karpenter controller to become ready..."
wait_rollout "deployment" "karpenter" "karpenter" || ROLLOUT_FAILURES=$((ROLLOUT_FAILURES + 1))

# summary
echo ""
echo "============================================="
if [[ "${DRY_RUN}" == true ]]; then
  echo " Restore dry run complete — no changes made"
elif [[ "${ROLLOUT_FAILURES}" -gt 0 ]]; then
  echo " Restore complete with ${ROLLOUT_FAILURES} rollout timeout(s)"
  echo " Check pod status: kubectl get pods -n karpenter"
else
  echo " Restore complete — Karpenter controller ready"
fi
echo "============================================="

[[ "${ROLLOUT_FAILURES}" -gt 0 ]] && exit 1 || exit 0
