# Application Units

Add application workloads under unit, domain, workload-kind, and workload folders.

Required shape:

```text
units/<unit>/
├── kustomization.yaml
└── <domain>/
    ├── kustomization.yaml
    └── <workload-kind>/
        ├── kustomization.yaml
        └── <workload>/
            ├── kustomization.yaml
            ├── deployment.yaml | statefulset.yaml | job.yaml | cronjob.yaml
            ├── service.yaml
            ├── configmap.yaml
            └── ...
```

Rules:
- Do not put 1000 workloads directly under `base/app/`.
- Do not group by Kubernetes kind.
- `unit` is the first scale boundary, usually a business unit, product area, or owning organization.
- `domain` is the bounded context inside the unit.
- `workload-kind` separates operational classes such as `services`, `workers`, `schedulers`, `jobs`, and `stateful`.
- A domain `kustomization.yaml` composes workload-kind packages in that domain.
- A workload `kustomization.yaml` composes the Kubernetes object files for one deployable unit.
