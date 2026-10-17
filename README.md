# eks-observability-helm-charts

**Versioned Helm chart definitions for the observability platform.**

This repo holds the umbrella Helm charts that the platform deploys. Each
chart is a thin wrapper around an upstream chart (Prometheus community,
Grafana, Bitnami, external-secrets, etc.) plus the values we want.

> One of three repos. The other two are
> [`eks-observability-iac`](https://github.com/Rashed00/eks-observability-iac)
> (AWS infrastructure, spin-up and destroy scripts) and
> [`eks-observability-gitops`](https://github.com/Rashed00/eks-observability-gitops)
> (ArgoCD Applications that deploy these charts).

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
   │   Every chart change pushed to main is version-bumped,       │
   │   packaged and published to GitHub Pages automatically.      │
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
│   ├── grafana/                    Standalone Grafana (alternative, not deployed)
│   ├── grafana-operator/           Operator that manages Grafana via CRDs
│   ├── alloy/                      Hub-cluster telemetry collector (DaemonSet)
│   ├── envoy-gateway/              Gateway API implementation
│   ├── external-secrets/           Syncs AWS Secrets Manager into K8s
│   ├── prometheus-operator-crds/   CRDs (install before kube-prometheus-stack)
│   └── metrics-server/             kubectl top + HPA
├── ct.yaml                         chart-testing config
├── scripts/
│   ├── update-deps.sh              `helm dependency update` for every chart
│   └── ci/bump-changed-charts.sh   Bumps the version of each changed chart (used by release.yml)
└── .github/workflows/
    ├── pr-validate.yml             helm lint + helm template + kubeconform
    └── release.yml                 Bump + publish to gh-pages + notify gitops, on push to main
```

Each chart's `charts/<name>/` contains:

```
charts/<name>/
├── Chart.yaml          One pinned dependency on the upstream chart.
├── values.yaml         The values we deploy (real values for our one environment).
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

The charts are published at `https://rashed00.github.io/eks-observability-helm-charts`.
To browse them locally:

```bash
helm repo add eks-observability https://rashed00.github.io/eks-observability-helm-charts
helm repo update
helm search repo eks-observability
```

ArgoCD does this automatically: each Application in the gitops repo
references this URL directly.

---

## Day-2 operations

You never edit a chart's `version` or the gitops `targetRevision` by hand.
Pushing a chart change to `main` does both.

### Change values for an existing chart

1. Edit `charts/<name>/values.yaml`.
2. Open a PR — CI runs `helm lint`, `helm template`, and `kubeconform`.
   Add a `minor` or `major` label if the change needs more than a patch bump.
3. Merge (or push to `main`). The `release.yml` workflow:
   - bumps `version` in `charts/<name>/Chart.yaml` and commits it to `main`,
   - packages the chart and publishes it to `gh-pages`,
   - tells the gitops repo, which sets the new `targetRevision` and pushes.
   ArgoCD deploys the new version a few minutes later.
4. **Run `git pull`.** The bot's bump commit is now on top of yours.

If you bump `version` yourself in the same push, the workflow keeps your
number and just releases it.

### Upgrade the upstream chart

1. Bump the version in `charts/<name>/Chart.yaml` `dependencies[0].version`.
2. Run `scripts/update-deps.sh` locally to refresh `Chart.lock`.
3. Inspect the upstream's CHANGELOG / NOTES for breaking changes in values.
4. Update `values.yaml` if needed; commit; PR. Add the `major` label for an
   upstream major version.

### Add a new chart

1. `mkdir -p charts/<name>/ci`
2. Write `Chart.yaml` (one dep, pinned), `values.yaml`, `README.md`,
   `ci/values-ci.yaml`.
3. Open a PR. CI picks the new chart up automatically (the matrix workflow
   detects added directories).
4. After merge, the chart is released at the version in its `Chart.yaml`.
   Add an Application for it in the gitops repo; from then on, every
   change is bumped and rolled out automatically.

### Catch up a missed release in gitops

If the notify step failed (for example the token expired), the chart is
released but gitops was not told. In the gitops repo: Actions →
"Bump targetRevision" → Run workflow, with the chart name and version.
Do not use "Re-run failed jobs" here: it would bump the version a second time.

---

## Values are real, not placeholders

Each `values.yaml` holds the real values for our one environment (AWS
account ID in role ARNs, bucket names, region, domain). None of them are
secrets; passwords live in AWS Secrets Manager. `pr-validate.yml` fails on
any leftover `<PLACEHOLDER>`, because ArgoCD would deploy it as is. See
[`ARCHITECTURE.md`](./ARCHITECTURE.md) for why, and how to move the
platform to another account.

---

## CI/CD

| Workflow | When | What |
|---|---|---|
| `pr-validate.yml` | PR opened / updated | Detects changed charts → matrix-runs `helm dependency update`, `helm lint`, `helm template`, `kubeconform`. Fails on leftover placeholders. |
| `release.yml` | Push to `main` (chart file changed), or manual run | Bumps the version of each changed chart and commits it, publishes with `helm/chart-releaser-action` to the `gh-pages` branch, then sends a `chart-released` event to the gitops repo. A manual run skips the bump and only publishes unreleased versions. |

`release.yml` needs, once:
- Settings → Pages → deploy from the `gh-pages` branch.
- Settings → Actions → General → Workflow permissions: **Read and write**.
- Secret `GITOPS_DISPATCH_TOKEN`: fine-grained token, repository
  `eks-observability-gitops` only, permission **Contents: Read and write**.
  It expires; regenerate it and update the secret when it does.
- Optional: PR labels `minor` and `major`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `helm dependency update` fails with 403 on OCI | The upstream chart moved registries (Bitnami moved older Thanos images to `bitnamilegacy`). Check `Chart.yaml` repository URL. |
| kubeconform complains about CRDs (PrometheusRule, ServiceMonitor, etc.) | The CI step uses the datreeio/CRDs-catalog so common operator CRDs are known. If yours isn't there, add a `-schema-location` for it. |
| ArgoCD says "chart not found" | The release workflow hasn't run yet, or GitHub Pages isn't enabled. Check the `gh-pages` branch has an `index.yaml`. |
| `git push` rejected after a chart change | The bot pushed a version bump on top of your last commit. Run `git pull`, then push again. |
| Release run fails at "Tell the gitops repo" with 403 | `GITOPS_DISPATCH_TOKEN` lacks **Contents: Read and write** on the gitops repo, or has expired. Fix the token, then catch up by hand (see above). |
| Release run fails at "Commit and push the bump" | `main` is protected. Allow GitHub Actions to push, or remove the protection. |