# dev Application Unit Overlays

Add dev-only workload overrides here.

Shape:

```text
units/<unit>/<domain>/<workload-kind>/<workload>/kustomization.yaml
```

Each workload overlay must reference its base workload package and contain only dev-specific patches.
