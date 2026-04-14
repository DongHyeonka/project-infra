# Application Shared Resources

Use this package for namespace-level shared resources in `app`.

Examples:
- shared `NetworkPolicy`
- shared `ResourceQuota`
- shared `LimitRange`
- shared service accounts used by many workloads

Rules:
- Do not place workload-specific resources here.
- Shared resources must be safe for every workload in the `app` namespace.
- If a resource is needed by only one domain, keep it in that domain instead.
