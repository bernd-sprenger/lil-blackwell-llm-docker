#!/usr/bin/env bash
# Build ghcr.io/bernd-sprenger/lil-vllm: Local Inference Lab's
# karmic-kraken-20261020 image (LIL's nccl/flashinfer/lmcache bundles exactly
# as published) with vLLM and InstantTensor built from our forks. See README.md.
#
# Usage (on Babbler, from a clean checkout of this branch): bernd/build.sh
#   WORK   build tree, caches included (default /opt/data/build/lil-image)
#   IMAGE  tag to build (default ghcr.io/bernd-sprenger/lil-vllm:kk-20261020-cb1)
#   PUSH   1 pushes IMAGE after the build (needs docker login ghcr.io)
#
# Needs: docker with buildx, git, curl, python3, zstd, jq, unzip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="${WORK:-/opt/data/build/lil-image}"
IMAGE="${IMAGE:-ghcr.io/bernd-sprenger/lil-vllm:kk-20261020-cb1}"
PUSH="${PUSH:-0}"

# LIL's canonical karmic-kraken-20261020: the assembly lock that pins every
# component bundle by release asset ID and sha256. This branch is LIL's
# recipe commit 8bb0967 plus this directory.
ASSEMBLY_TAG=karmic-kraken-fd4ae19d3cce7a08f769c7ed9183dd5ac7eae0e082d090cb9c53923f84014d2d
ASSEMBLY_SHA256=726495437360dd409f0d3f53fffaf8334e767e3ec4a45c5ad714465b811fbbec

# vLLM: LIL's dev/karmic-kraken 8244d1c44 (the assembly's vLLM) plus the
# NVFP4-CSF flat slab fix. Python only, so it is built over LIL's native
# bundle instead of recompiling.
VLLM_REPO=https://github.com/bernd-sprenger/lil-vllm.git
VLLM_BRANCH=bernd/dev/karmic-kraken
VLLM_COMMIT=5697bddfcc9acb8a9d106d60c13b918fc0cd71f4

# InstantTensor: upstream v0.2.2 plus LIL's fork changes, the vLLM compat
# shim and the deferred budget check.
INSTANTTENSOR_REPO=https://github.com/bernd-sprenger/lil-InstantTensor.git
INSTANTTENSOR_BRANCH=bernd/main
INSTANTTENSOR_COMMIT=0ba90b914433ac30a16a2efa218841367a0b4033
# pagure.io is unreliable; LIL's own Dockerfiles use this mirror.
LIBAIO_MIRROR=https://github.com/sailfishos-mirror/libaio.git

BUILDER=lil-wheel-cu134-sm120

for cmd in docker git curl python3 zstd jq unzip; do
    if ! command -v "$cmd" >/dev/null; then
        echo "error: $cmd not found (apt install zstd jq unzip)" >&2
        exit 1
    fi
done

# The image records the recipe commit, so build only committed recipes.
if [[ -n "$(git -C "$RECIPE" status --porcelain)" ]]; then
    echo "error: $RECIPE has uncommitted changes" >&2
    exit 1
fi
RECIPE_COMMIT="$(git -C "$RECIPE" rev-parse HEAD)"
TOOLS="$RECIPE/tools/jovian_wheel_runtime"

# LIL's tools call `gh api` for public GitHub reads; the shim answers them.
export PATH="$SCRIPT_DIR/gh-shim:$PATH"
# Component archives and the exported NGC foundation, kept across runs.
export LIL_COMPONENT_ARCHIVE_CACHE="$WORK/cache/components"
export LIL_FOUNDATION_CACHE="$WORK/cache/foundation"
mkdir -p "$LIL_COMPONENT_ARCHIVE_CACHE" "$LIL_FOUNDATION_CACHE"

RUN="$WORK/runs/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN"
echo "Build tree: $RUN"

# --- Assembly lock: verify, then drop the InstantTensor entry (built below).
# vLLM stays: its bundle is the native base for our Python-only build.
gh api "repos/local-inference-lab/blackwell-llm-docker/releases/tags/$ASSEMBLY_TAG" \
    | jq -r '.assets[] | select(.name == "community-assembly.json") | .id' \
    > "$RUN/assembly-asset-id"
gh api "repos/local-inference-lab/blackwell-llm-docker/releases/assets/$(cat "$RUN/assembly-asset-id")" \
    -H "Accept: application/octet-stream" > "$RUN/community-assembly.json"
echo "$ASSEMBLY_SHA256  $RUN/community-assembly.json" | sha256sum --check --quiet
jq 'del(.components.instanttensor)' "$RUN/community-assembly.json" \
    > "$RUN/assembly-without-instanttensor.json"

