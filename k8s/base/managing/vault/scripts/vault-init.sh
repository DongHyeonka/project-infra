#!/bin/bash
set -euo pipefail

VAULT_NAMESPACE="mnt"
VAULT_POD="vault-0"
KEY_SHARES=5
KEY_THRESHOLD=3

echo "=== Vault 초기화 스크립트 ==="

# 1. Vault 초기화
echo "[1/6] Vault 초기화..."
INIT_OUTPUT=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault operator init \
  -key-shares="$KEY_SHARES" \
  -key-threshold="$KEY_THRESHOLD" \
  -format=json)

echo "$INIT_OUTPUT" > vault-init-keys.json
echo "  → vault-init-keys.json 에 Unseal Key + Root Token 저장됨 (안전하게 보관할 것)"

# 2. Unseal
echo "[2/6] Vault Unseal..."
for i in $(seq 0 $(($KEY_THRESHOLD - 1))); do
  KEY=$(echo "$INIT_OUTPUT" | jq -r ".unseal_keys_b64[$i]")
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault operator unseal "$KEY"
done
echo "  → Unseal 완료"

# 3. Root Token으로 로그인
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r ".root_token")
VAULT_EXEC="kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --"

# 4. KV v2 시크릿 엔진 활성화
echo "[3/6] KV v2 시크릿 엔진 활성화..."
$VAULT_EXEC vault login "$ROOT_TOKEN"
$VAULT_EXEC vault secrets enable -path=secret kv-v2
echo "  → secret/ 경로에 KV v2 활성화됨"

# 5. Kubernetes Auth Method 설정
echo "[4/6] Kubernetes Auth Method 활성화..."
$VAULT_EXEC vault auth enable kubernetes
$VAULT_EXEC vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443"
echo "  → Kubernetes Auth 활성화됨"

# 6. VSO용 Policy 생성
echo "[5/6] VSO Policy 생성..."
$VAULT_EXEC sh -c 'vault policy write vault-secrets-operator - <<EOF
path "secret/data/docker-registry/*" {
  capabilities = ["read"]
}
EOF'
echo "  → vault-secrets-operator Policy 생성됨"

# 7. VSO용 Kubernetes Auth Role 생성
echo "[6/6] VSO Kubernetes Auth Role 생성..."
$VAULT_EXEC vault write auth/kubernetes/role/vault-secrets-operator \
  bound_service_account_names=vault-secrets-operator \
  bound_service_account_namespaces=mnt \
  policies=vault-secrets-operator \
  ttl=1h
echo "  → vault-secrets-operator Role 생성됨"

echo ""
echo "=== 초기화 완료 ==="
echo "Vault UI: http://<노드IP>:30820/ui"
echo "Root Token: $ROOT_TOKEN"
echo ""
echo "다음 단계:"
echo "  1. Vault UI 또는 CLI에서 Docker Registry 시크릿 저장"
echo "     vault kv put secret/docker-registry/auth htpasswd=\"\$(cat htpasswd)\""
echo "     vault kv put secret/docker-registry/pull-credentials username=pull-user password=PULL_PASSWORD"
echo "  2. VSO Helm 설치: k8s/helm/vault-secrets-operator/install.sh 실행"
