#!/usr/bin/env bash
# Build the combined image (cb3-class): a cb2 base plus the baked-in
# combined entrypoint (bernd/combined-launcher). Thin layer, no component
# rebuilds — run it on a host that already has the base image (Babbler)
# and is logged into ghcr.io when pushing.
#
# Usage (from a clean checkout of this branch): bernd/build_combined.sh
#   BASE   base image (default ghcr.io/bernd-sprenger/lil-vllm:kk-20261120-cb2)
#   IMAGE  tag to build (default ghcr.io/bernd-sprenger/lil-vllm:kk-20261120-cb3)
#   PUSH   1 pushes IMAGE after the build
#
# Needs: docker with buildx (or legacy builder — no advanced syntax), git.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE="${BASE:-ghcr.io/bernd-sprenger/lil-vllm:kk-20261120-cb2}"
IMAGE="${IMAGE:-ghcr.io/bernd-sprenger/lil-vllm:kk-20261120-cb3}"
PUSH="${PUSH:-0}"

# The image records the recipe commit, so build only committed recipes.
if [[ -n "$(git -C "$RECIPE" status --porcelain)" ]]; then
    echo "error: $RECIPE has uncommitted changes" >&2
    exit 1
fi
RECIPE_COMMIT="$(git -C "$RECIPE" rev-parse HEAD)"

if ! docker image inspect "$BASE" >/dev/null 2>&1; then
    echo "error: base image $BASE not present locally (pull it first)" >&2
    exit 1
fi

docker build -q \
    --build-arg BASE="$BASE" \
    --label org.opencontainers.image.source=https://github.com/bernd-sprenger/lil-blackwell-llm-docker \
    --label org.opencontainers.image.revision="$RECIPE_COMMIT" \
    --label org.opencontainers.image.description="Combined launcher over $BASE: stock-LMCache MP server + vLLM engine in one container (LIL pattern)" \
    -t "$IMAGE" \
    "$SCRIPT_DIR/combined-launcher" >/dev/null

# --- Record what was built (same shape as build.sh's BUILT record).
{
    echo "image=$IMAGE"
    echo "image_id=$(docker image inspect --format '{{.Id}}' "$IMAGE")"
    echo "base=$BASE"
    echo "base_id=$(docker image inspect --format '{{.Id}}' "$BASE")"
    echo "recipe=$RECIPE_COMMIT"
    echo "entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$IMAGE")"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

if [[ "$PUSH" == 1 ]]; then
    docker push "$IMAGE"
fi
