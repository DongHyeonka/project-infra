# prod Application Unit Overlays

Add prod-only workload overrides here.

Shape:

```text
units/<unit>/<domain>/<workload-kind>/<workload>/kustomization.yaml
```

Each workload overlay must reference its base workload package and contain only prod-specific patches.
