#!/usr/bin/env bash
# Run `helm dependency update` for every chart in charts/.
# Useful before tagging a release or after editing Chart.yaml dependencies.

set -euo pipefail

cd "$(dirname "$0")/.."

for chart in charts/*/; do
  [[ -f "${chart}Chart.yaml" ]] || continue
  echo "==> helm dependency update ${chart}"
  helm dependency update "${chart}"
done

echo
echo "All chart dependencies updated."
