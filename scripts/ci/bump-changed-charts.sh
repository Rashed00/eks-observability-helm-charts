#!/usr/bin/env bash
# bump-changed-charts.sh - bump the version of every chart changed in a push.
#
# Used by .github/workflows/release.yml. Can also be run by hand to see what
# it would do (it only edits Chart.yaml files, it does not commit).
#
#   scripts/ci/bump-changed-charts.sh <before-sha> <after-sha> <patch|minor|major>
#
# For each chart folder changed between the two commits:
#   - only README.md, README.pdf or ci/ changed  -> ignored (nothing deployable changed)
#   - Chart.yaml "version" was already changed     -> left alone (you bumped it by hand)
#   - chart is new in this push                    -> left alone (its first version is released as is)
#   - otherwise                                    -> version bumped (patch/minor/major)
#
# Prints one line per chart to release, "<name> <version>", on stdout.
# Everything else goes to stderr.

set -euo pipefail

BEFORE="${1:?before sha}"
AFTER="${2:?after sha}"
BUMP="${3:-patch}"
CHARTS_DIR="${CHARTS_DIR:-charts}"

case "${BUMP}" in patch|minor|major) ;; *) echo "Unknown bump '${BUMP}'" >&2; exit 2 ;; esac

chart_version() {  # <file content on stdin> -> version
  awk '/^version:/ { gsub(/["'\'' ]/, "", $2); print $2; exit }'
}

next_version() {  # <version> <bump>
  local core="${1%%-*}" major minor patch
  IFS=. read -r major minor patch <<<"${core}"
  major="${major:-0}" minor="${minor:-0}" patch="${patch:-0}"
  case "$2" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
  esac
}

# Chart folders with at least one deployable file changed.
mapfile -t charts < <(git diff --name-only "${BEFORE}" "${AFTER}" -- "${CHARTS_DIR}/" \
  | awk -F/ -v d="${CHARTS_DIR}" '
      $1 != d || NF < 3 { next }
      $3 == "README.md" || $3 == "README.pdf" || $3 == "ci" { next }
      { print $2 }' \
  | sort -u)

if [[ "${#charts[@]}" -eq 0 ]]; then
  echo "No deployable chart changes in this push." >&2
  exit 0
fi

for name in "${charts[@]}"; do
  file="${CHARTS_DIR}/${name}/Chart.yaml"

  if [[ ! -f "${file}" ]]; then
    echo "${name}: chart was removed, skipping." >&2
    continue
  fi

  current="$(chart_version <"${file}")"
  if [[ -z "${current}" ]]; then
    echo "${name}: no 'version:' line in ${file}" >&2
    exit 1
  fi

  if ! old_content="$(git show "${BEFORE}:${file}" 2>/dev/null)"; then
    echo "${name}: new chart, releasing ${current} as is." >&2
    echo "${name} ${current}"
    continue
  fi

  previous="$(chart_version <<<"${old_content}")"
  if [[ "${previous}" != "${current}" ]]; then
    echo "${name}: version already bumped by hand (${previous} -> ${current}), leaving it." >&2
    echo "${name} ${current}"
    continue
  fi

  new="$(next_version "${current}" "${BUMP}")"
  sed -i -E "s/^version:.*/version: ${new}/" "${file}"
  echo "${name}: ${current} -> ${new} (${BUMP})" >&2
  echo "${name} ${new}"
done