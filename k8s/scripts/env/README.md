# Environment Operations

Environment scripts orchestrate multiple package entry points.

Scripts:
- `bootstrap.sh <dev|staging|prod>` applies managing infrastructure, initializes Vault, installs VSO, and applies VSO custom resources.
- `teardown.sh <dev|staging|prod>` removes managing infrastructure for an environment.

Rules:
- Keep environment-wide phase ordering here.
- Keep package-specific operations in their own script area, such as `../vault`.
- Do not add one script per service or workload.
