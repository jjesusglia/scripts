#!/usr/bin/env bash
#
# backup-calico-eks.sh
# Backs up Calico / Tigera resources from an EKS cluster.
#
# Namespaces:  calico-apiserver, tigera-operator, calico-system
# Resources:   Deployments, DaemonSets, CRDs, Installation CR,
#              GlobalNetworkSets, Calico NetworkPolicies,
#              GlobalNetworkPolicies, IPPools, BGP configs,
#              FelixConfigurations, HostEndpoints, NetworkSets,
#              and all remaining Calico/Tigera CRD instances.
#
# Usage:
#   ./backup-calico-eks.sh [--context <kube-context>] [--output-dir <dir>]
#
set -euo pipefail

#  defaults 
KUBE_CONTEXT=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="./calico-backup-${TIMESTAMP}"

#  arg parsing 
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)  KUBE_CONTEXT="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--context <kube-context>] [--output-dir <dir>]"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

KUBECTL="kubectl"
[[ -n "${KUBE_CONTEXT}" ]] && KUBECTL="kubectl --context ${KUBE_CONTEXT}"

#  preflight 
if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

echo "============================================="
echo " Calico / Tigera EKS Backup"
echo " Timestamp : ${TIMESTAMP}"
echo " Output    : ${OUTPUT_DIR}"
[[ -n "${KUBE_CONTEXT}" ]] && echo " Context   : ${KUBE_CONTEXT}"
echo "============================================="

mkdir -p "${OUTPUT_DIR}"

#  helper: export a namespaced resource 
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

#  helper: export a cluster-scoped resource 
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

#  1. Namespace manifests 
NAMESPACES=("calico-apiserver" "tigera-operator" "calico-system")

echo ""
echo ">>> Backing up namespace manifests..."
mkdir -p "${OUTPUT_DIR}/namespaces"
for ns in "${NAMESPACES[@]}"; do
  if ${KUBECTL} get ns "${ns}" &>/dev/null; then
    echo "  namespace/${ns}"
    ${KUBECTL} get ns "${ns}" -o yaml > "${OUTPUT_DIR}/namespaces/${ns}.yaml"
  else
    echo "  namespace/${ns}  not found, skipping"
  fi
done

#  2. Namespaced workloads (Deployments, DaemonSets, Services, etc.)
WORKLOAD_RESOURCES=("deployments" "daemonsets" "statefulsets" "services" "configmaps" "secrets" "serviceaccounts")

for ns in "${NAMESPACES[@]}"; do
  if ! ${KUBECTL} get ns "${ns}" &>/dev/null; then
    continue
  fi
  for res in "${WORKLOAD_RESOURCES[@]}"; do
    echo ""
    echo ">>> ${ns} / ${res}"
    backup_namespaced "${ns}" "${res}" "namespaced/${res}"
  done
done

#  3. Calico / Tigera CRDs 
echo ""
echo ">>> Backing up Calico/Tigera CRDs..."
mkdir -p "${OUTPUT_DIR}/crds"
CALICO_CRDS=$(${KUBECTL} get crds -o name | grep -E '(projectcalico|tigera|adminnetworkpolicies\.policy\.networking\.k8s\.io)' || true)
if [[ -n "${CALICO_CRDS}" ]]; then
  for crd in ${CALICO_CRDS}; do
    name=$(basename "${crd}")
    echo "  ${name}"
    ${KUBECTL} get "${crd}" -o yaml > "${OUTPUT_DIR}/crds/${name}.yaml"
  done
else
  echo "  (no Calico/Tigera CRDs found)"
fi

