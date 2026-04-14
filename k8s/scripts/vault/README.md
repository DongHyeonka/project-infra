# Vault Operations

Vault scripts are imperative operations for the `managing/vault` package.

Scripts:
- `init.sh` initializes and unseals Vault, then configures Kubernetes auth for VSO.
- `seed-registry.sh` writes Docker Registry credentials into Vault.

Rules:
- Keep Vault runtime manifests in `base/managing/vault`.
- Keep VSO custom resources in `base/managing/vault-secrets-operator`.
- Keep operator installation under `vso/helm/vault-secrets-operator`.