# --- LIL's bundles, through LIL's own verified download (asset IDs, archive
# and manifest sha256 from the lock).
python3 "$TOOLS/container_channel.py" download \
    --assembly "$RUN/assembly-without-instanttensor.json" \
    --output "$RUN/bundles"

if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
    docker buildx create --name "$BUILDER" --driver docker-container \
        --config "$SCRIPT_DIR/buildkitd.toml" >/dev/null
fi
docker buildx inspect --bootstrap "$BUILDER" >/dev/null

# --- InstantTensor from our fork, built with its ci/lil_wheels/build_bundle.sh
# (same builder image and locks as LIL's).
IT_SRC="$RUN/instanttensor-src"
git clone -q --branch "$INSTANTTENSOR_BRANCH" "$INSTANTTENSOR_REPO" "$IT_SRC"
git -C "$IT_SRC" checkout -q --detach "$INSTANTTENSOR_COMMIT"
git -C "$IT_SRC" config submodule.csrc/third_party/libaio.url "$LIBAIO_MIRROR"
git -C "$IT_SRC" submodule update -q --init --recursive
test -z "$(git -C "$IT_SRC" status --porcelain)"
INSTANTTENSOR_RELEASE_TAG="instanttensor-cu134-bernd-$INSTANTTENSOR_COMMIT" \
GITHUB_REPOSITORY=bernd-sprenger/lil-InstantTensor \
    "$IT_SRC/ci/lil_wheels/build_bundle.sh" "$RUN/instanttensor"

# --- vLLM from our fork: a Python-only wheel over LIL's native bundle.
# build_bundle.sh refuses unless the native sources, locks and build tools
# are identical to the bundle's source commit.
VLLM_SRC="$RUN/vllm-src"
git clone -q --filter=blob:none --branch "$VLLM_BRANCH" "$VLLM_REPO" "$VLLM_SRC"
git -C "$VLLM_SRC" checkout -q --detach "$VLLM_COMMIT"
VLLM_PRECOMPILED_BUNDLE="$RUN/bundles/vllm" \
VLLM_RELEASE_TAG="vllm-jovian-cu134-bernd-$VLLM_COMMIT" \
GITHUB_REPOSITORY=bernd-sprenger/lil-vllm \
    "$VLLM_SRC/tools/jovian_wheel_release/build_bundle.sh" "$RUN/vllm"

# --- The image: LIL's local assembly over the pinned NGC foundation.
python3 "$TOOLS/build_local_runtime.py" \
    --output "$RUN/runtime" \
    --image "$IMAGE" \
    --nccl-bundle "$RUN/bundles/nccl" \
    --flashinfer-bundle "$RUN/bundles/flashinfer" \
    --vllm-bundle "$RUN/vllm/bundle" \
    --lmcache-bundle "$RUN/bundles/lmcache" \
    --instanttensor-bundle "$RUN/instanttensor/bundle"

# --- OCI labels (metadata only, no new layer): GHCR links the package to
# this repository through image.source.
printf '%s\n' \
    "FROM $IMAGE" \
    "LABEL org.opencontainers.image.source=https://github.com/bernd-sprenger/lil-blackwell-llm-docker" \
    "LABEL org.opencontainers.image.revision=$RECIPE_COMMIT" \
    "LABEL org.opencontainers.image.description=\"LIL karmic-kraken-20261020 with vLLM $VLLM_COMMIT and InstantTensor $INSTANTTENSOR_COMMIT from bernd-sprenger forks\"" \
    | docker build -q -t "$IMAGE" - >/dev/null

# --- Record what was built.
{
    echo "image=$IMAGE"
    echo "image_id=$(docker image inspect --format '{{.Id}}' "$IMAGE")"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "recipe=$RECIPE_COMMIT"
    echo "assembly=$ASSEMBLY_TAG"
    jq -r '.components | to_entries[] | select(.key != "vllm") | "\(.key)=\(.value.source_commit)"' \
        "$RUN/assembly-without-instanttensor.json"
    echo "vllm=$VLLM_COMMIT ($VLLM_REPO $VLLM_BRANCH, native bundle $(jq -r .source.commit "$RUN/bundles/vllm/manifest.json"))"
    echo "instanttensor=$INSTANTTENSOR_COMMIT ($INSTANTTENSOR_REPO $INSTANTTENSOR_BRANCH)"
    echo "runtime_manifest_sha256=$(sha256sum "$RUN/runtime/runtime/manifest.json" | cut -d' ' -f1)"
} | tee "$RUN/BUILT"

if [[ "$PUSH" == 1 ]]; then
    docker push "$IMAGE"
fi
