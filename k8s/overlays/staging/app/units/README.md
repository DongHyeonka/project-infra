# staging Application Unit Overlays

Add staging-only workload overrides here.

Shape:

```text
units/<unit>/<domain>/<workload-kind>/<workload>/kustomization.yaml
```

Each workload overlay must reference its base workload package and contain only staging-specific patches.
