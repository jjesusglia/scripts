#!/usr/bin/env bash
# Karpenter health check script
# Usage: ./check-health.sh [kubectl-context]

set -euo pipefail

CONTEXT="${1:-dev}"
KUBE="kubectl --context ${CONTEXT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

pass() { echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

FAILURES=0

# ── Controller ────────────────────────────────────────────────────────────────
header "Controller"

READY=$($KUBE get deployment karpenter -n karpenter \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED=$($KUBE get deployment karpenter -n karpenter \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")

if [[ "$READY" == "$DESIRED" && "$READY" != "0" ]]; then
  pass "Deployment ready: ${READY}/${DESIRED} replicas"
else
  fail "Deployment not ready: ${READY}/${DESIRED} replicas"
fi

IMAGE=$($KUBE get deployment karpenter -n karpenter \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
echo "    image: ${IMAGE}"

ERRORS=$($KUBE logs -n karpenter -l app.kubernetes.io/name=karpenter \
  --tail=200 --since=5m 2>/dev/null | grep -ciE "error|panic|fatal" || true)
if [[ "$ERRORS" -eq 0 ]]; then
  pass "No errors in last 5m of logs"
else
  warn "${ERRORS} error/panic/fatal lines in last 5m of logs"
  $KUBE logs -n karpenter -l app.kubernetes.io/name=karpenter \
    --tail=200 --since=5m 2>/dev/null | grep -iE "error|panic|fatal" | tail -5 | sed 's/^/    /'
fi

# ── CRDs ──────────────────────────────────────────────────────────────────────
header "CRDs"

for crd in nodepools.karpenter.sh nodeclaims.karpenter.sh ec2nodeclasses.karpenter.k8s.aws; do
  if $KUBE get crd "$crd" &>/dev/null; then
    pass "$crd"
  else
    fail "$crd not found"
  fi
done

# ── NodePools ─────────────────────────────────────────────────────────────────
header "NodePools"

while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  ready=$(echo "$line" | awk '{print $2}')
  if [[ "$ready" == "True" ]]; then
    pass "${name} (Ready)"
  else
    fail "${name} (not Ready — status: ${ready})"
  fi
done < <($KUBE get nodepools \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)

# ── EC2NodeClasses ─────────────────────────────────────────────────────────────
header "EC2NodeClasses"

while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  ready=$(echo "$line" | awk '{print $2}')
  if [[ "$ready" == "True" ]]; then
    pass "${name} (Ready)"
  else
    fail "${name} (not Ready — status: ${ready})"
  fi
done < <($KUBE get ec2nodeclasses \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)

# ── NodeClaims ────────────────────────────────────────────────────────────────
header "NodeClaims"

TOTAL=$($KUBE get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' ')
NOT_READY=$($KUBE get nodeclaims --no-headers 2>/dev/null \
  | awk '$6 != "True"' | wc -l | tr -d ' ' || true)

pass "Total NodeClaims: ${TOTAL}"

if [[ "$NOT_READY" -eq 0 ]]; then
  pass "All NodeClaims Ready"
else
  warn "${NOT_READY} NodeClaims not Ready"
  $KUBE get nodeclaims --no-headers 2>/dev/null \
    | awk '$6 != "True" {print "    "$1, $2, $6}' || true
fi

# ── Nodes ─────────────────────────────────────────────────────────────────────
header "Nodes"

TOTAL_NODES=$($KUBE get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
NOT_READY_NODES=$($KUBE get nodes --no-headers 2>/dev/null \
  | grep -v " Ready" | wc -l | tr -d ' ' || true)

pass "Total nodes: ${TOTAL_NODES}"

if [[ "$NOT_READY_NODES" -eq 0 ]]; then
  pass "All nodes Ready"
else
  fail "${NOT_READY_NODES} node(s) not Ready"
  $KUBE get nodes --no-headers 2>/dev/null | grep -v " Ready" | awk '{print "    "$1, $2}' || true
fi

PENDING_PODS=$($KUBE get pods -A --field-selector=status.phase=Pending \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$PENDING_PODS" -eq 0 ]]; then
  pass "No Pending pods"
else
  warn "${PENDING_PODS} Pending pod(s) — may be normal during scale-up"
  $KUBE get pods -A --field-selector=status.phase=Pending \
    --no-headers 2>/dev/null | awk '{print "    "$1"/"$2}' | head -10 || true
fi

# ── Recent Events ─────────────────────────────────────────────────────────────
header "Recent Karpenter Events (last 10)"

$KUBE get events -n karpenter --sort-by='.lastTimestamp' \
  --no-headers 2>/dev/null | tail -10 | awk '{print "  "$0}' || true

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All checks passed.${RESET}"
else
  echo -e "${RED}${BOLD}${FAILURES} check(s) failed.${RESET}"
  exit 1
fi
