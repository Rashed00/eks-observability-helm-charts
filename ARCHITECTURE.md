# Architecture

This document explains **why** the helm-charts repo is shaped this way.

## Two questions to answer up-front

### Why not just point ArgoCD at upstream charts directly?

You could. The gitops repo could write:

```yaml
spec:
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 80.4.1
    helm:
      valueFiles: [ values-prod.yaml ]
```

But then every ArgoCD `Application` is responsible for pinning its own
version, and the values file lives somewhere else (often in the gitops
repo). When you upgrade Loki from 6.49 to 7.0, you have to:

1. Read the upstream CHANGELOG.
2. Update the Application's `targetRevision`.
3. Find and edit the matching values file.
4. PR-review the change across two files in two locations.

With umbrella charts, the upgrade is **one PR, one file**:

```yaml
# charts/loki/Chart.yaml
dependencies:
  - name: loki
    version: "7.0.0"   # bumped from 6.49.0
```

The release workflow packages it, ArgoCD pulls the new version, and
because the values file is part of the same chart, you've also reviewed
any required values changes in the same PR.

### Why does the values file live next to the chart, not in gitops?

Two reasons.

**One: locality of reference.** A Helm chart is a deployable unit: chart
templates + default values. Splitting the values across repositories means
"to understand what this chart deploys" requires opening two files in two
repos. Painful for a junior, painful at 3 a.m. during an incident.

**Two: testability.** With values next to the chart, `helm template
charts/loki` is a complete, validatable rendering — no extra files needed.
CI can render every chart with no cross-repo coordination.

The trade-off: environment-specific overrides require a small amount of
work. For this platform we have **one environment** (production), so the
values file is environment-ready. If you need a second environment later,
the right answer is `charts/loki/values-staging.yaml` *next to*
`values.yaml`, not a separate file in gitops.

## How charts are versioned

`Chart.yaml` has two version fields:

- `version` — the **umbrella chart** version. Bump on every change.
- `appVersion` — informational; tracks the upstream's app version.

Plus the pinned upstream dep:

```yaml
dependencies:
  - name: kube-prometheus-stack
    version: "80.4.1"   # pinned
```

The umbrella's `version` is what ArgoCD references via
`Application.spec.source.targetRevision`. Use semver:

| Change | Bump |
|---|---|
| values.yaml tweak (no upstream change) | patch (`1.0.1`) |
| Add a new value, no breaking change | minor (`1.1.0`) |
| Upgrade upstream major version | major (`2.0.0`) |

## How releases work

`helm/chart-releaser-action` (in `.github/workflows/release.yml`):

1. Scans the `charts/` directory.
2. For each chart whose `version` is newer than the latest git tag, runs
   `helm package` to produce a `.tgz`.
3. Creates a GitHub Release with the tarball attached.
4. Updates `index.yaml` on the `gh-pages` branch to point at the new release.

GitHub Pages serves the `gh-pages` branch as a static site, which is a
valid Helm repository.

## Placeholders, and why values.yaml is checked in with `<ACCOUNT_ID>` in it

Production secrets and environment-specific identifiers must NOT live in
the chart's `values.yaml`, because anyone with read access to the repo can
see them. We use `<ACCOUNT_ID>`, `<AWS_REGION>`, `<TEMPO_BUCKET>` etc. as
deliberate placeholders.

When the gitops repo references a chart from this repo, ArgoCD downloads
the packaged tarball. The placeholders are still there. The gitops repo's
ArgoCD `Application` either:

1. Substitutes them via `Application.spec.source.helm.values` inline (for
   small/few values), or
2. References an in-cluster ConfigMap or rendered values file
   (`Application.spec.source.helm.valueFiles`) — but for our setup this is
   rarely necessary because Terraform outputs are stable across the
   cluster's lifetime.

The CI workflow has its own `ci/values-ci.yaml` per chart that overrides
placeholders with synthetic values so `helm template` + `kubeconform` can
validate the rendered manifests.

## Future improvements (not done yet)

- **values.schema.json per chart** — Helm 3 supports JSON schema for values.
  Adding one per chart lets CI catch typos in `values.yaml` and surfaces
  clearer error messages to the gitops repo.
- **helm-docs** — auto-generated `README.md` from `Chart.yaml` + `values.yaml`.
- **OCI publishing** — alternative to GitHub Pages. ghcr.io supports
  OCI-registry Helm repos. Pages is simpler for a learning project.
