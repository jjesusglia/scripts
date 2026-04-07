#!/usr/bin/env bash
#
# backup.sh
# Backs up Karpenter resources from an EKS cluster.
#
# Resources: CRDs, NodePools, NodeClaims, EC2NodeClasses,
#            karpenter namespace workloads, RBAC
#
# Usage:
#   ./backup.sh [--context <kube-context>] [--output-dir <dir>]
#
set -euo pipefail

# defaults
KUBE_CONTEXT=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="./karpenter-backup-${TIMESTAMP}"

# arg parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)    KUBE_CONTEXT="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2";   shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--context <kube-context>] [--output-dir <dir>]"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

KUBECTL="kubectl"
[[ -n "${KUBE_CONTEXT}" ]] && KUBECTL="kubectl --context ${KUBE_CONTEXT}"

# preflight
if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

echo "============================================="
echo " Karpenter EKS Backup"
echo " Timestamp : ${TIMESTAMP}"
echo " Output    : ${OUTPUT_DIR}"
[[ -n "${KUBE_CONTEXT}" ]] && echo " Context   : ${KUBE_CONTEXT}"
echo "============================================="

mkdir -p "${OUTPUT_DIR}"

# helper: export a namespaced resource
backup_namespaced() {
  local ns="$1" resource="$2" subdir="$3"
  local dest="${OUTPUT_DIR}/${subdir}"
  mkdir -p "${dest}"

  local items
  items=$(${KUBECTL} get "${resource}" -n "${ns}" -o name 2>/dev/null || true)
  if [[ -z "${items}" ]]; then
    echo "  (none found)"
    return
  fi

  for item in ${items}; do
    local name
    name=$(basename "${item}")
    echo "  ${ns}/${resource}/${name}"
    ${KUBECTL} get "${item}" -n "${ns}" -o yaml > "${dest}/${ns}_${name}.yaml"
  done
}

# helper: export a cluster-scoped resource
backup_cluster() {
  local resource="$1" subdir="$2"
  local dest="${OUTPUT_DIR}/${subdir}"
  mkdir -p "${dest}"

  local items
  items=$(${KUBECTL} get "${resource}" -o name 2>/dev/null || true)
  if [[ -z "${items}" ]]; then
    echo "  (none found)"
    return
  fi

  for item in ${items}; do
    local name
    name=$(basename "${item}")
    echo "  ${resource}/${name}"
    ${KUBECTL} get "${item}" -o yaml > "${dest}/${name}.yaml"
  done
}

# 1. CRDs
echo ""
echo ">>> Backing up Karpenter CRDs..."
mkdir -p "${OUTPUT_DIR}/crds"
KARPENTER_CRDS=$(${KUBECTL} get crds -o name | grep -E '(karpenter\.sh|karpenter\.k8s\.aws)' || true)
if [[ -n "${KARPENTER_CRDS}" ]]; then
  for crd in ${KARPENTER_CRDS}; do
    name=$(basename "${crd}")
    echo "  ${name}"
    ${KUBECTL} get "${crd}" -o yaml > "${OUTPUT_DIR}/crds/${name}.yaml"
  done
else
  echo "  (no Karpenter CRDs found)"
fi

# 2. Cluster-scoped CRs
echo ""
echo ">>> Backing up NodePools..."
backup_cluster "nodepools.karpenter.sh" "cluster-resources/nodepools"

echo ""
echo ">>> Backing up NodeClaims..."
backup_cluster "nodeclaims.karpenter.sh" "cluster-resources/nodeclaims"

echo ""
echo ">>> Backing up EC2NodeClasses..."
backup_cluster "ec2nodeclasses.karpenter.k8s.aws" "cluster-resources/ec2nodeclasses"

# 3. Namespaced resources (karpenter namespace)
KARPENTER_NS="karpenter"
WORKLOAD_RESOURCES=("deployments" "configmaps" "secrets" "serviceaccounts")

if ${KUBECTL} get ns "${KARPENTER_NS}" &>/dev/null; then
  echo ""
  echo ">>> Backing up namespace/${KARPENTER_NS}..."
  mkdir -p "${OUTPUT_DIR}/namespaces"
  ${KUBECTL} get ns "${KARPENTER_NS}" -o yaml > "${OUTPUT_DIR}/namespaces/${KARPENTER_NS}.yaml"

  for res in "${WORKLOAD_RESOURCES[@]}"; do
    echo ""
    echo ">>> ${KARPENTER_NS} / ${res}"
    backup_namespaced "${KARPENTER_NS}" "${res}" "namespaced/${res}"
  done
else
  echo "  WARNING: namespace '${KARPENTER_NS}' not found, skipping namespaced resources"
fi

# 4. RBAC
echo ""
echo ">>> Backing up Karpenter RBAC..."
mkdir -p "${OUTPUT_DIR}/rbac"
for rbac_type in clusterroles clusterrolebindings; do
  items=$(${KUBECTL} get "${rbac_type}" -o name | grep -i "karpenter" || true)
  if [[ -n "${items}" ]]; then
    for item in ${items}; do
      name=$(basename "${item}")
      echo "  ${rbac_type}/${name}"
      ${KUBECTL} get "${item}" -o yaml > "${OUTPUT_DIR}/rbac/${rbac_type}_${name}.yaml"
    done
  else
    echo "  (no karpenter ${rbac_type} found)"
  fi
done

# 5. Compress
TARBALL="${OUTPUT_DIR}.tar.gz"
echo ""
echo ">>> Compressing backup → ${TARBALL}"
tar -czf "${TARBALL}" -C "$(dirname "${OUTPUT_DIR}")" "$(basename "${OUTPUT_DIR}")"

# summary
FILE_COUNT=$(find "${OUTPUT_DIR}" -name '*.yaml' | wc -l | tr -d ' ')
echo ""
echo "============================================="
echo " Backup complete"
echo " Files   : ${FILE_COUNT} YAML manifests"
echo " Dir     : ${OUTPUT_DIR}/"
echo " Archive : ${TARBALL}"
echo "============================================="
