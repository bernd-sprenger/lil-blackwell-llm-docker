#!/usr/bin/env bash
# Build a karmic-kraken-envelope LMCache bundle from STOCK upstream source.
#
# LIL's own ci/lil_wheels pipeline (their LMCache fork) produces the +lil
# bundle the assembly publishes. This script runs the same Dockerfile, the
# same builder image, the same normalization and the same bundle schema —
# over an unmodified upstream LMCache tag. The resulting wheel is a source
# build against the exact NGC foundation (torch 2.14.0a0+nv26.08), which the
# upstream release wheels are NOT: they are built against stable torch and
# their cuda_ops fails to load in this image (verified: undefined symbol
# _ZN3c104cuda19CUDAErrorLogCaptureC1Ev from the v0.5.7.post1 cp312 wheel).
#
# Usage (on Babbler): bernd/stock-lmcache/build_bundle.sh [OUTPUT_DIR]
#   LMCACHE_TAG     upstream tag to build (default v0.5.7.post1)
#   WORK            build tree (default /opt/data/build/lil-image, shared
#                   with bernd/build.sh so the component cache is reused)
#
# Emits OUTPUT_DIR/bundle (manifest.json + wheels/ + SHA256SUMS), ready for
# bernd/build.sh's LMCACHE_BUNDLE=<path>. The manifest's source.repository
# and commit point at upstream: the tree is exactly the tag, the ci/lil_wheels
# staging below is untracked and does not enter the recorded git tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$SCRIPT_DIR"
OUTPUT_DIR=${1:-"$SCRIPT_DIR/dist/lmcache-stock"}
LMCACHE_TAG="${LMCACHE_TAG:-v0.5.7.post1}"
WORK="${WORK:-/opt/data/build/lil-image}"

for cmd in docker git jq python3 curl unzip; do
    if ! command -v "$cmd" >/dev/null; then
        echo "error: $cmd not found" >&2
        exit 1
    fi
done

lock_value() {
    awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; found=1} END {exit !found}' \
        "$TOOLS/runtime.lock"
}

SRC="$OUTPUT_DIR/lmcache-src"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/raw" "$OUTPUT_DIR/bundle/wheels" "$WORK/cache/components"

echo "-- Cloning upstream LMCache at $LMCACHE_TAG"
git clone -q --branch "$LMCACHE_TAG" --depth 1 \
    https://github.com/LMCache/LMCache.git "$SRC"
SOURCE_COMMIT=$(git -C "$SRC" rev-parse HEAD)
SOURCE_TREE=$(git -C "$SRC" rev-parse 'HEAD^{tree}')
SOURCE_DATE_EPOCH=$(git -C "$SRC" show -s --format=%ct HEAD)
echo "   commit $SOURCE_COMMIT (tree $SOURCE_TREE)"

# Stage the wheel tools inside the checkout; untracked files keep the
# recorded tree the pure upstream tag. The Dockerfile's COPY relies on
# them living at ci/lil_wheels, exactly as in LIL's fork.
mkdir -p "$SRC/ci/lil_wheels"
cp "$TOOLS/Dockerfile" "$TOOLS/build_wheel.sh" "$TOOLS/normalize_wheel.py" \
    "$TOOLS/build-requirements.lock" "$TOOLS/runtime.lock" \
    "$SRC/ci/lil_wheels/"

# The runtime assembly packages a cuMem interposer for the +lil engine-driven
# cache path; upstream LMCache has no such component (csrc/cumem_ipc_interposer
# is fork-only). This branch's prepare_runtime_auxiliary.py recognizes the
# stock bundle's source.upstream marker and records the absence instead of
# fetching fork-only files from a repository that does not contain the commit.

BUILDER=$(lock_value buildx.builder)
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
    docker buildx create --name "$BUILDER" --driver docker-container \
        --config "$SCRIPT_DIR/../buildkitd.toml" >/dev/null
fi
docker buildx inspect --bootstrap "$BUILDER" >/dev/null

echo "-- Building the wheel in the pinned foundation"
docker buildx build \
    --progress=plain \
    --builder "$BUILDER" \
    --file "$SRC/ci/lil_wheels/Dockerfile" \
    --build-arg "BUILDER_IMAGE=$(lock_value builder.image)" \
    --build-arg "UV_IMAGE=$(lock_value uv.image)" \
    --build-arg "UV_SHA256=$(lock_value uv.sha256)" \
    --build-arg "SOURCE_COMMIT=${SOURCE_COMMIT}" \
    --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
    --target export \
    --output "type=local,dest=${OUTPUT_DIR}/raw" \
    "$SRC"
cp -a "$OUTPUT_DIR/raw/wheels/." "$OUTPUT_DIR/bundle/wheels/"

wheel=$(find "$OUTPUT_DIR/bundle/wheels" -maxdepth 1 -name 'lmcache-*.whl' -print -quit)
test -n "$wheel"
metadata=$(unzip -p "$wheel" '*/METADATA')
package_name=$(awk -F': ' '$1 == "Name" {print $2; exit}' <<<"$metadata}")
package_version=$(awk -F': ' '$1 == "Version" {print $2; exit}' <<<"$metadata}")
test "$package_name" = lmcache
unzip -Z1 "$wheel" | grep -Eq '^lmcache/cuda_ops\.[^/]*\.so$'
digest=$(sha256sum "$wheel" | awk '{print $1}')
file=$(basename "$wheel")
echo "-- Wheel: $file"

jq -n \
    --arg status "research-only" \
    --arg repository "https://github.com/bernd-sprenger/lil-blackwell-llm-docker" \
    --arg tag "${LMCACHE_TAG}" \
    --arg commit "${SOURCE_COMMIT}" \
    --arg tree "${SOURCE_TREE}" \
    --arg package_version "${package_version}" \
    --arg file "${file}" \
    --arg sha256 "${digest}" \
    --arg builder_image "$(lock_value builder.image)" \
    --arg python "$(lock_value python.version)" \
    --arg cuda "$(lock_value cuda.version)" \
    --arg pytorch "$(lock_value pytorch.version)" \
    --arg pytorch_commit "$(lock_value pytorch.commit)" \
    --arg cuda_arch_list "$(lock_value cuda.arch-list)" \
    '{schema: "local-inference-lmcache-wheel-release/v1", status: $status,
      scope: "STOCK upstream LMCache, rebuilt for the declared ABI by bernd/stock-lmcache in bernd-sprenger/lil-blackwell-llm-docker",
      source: {upstream: "https://github.com/LMCache/LMCache.git",
        tag: $tag, commit: $commit, tree: $tree, recipe: $repository},
      package_version: $package_version,
      release_tag: ("lmcache-cu134-sm120-stock-bernd-" + $commit),
      runtime: {builder_image: $builder_image, python: $python, cuda: $cuda,
        pytorch: $pytorch, pytorch_commit: $pytorch_commit,
        cuda_arch_list: $cuda_arch_list},
      packages: [{name: "lmcache", version: $package_version, file: $file,
        sha256: $sha256, url: $repository}]}' \
    > "$OUTPUT_DIR/bundle/manifest.json"

(
    cd "$OUTPUT_DIR/bundle"
    find wheels -maxdepth 1 -name '*.whl' -print0 | sort -z | xargs -0 sha256sum
    sha256sum manifest.json
) > "$OUTPUT_DIR/bundle/SHA256SUMS"

echo "-- Bundle: $OUTPUT_DIR/bundle"
echo "   Feed it to bernd/build.sh with LMCACHE_BUNDLE=$OUTPUT_DIR/bundle"
