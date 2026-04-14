#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K8S_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV="${1:-}"
if [[ -z "$ENV" ]] || [[ ! "$ENV" =~ ^(dev|staging|prod)$ ]]; then
  echo "사용법: $0 <dev|staging|prod>"
  exit 1
fi

OVERLAY_DIR="$K8S_ROOT/overlays/$ENV/managing"
NAMESPACE="mnt"

echo "============================================"
echo "  Project-Infra 전체 삭제 ($ENV 환경)"
echo "============================================"
echo ""
echo "삭제 대상: VSO 리소스, VSO Helm, 인프라 리소스, PVC, Namespace"
read -p "계속하시겠습니까? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "취소됨."
  exit 0
fi
echo ""

# -----------------------------------------------
# Phase 1: VSO 리소스 삭제
# -----------------------------------------------
echo "[1/5] VSO 리소스 삭제..."
kubectl delete -k "$OVERLAY_DIR/vault-secrets-operator/" --ignore-not-found 2>/dev/null || true
echo "  → VaultConnection, VaultAuth, VaultStaticSecret 삭제 완료"
echo ""

# -----------------------------------------------
# Phase 2: VSO Helm 삭제
# -----------------------------------------------
echo "[2/5] VSO Helm 삭제..."
if helm status vault-secrets-operator -n "$NAMESPACE" > /dev/null 2>&1; then
  helm uninstall vault-secrets-operator -n "$NAMESPACE"
  echo "  → VSO Helm 릴리즈 삭제 완료"
else
  echo "  → VSO Helm이 설치되어 있지 않음, 스킵"
fi
echo ""

# -----------------------------------------------
# Phase 3: 인프라 리소스 삭제
# -----------------------------------------------
echo "[3/5] 인프라 리소스 삭제..."
kubectl delete -k "$OVERLAY_DIR/" --ignore-not-found 2>/dev/null || true
echo "  → Vault, Docker Registry, ConfigMap, Service 삭제 완료"
echo ""

# -----------------------------------------------
# Phase 4: PVC 삭제
# -----------------------------------------------
echo "[4/5] PVC 삭제..."
kubectl delete pvc --all -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
echo "  → PVC 삭제 완료"
echo ""

# -----------------------------------------------
# Phase 5: ClusterRoleBinding 삭제
# -----------------------------------------------
echo "[5/5] ClusterRoleBinding 삭제..."
kubectl delete clusterrolebinding vault-tokenreview-binding --ignore-not-found 2>/dev/null || true
echo "  → ClusterRoleBinding 삭제 완료"
echo ""

# -----------------------------------------------
# 최종 확인
# -----------------------------------------------
echo "============================================"
echo "  삭제 완료 — 상태 확인"
echo "============================================"
echo ""

if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
  echo "--- 남은 리소스 ($NAMESPACE) ---"
  kubectl get all -n "$NAMESPACE" 2>/dev/null || true
else
  echo "Namespace '$NAMESPACE' 삭제됨."
fi
