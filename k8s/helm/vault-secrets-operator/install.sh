#!/bin/bash
set -euo pipefail

NAMESPACE="mnt"
RELEASE_NAME="vault-secrets-operator"
CHART_VERSION="0.9.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Vault Secrets Operator Helm 설치 ==="

helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install "$RELEASE_NAME" hashicorp/vault-secrets-operator \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  --values "$SCRIPT_DIR/values.yaml"

echo "  → $RELEASE_NAME 설치 완료 (NS: $NAMESPACE)"
echo ""
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault-secrets-operator
