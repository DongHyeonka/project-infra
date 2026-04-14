# Platform Operations

Platform scripts are for shared platform add-ons and control-plane adjuncts.

Examples:
- install or verify shared controllers
- check registry reachability
- check operator readiness

Application workload rollout belongs in Kustomize packages, not platform scripts.
