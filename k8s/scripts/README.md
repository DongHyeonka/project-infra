# Kubernetes Scripts

Scripts are for imperative bootstrap or break-glass operations.

Entry points:
- `env/bootstrap.sh <dev|staging|prod>` bootstraps the managing infrastructure.
- `env/teardown.sh <dev|staging|prod>` tears down the managing infrastructure.
- `vault/init.sh` initializes Vault.
- `vault/seed-registry.sh` seeds Docker Registry credentials into Vault.

Ops areas:
- `env/` is for environment-level bootstrap and teardown orchestration.
- `cluster/` is for cluster-level checks and lifecycle helpers.
- `platform/` is for platform add-ons that are not individual app workloads.
- `security/` is for security and secret operations.
- `release/` is for release orchestration across many workload packages.
- `data/` is for data-plane operational tasks.
- `vault/` is for Vault-specific operations.

Rules:
- Do not add one script per service.
- Service, job, scheduler, and database rollout should be handled by Kustomize packages.
- Scripts must orchestrate phases; they must not become the source of Kubernetes resource specs.
- Package-specific scripts belong under a clearly named subdirectory with a README.
