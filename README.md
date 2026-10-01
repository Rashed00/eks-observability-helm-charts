# eks-observability-helm-charts

**Versioned Helm chart definitions for the observability platform.**

This repo holds the umbrella Helm charts that the platform deploys. Each
chart is a thin wrapper around an upstream chart (Prometheus community,
Grafana, Bitnami, external-secrets, etc.) plus the values we want.

> One of three repos. See the [top-level README](../README.md) for how this
> repo fits with `eks-observability-iac` and `eks-observability-gitops`.

---

## The big picture

```
                                       gitops repo
                              (ArgoCD Applications)
                                       │
                                       │ "deploy chart X@version Y"
                                       ▼
   ┌──────────────────────────────────────────────────────────────┐
   │   THIS repo (eks-observability-helm-charts)                  │
   │                                                              │
   │   ┌────────────────────────────────────────────────────┐     │
   │   │ charts/<name>/                                     │     │
   │   │   ├── Chart.yaml      one upstream dep, pinned     │     │
   │   │   ├── values.yaml     environment-ready values     │     │
   │   │   ├── README.md       what this chart is           │     │
   │   │   └── ci/values-ci.yaml   CI-only overrides        │     │
   │   └────────────────────────────────────────────────────┘     │
   │                                                              │
   │   Packaged + published to GitHub Pages on every release tag. │
   └──────────────────────────────────────────────────────────────┘
                                       │
                                       │ helm pull / install
                                       ▼
                          Upstream Helm chart + our values.yaml
                                       │
                                       ▼
                               Kubernetes cluster
```

## Why umbrella charts?

We don't fork the upstream Prometheus / Grafana / Loki / ... charts. We
write a tiny `Chart.yaml` that depends on the upstream chart at a **pinned
version** and ship our `values.yaml` next to it.

Benefits:

| | Without umbrella charts | With umbrella charts |
|---|---|---|
| Where is the version pinned? | Spread across many ArgoCD Application YAMLs | Single `Chart.yaml` per component |
| Where do the values live? | Could be anywhere | Always next to `Chart.yaml` |
| How do you test locally? | `helm template <upstream> --values <somewhere>` | `helm template charts/<name>` — done |
| How does the gitops repo refer to it? | `repoURL: <upstream-helm-repo>` + `chart: <name>` + values from elsewhere | `repoURL: <our-pages-url>` + `chart: <name>` — values are inside |

The values file lives **with the chart**, not in the gitops repo. That's
intentional — see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Repo layout

```
eks-observability-helm-charts/
├── charts/
│   ├── kube-prometheus-stack/      Prometheus + Alertmanager + Operator
│   ├── thanos/                     Long-term metrics + multi-cluster query
│   ├── loki/                       Logs (S3 backend)
│   ├── tempo/                      Traces (S3 backend, OTLP)
│   ├── grafana/                    Standalone Grafana (alternative)
│   ├── grafana-operator/           Operator that manages Grafana via CRDs
│   ├── alloy/                      Hub-cluster telemetry collector (DaemonSet)
│   ├── envoy-gateway/              Gateway API implementation
│   ├── external-secrets/           Syncs AWS Secrets Manager into K8s
│   ├── prometheus-operator-crds/   CRDs (install before kube-prometheus-stack)
│   └── metrics-server/             kubectl top + HPA
├── ct.yaml                         chart-testing config
├── scripts/update-deps.sh          `helm dependency update` for every chart
└── .github/workflows/
    ├── pr-validate.yml             helm lint + helm template + kubeconform
    └── release.yml                 Package + publish to gh-pages on push
```

Each chart's `charts/<name>/` contains:

```
charts/<name>/
├── Chart.yaml          One pinned dependency on the upstream chart.
├── values.yaml         The values we deploy. May contain placeholders.
├── README.md           What this chart is + required external resources.
└── ci/
    └── values-ci.yaml  Overrides used only by CI to render valid manifests.
```

---

## Prerequisites

| Tool | Version |
|---|---|
| Helm | >= 3.14 |
| kubeconform (for local validation) | >= 0.6 |

---

## First-time setup (consumer side)

After the maintainer publishes a release, consumers (the gitops repo)
add this as a Helm repo:

```bash
helm repo add eks-observability https://<owner>.github.io/eks-observability-helm-charts
helm repo update
helm search repo eks-observability
```

ArgoCD does this automatically once the GitHub Pages URL is referenced in
an Application.

---

## Day-2 operations

### Change values for an existing chart

1. Edit `charts/<name>/values.yaml`.
2. **Bump the version** in `charts/<name>/Chart.yaml` (the umbrella's `version:`,
   not the upstream `appVersion:`). Use semver — patch for values-only
   changes, minor for new upstream chart deps.
3. Open a PR — CI runs `helm lint`, `helm template`, and `kubeconform`.
4. After merge, the `release.yml` workflow packages the chart and pushes
   to `gh-pages`. ArgoCD picks up the new version when you reference it
   in an Application in the gitops repo.

### Upgrade the upstream chart

1. Bump the version in `charts/<name>/Chart.yaml` `dependencies[0].version`.
2. Run `scripts/update-deps.sh` locally to refresh `Chart.lock`.
3. Inspect the upstream's CHANGELOG / NOTES for breaking changes in values.
4. Update `values.yaml` if needed; commit; PR.

### Add a new chart

1. `mkdir -p charts/<name>/ci`
2. Write `Chart.yaml` (one dep, pinned), `values.yaml`, `README.md`,
   `ci/values-ci.yaml`.
3. Open a PR. CI will pick the new chart up automatically (matrix workflow
   detects added directories).

---

## Placeholders in values.yaml

Several `values.yaml` files contain literal `<ACCOUNT_ID>`, `<AWS_REGION>`,
or `<TEMPO_BUCKET>` strings. They're intentional — when the gitops repo
references a chart from this repo, ArgoCD reads the published tarball as-is.
Those values exist so that the chart's `values.yaml` is **identical for every
environment that uses this platform**; environment-specific overrides go
in the consumer (the gitops repo's ArgoCD `Application.spec.source.helm`).

CI provides `ci/values-ci.yaml` per chart that replaces the placeholders with
synthetic values so `helm template` produces valid Kubernetes manifests for
kubeconform.

---

## CI/CD

| Workflow | When | What |
|---|---|---|
| `pr-validate.yml` | PR opened / updated | Detects changed charts → matrix-runs `helm dependency update`, `helm lint`, `helm template`, `kubeconform`. |
| `release.yml` | Push to `main` (chart file changed) | Runs `helm/chart-releaser-action` — packages bumped charts and publishes to `gh-pages` branch (served as a Helm repo at `https://<owner>.github.io/eks-observability-helm-charts`). |

The release workflow only packages a chart when its `Chart.yaml` `version`
field is newer than the latest tag for that chart — so a PR that doesn't
bump the version is a values-rendering test, not a release.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `helm dependency update` fails with 403 on OCI | The upstream chart moved registries (Bitnami moved older Thanos images to `bitnamilegacy`). Check `Chart.yaml` repository URL. |
| kubeconform complains about CRDs (PrometheusRule, ServiceMonitor, etc.) | The CI step uses the datreeio/CRDs-catalog so common operator CRDs are known. If yours isn't there, add a `-schema-location` for it. |
| ArgoCD says "chart not found" | The release workflow hasn't run yet, or GitHub Pages isn't enabled. Check the `gh-pages` branch has an `index.yaml`. |
