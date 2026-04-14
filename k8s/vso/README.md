# Vault Secrets Operator

This directory owns the Vault Secrets Operator installation lifecycle.

Layout:
- `helm/vault-secrets-operator/` installs the VSO controller and CRDs.

The custom resources consumed by VSO live in:
- `base/managing/vault-secrets-operator/`
- `overlays/<env>/managing/vault-secrets-operator/`

Reason:
- Helm installs the controller and CRDs.
- Kustomize applies `VaultConnection`, `VaultAuth`, and `VaultStaticSecret` after CRDs exist.
