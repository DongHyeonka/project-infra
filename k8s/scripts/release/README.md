# Release Operations

Release scripts orchestrate many Kustomize package entry points.

Examples:
- apply every workload package in one unit
- diff a unit before release
- roll back a failed environment release

Do not add one release script per workload. Prefer generated package lists or GitOps controllers.
