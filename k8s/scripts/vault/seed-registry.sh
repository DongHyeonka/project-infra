#!/bin/bash
set -euo pipefail

VAULT_NAMESPACE="mnt"
VAULT_POD="vault-0"
VAULT_EXEC="kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --"

# init.sh에서 생성된 키 파일 확인
if [ ! -f vault-init-keys.json ]; then
  echo "ERROR: vault-init-keys.json 파일이 없습니다. k8s/scripts/vault/init.sh를 먼저 실행하세요."
  exit 1
fi

ROOT_TOKEN=$(jq -r ".root_token" vault-init-keys.json)
$VAULT_EXEC vault login "$ROOT_TOKEN" > /dev/null

echo "=== Docker Registry 시크릿 생성 ==="

# 1. push/pull 계정 비밀번호 입력받기
read -p "push-user 비밀번호: " -s PUSH_PASSWORD
echo
read -p "pull-user 비밀번호: " -s PULL_PASSWORD
echo

# 2. htpasswd 생성 (Pod 안에서 직접 생성)
echo "[1/3] htpasswd 생성..."
HTPASSWD_CONTENT=$(docker run --rm httpd:2 htpasswd -Bbn push-user "$PUSH_PASSWORD" && \
                   docker run --rm httpd:2 htpasswd -Bbn pull-user "$PULL_PASSWORD")

# docker가 없으면 로컬 htpasswd로 fallback
if [ -z "$HTPASSWD_CONTENT" ]; then
  echo "  → docker 없음, 로컬 htpasswd 사용"
  HTPASSWD_CONTENT=$(htpasswd -Bbn push-user "$PUSH_PASSWORD" && \
                     htpasswd -Bbn pull-user "$PULL_PASSWORD")
fi

# 3. Vault에 htpasswd 저장
echo "[2/3] Vault에 htpasswd 저장..."
$VAULT_EXEC vault kv put secret/docker-registry/auth \
  htpasswd="$HTPASSWD_CONTENT"
echo "  → secret/docker-registry/auth 저장 완료"

# 4. Vault에 pull 자격증명 저장
echo "[3/3] Vault에 pull 자격증명 저장..."
$VAULT_EXEC vault kv put secret/docker-registry/pull-credentials \
  username="pull-user" \
  password="$PULL_PASSWORD"
echo "  → secret/docker-registry/pull-credentials 저장 완료"

echo ""
echo "=== 시크릿 저장 완료 ==="
echo "VSO가 refreshAfter(1h) 내에 K8s Secret으로 동기화합니다."
echo "즉시 동기화하려면: kubectl apply -k k8s/overlays/<env>/managing/vault-secrets-operator/"
