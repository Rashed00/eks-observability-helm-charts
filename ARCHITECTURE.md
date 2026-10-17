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

The release workflow bumps the umbrella version, packages it and tells the
gitops repo, which points the Application at the new version. ArgoCD then
deploys it. Because the values file is part of the same chart, you've also
reviewed any required values changes in the same PR.

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

- `version` — the **umbrella chart** version. Bumped automatically by
  `release.yml` on every push to main that changes the chart (patch by
  default; add a `minor` or `major` label to the PR for a bigger bump).
  A version you bump by hand is kept. After release, the gitops repo is
  told and sets the matching `targetRevision` itself.
- `appVersion` — informational; tracks the upstream's app version.

Plus the pinned upstream dep:

```yaml
dependencies:
  - name: kube-prometheus-stack
    version: "80.4.1"   # pinned
```

The umbrella's `version` is what ArgoCD references via
`Application.spec.source.targetRevision`. Semver, chosen with a PR label:

| Change | Bump | How |
|---|---|---|
| values.yaml tweak (no upstream change) | patch (`1.0.1`) | default, no label |
| Add a new value, no breaking change | minor (`1.1.0`) | `minor` label on the PR |
| Upgrade upstream major version | major (`2.0.0`) | `major` label on the PR |

## How releases work

Everything happens in one workflow, `.github/workflows/release.yml`, on
every push to `main` that changes a chart:

1. **Bump.** `scripts/ci/bump-changed-charts.sh` compares the push with the
   previous commit. For each chart whose deployable files changed, it bumps
   `version` in `Chart.yaml` (patch, or what the PR label says). It skips
   charts where only `README.md`, `README.pdf` or `ci/` changed, new charts,
   and charts whose version you already bumped by hand. The bot commits the
   bump to `main`.
2. **Release.** `helm/chart-releaser-action` packages every chart whose
   `version` has no release yet, creates a GitHub Release with the `.tgz`,
   and updates `index.yaml` on the `gh-pages` branch. GitHub Pages serves
   that branch as a Helm repository.
3. **Notify.** For each released chart, the workflow sends a
   `chart-released` event (chart name + version) to the gitops repo. The
   gitops workflow `bump-target-revision.yml` waits until the version is in
   `index.yaml`, sets `targetRevision` on the matching Application(s) and
   pushes to `main`. ArgoCD deploys it.

Why bump and release live in one workflow: a commit pushed by the bot with
`GITHUB_TOKEN` does not start other workflows. A separate bump workflow
would never trigger the release. For the same reason the bot's own commit
cannot start a loop.

The notify step needs the secret `GITOPS_DISPATCH_TOKEN`: a fine-grained
token for the gitops repo only, with **Contents: Read and write** (an
Actions permission alone returns 403). If the secret is missing, the chart
is still released and the run shows a warning.

## Environment values live in values.yaml

This platform has one environment, so each chart's `values.yaml` holds the
real values for it: the AWS account ID in IRSA role ARNs, S3 bucket names,
the region and the domain. The gitops Applications do not override any
values; they only pick the chart and version.

None of these are secrets. Account IDs, bucket names and role ARNs are
identifiers; access is controlled by IAM. Real secrets (passwords, the
remote-write credentials) never appear here: Terraform writes them to AWS
Secrets Manager, and External Secrets syncs them into the cluster.

To run the platform in another AWS account or domain, search for the
account ID and domain in `charts/*/values.yaml` and replace them.

`pr-validate.yml` fails if a chart still contains an angle-bracket
placeholder such as `<ACCOUNT_ID>`, because ArgoCD would deploy it as is.
Each chart's `ci/values-ci.yaml` holds the overrides CI needs to render it
with `helm template` + `kubeconform`.

## Future improvements (not done yet)

- **values.schema.json per chart** — Helm 3 supports JSON schema for values.
  Adding one per chart lets CI catch typos in `values.yaml` and surfaces
  clearer error messages to the gitops repo.
- **helm-docs** — auto-generated `README.md` from `Chart.yaml` + `values.yaml`.
- **OCI publishing** — alternative to GitHub Pages. ghcr.io supports
  OCI-registry Helm repos. Pages is simpler for a learning project.