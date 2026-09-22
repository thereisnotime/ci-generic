#!/usr/bin/env bash
# Build the image with every version taken from versions.env.
#
# The Dockerfile's ARGs have no defaults on purpose: a build that forgets one
# fails immediately rather than baking in whatever was there last. That makes
# this script the only supported way to build, locally and in CI.
set -euo pipefail

cd "$(dirname "$0")"

TAG="${1:-ci-generic:local}"

args=()
while IFS='=' read -r key value; do
  [[ "$key" =~ ^[A-Z_]+_VERSION$ ]] || continue
  args+=(--build-arg "${key}=${value}")
done < versions.env

if [ ${#args[@]} -eq 0 ]; then
  echo "no versions found in versions.env" >&2
  exit 1
fi

echo "building ${TAG} with ${#args[@]} pinned versions"
exec docker build "${args[@]}" -t "${TAG}" .
