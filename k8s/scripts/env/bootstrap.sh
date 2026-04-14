#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K8S_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$K8S_ROOT/.." && pwd)"

ENV="${1:-}"
if [[ -z "$ENV" ]] || [[ ! "$ENV" =~ ^(dev|staging|prod)$ ]]; then
  echo "사용법: $0 <dev|staging|prod>"
  exit 1
fi

OVERLAY_DIR="$K8S_ROOT/overlays/$ENV/managing"
VAULT_SCRIPTS="$SCRIPT_DIR/../vault"
VSO_HELM_DIR="$K8S_ROOT/vso/helm/vault-secrets-operator"
NAMESPACE="mnt"

echo "============================================"
echo "  Project-Infra 셋업 ($ENV 환경)"
echo "============================================"
echo ""

# -----------------------------------------------
# Phase 1: 인프라 리소스 배포
# -----------------------------------------------
echo "[1/6] 인프라 리소스 배포..."
kubectl apply -k "$OVERLAY_DIR/"
echo "  → Namespace, Vault, Docker Registry 배포 완료"
echo ""

# -----------------------------------------------
# Phase 2: Vault Pod 대기
# -----------------------------------------------
echo "[2/6] Vault Pod Ready 대기..."
kubectl wait --for=condition=Ready pod/vault-0 -n "$NAMESPACE" --timeout=120s
echo "  → Vault Pod Running"
echo ""

# -----------------------------------------------
# Phase 3: Vault 초기화
# -----------------------------------------------
echo "[3/6] Vault 초기화..."

# 이미 초기화된 경우 스킵
VAULT_STATUS=$(kubectl exec -n "$NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null || true)
if echo "$VAULT_STATUS" | jq -e '.initialized == true' > /dev/null 2>&1; then
  echo "  → Vault가 이미 초기화됨, 스킵"

  # Sealed 상태면 unseal
  if echo "$VAULT_STATUS" | jq -e '.sealed == true' > /dev/null 2>&1; then
    echo "  → Vault가 Sealed 상태, Unseal 진행..."
    if [ -f "$PROJECT_ROOT/vault-init-keys.json" ]; then
      KEY_THRESHOLD=$(jq -r '.unseal_threshold' "$PROJECT_ROOT/vault-init-keys.json")
      for i in $(seq 0 $(($KEY_THRESHOLD - 1))); do
        KEY=$(jq -r ".unseal_keys_b64[$i]" "$PROJECT_ROOT/vault-init-keys.json")
        kubectl exec -n "$NAMESPACE" vault-0 -- vault operator unseal "$KEY" > /dev/null
      done
      echo "  → Unseal 완료"
    else
      echo "  ERROR: vault-init-keys.json이 없습니다. 수동으로 unseal 하세요."
      exit 1
    fi
  fi
else
  cd "$PROJECT_ROOT"
  bash "$VAULT_SCRIPTS/init.sh"
fi
echo ""

# -----------------------------------------------
# Phase 4: Docker Registry 시크릿 저장
# -----------------------------------------------
echo "[4/6] Docker Registry 시크릿 저장..."

# Vault에 시크릿이 이미 있으면 스킵
ROOT_TOKEN=$(jq -r ".root_token" "$PROJECT_ROOT/vault-init-keys.json")
SECRET_EXISTS=$(kubectl exec -n "$NAMESPACE" vault-0 -- sh -c "vault login -no-print $ROOT_TOKEN && vault kv get -format=json secret/docker-registry/auth 2>/dev/null" || true)
if echo "$SECRET_EXISTS" | jq -e '.data' > /dev/null 2>&1; then
  echo "  → Docker Registry 시크릿이 이미 존재함, 스킵"
else
  cd "$PROJECT_ROOT"
  bash "$VAULT_SCRIPTS/seed-registry.sh"
fi
echo ""

# -----------------------------------------------
# Phase 5: VSO Helm 설치
# -----------------------------------------------
echo "[5/6] VSO Helm 설치..."

# 이미 설치된 경우 스킵
if helm status vault-secrets-operator -n "$NAMESPACE" > /dev/null 2>&1; then
  echo "  → VSO가 이미 설치됨, 스킵"
else
  bash "$VSO_HELM_DIR/install.sh"
fi

echo "  → VSO Pod Ready 대기..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault-secrets-operator -n "$NAMESPACE" --timeout=120s
echo "  → VSO Pod Running"
echo ""

# -----------------------------------------------
# Phase 6: VSO 리소스 배포
# -----------------------------------------------
echo "[6/6] VSO 리소스 배포..."
kubectl apply -k "$OVERLAY_DIR/vault-secrets-operator/"
echo "  → VaultConnection, VaultAuth, VaultStaticSecret 적용 완료"
echo ""

# -----------------------------------------------
# 최종 확인
# -----------------------------------------------
echo "============================================"
echo "  셋업 완료 — 상태 확인"
echo "============================================"
echo ""

echo "--- Secrets ---"
kubectl get secrets -n "$NAMESPACE" --no-headers | grep -E 'docker-registry-htpasswd|registry-pull-credential' || echo "  (Secret 생성 대기 중...)"
echo ""

# Secret 생성 대기 (최대 30초)
echo "Secret 동기화 대기..."
for i in $(seq 1 6); do
  if kubectl get secret docker-registry-htpasswd -n "$NAMESPACE" > /dev/null 2>&1 && \
     kubectl get secret registry-pull-credential -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "  → Secret 동기화 완료"
    break
  fi
  if [ "$i" -eq 6 ]; then
    echo "  → Secret이 아직 생성되지 않음. 'kubectl describe vaultstaticsecret -n $NAMESPACE' 로 확인하세요."
  fi
  sleep 5
done
echo ""

echo "--- Pods ---"
kubectl get pods -n "$NAMESPACE"
echo ""

echo "============================================"
echo "  $ENV 환경 인프라 셋업 완료"
echo "============================================"
echo ""
echo "Vault UI: http://<노드IP>:30820/ui"
echo "Root Token: $(jq -r '.root_token' "$PROJECT_ROOT/vault-init-keys.json" 2>/dev/null || echo '(vault-init-keys.json 확인)')"