#  4. Cluster-scoped Calico custom resources 
CLUSTER_SCOPED_CRS=(
  "installations.operator.tigera.io"
  "tigerastatuses.operator.tigera.io"
  "apiservers.operator.tigera.io"
  "imagesets.operator.tigera.io"
  "globalnetworksets.crd.projectcalico.org"
  "globalnetworkpolicies.crd.projectcalico.org"
  "ippools.crd.projectcalico.org"
  "ipamblocks.crd.projectcalico.org"
  "blockaffinities.crd.projectcalico.org"
  "clusterinformations.crd.projectcalico.org"
  "felixconfigurations.crd.projectcalico.org"
  "bgpconfigurations.crd.projectcalico.org"
  "bgppeers.crd.projectcalico.org"
  "bgpfilters.crd.projectcalico.org"
  "hostendpoints.crd.projectcalico.org"
  "kubecontrollersconfigurations.crd.projectcalico.org"
  "caliconodestatuses.crd.projectcalico.org"
  "ipamconfigs.crd.projectcalico.org"
  "ipamhandles.crd.projectcalico.org"
  "ipreservations.crd.projectcalico.org"
  "tiers.crd.projectcalico.org"
)

echo ""
echo ">>> Backing up cluster-scoped Calico/Tigera CRs..."
for cr in "${CLUSTER_SCOPED_CRS[@]}"; do
  # Only attempt if the CRD actually exists
  if ${KUBECTL} api-resources --api-group="$(echo "${cr}" | cut -d. -f2-)" &>/dev/null 2>&1; then
    short=$(echo "${cr}" | cut -d. -f1)
    echo ""
    echo ">>> ${short}"
    backup_cluster "${cr}" "cluster-resources/${short}"
  fi
done

#  5. Namespaced Calico NetworkPolicies & NetworkSets 
NAMESPACED_CALICO_CRS=(
  "networkpolicies.crd.projectcalico.org"
  "networksets.crd.projectcalico.org"
  "adminnetworkpolicies.policy.networking.k8s.io"
)

echo ""
echo ">>> Backing up namespaced Calico CRs (all namespaces)..."
for cr in "${NAMESPACED_CALICO_CRS[@]}"; do
  short=$(echo "${cr}" | cut -d. -f1)
  echo ""
  echo ">>> ${short} (all namespaces)"
  dest="${OUTPUT_DIR}/namespaced-calico-crs/${short}"
  mkdir -p "${dest}"

  items=$(${KUBECTL} get "${cr}" --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if [[ -z "${items}" ]]; then
    echo "  (none found)"
    continue
  fi

  while IFS='/' read -r ns name; do
    [[ -z "${ns}" || -z "${name}" ]] && continue
    echo "  ${ns}/${name}"
    ${KUBECTL} get "${cr}" "${name}" -n "${ns}" -o yaml > "${dest}/${ns}_${name}.yaml"
  done <<< "${items}"
done

#  6. Kubernetes NetworkPolicies in Calico namespaces 
echo ""
echo ">>> Backing up k8s NetworkPolicies in Calico namespaces..."
for ns in "${NAMESPACES[@]}"; do
  if ${KUBECTL} get ns "${ns}" &>/dev/null; then
    backup_namespaced "${ns}" "networkpolicies" "namespaced/networkpolicies"
  fi
done

#  7. RBAC (ClusterRoles / ClusterRoleBindings) 
echo ""
echo ">>> Backing up Calico/Tigera RBAC..."
mkdir -p "${OUTPUT_DIR}/rbac"
for rbac_type in clusterroles clusterrolebindings; do
  items=$(${KUBECTL} get "${rbac_type}" -o name | grep -iE '(calico|tigera)' || true)
  if [[ -n "${items}" ]]; then
    for item in ${items}; do
      name=$(basename "${item}")
      echo "  ${rbac_type}/${name}"
      ${KUBECTL} get "${item}" -o yaml > "${OUTPUT_DIR}/rbac/${rbac_type}_${name}.yaml"
    done
  fi
done

#  8. Create tarball 
TARBALL="${OUTPUT_DIR}.tar.gz"
echo ""
echo ">>> Compressing backup  ${TARBALL}"
tar -czf "${TARBALL}" -C "$(dirname "${OUTPUT_DIR}")" "$(basename "${OUTPUT_DIR}")"

#  summary 
FILE_COUNT=$(find "${OUTPUT_DIR}" -name '*.yaml' | wc -l)
echo ""
echo "============================================="
echo " Backup complete"
echo " Files   : ${FILE_COUNT} YAML manifests"
echo " Dir     : ${OUTPUT_DIR}/"
echo " Archive : ${TARBALL}"
echo "============================================="
