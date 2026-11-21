#!/usr/bin/env bash
# Build and normalize LMCache native extensions for the declared foundation.
# From local-inference-lab/LMCache ci/lil_wheels/build_wheel.sh (commit
# dde2c874); local changes: the +bernd local version tag, the
# LMCACHE_BASE_VERSION override, and the stale-build purge below.
set -euo pipefail

mkdir -p /wheelhouse
# The buildkit cache mount at /src/lmcache/build survives across builds.
# setuptools' incremental build_py overlays today's sources but NEVER
# removes files an older tree had — a changed-source rebuild silently
# packages the union of both trees (observed: the consolidation build
# shipped 0.5.7.post1-era l1_manager/ and quality_bench/ modules next to
# the Aug-30 module layout, producing ImportError mid-boot). Purge the
# stale lib/temp trees; the native .o cache dir value is gone either way,
# correctness wins.
rm -rf build/lib.* build/temp.* build/bdist.* build/wheel

# Shallow branch clones carry no tags, and setuptools_scm then reports
# 0.1.dev1 — below every feature gate. Pass a base from the outside
# (nearest release train the content derives from); empty = git-derived.
if [[ -n "${LMCACHE_BASE_VERSION:-}" ]]; then
    base_version="$LMCACHE_BASE_VERSION"
else
    base_version=$(/build-venv/bin/python -m setuptools_scm | tr -d '[:space:]')
    base_version=${base_version%%+*}
fi
package_version="${base_version}+bernd.cu134.g${SOURCE_COMMIT:0:12}"

env -u PYTHONPATH \
  SETUPTOOLS_SCM_PRETEND_VERSION_FOR_LMCACHE="${package_version}" \
  uv build \
    --wheel \
    --no-build-isolation \
    --python /build-venv/bin/python \
    --out-dir /wheelhouse \
    /src/lmcache

test "$(find /wheelhouse -maxdepth 1 -name 'lmcache-*.whl' | wc -l)" -eq 1
/build-venv/bin/python ci/lil_wheels/normalize_wheel.py \
  --wheel /wheelhouse/lmcache-*.whl \
  --torch-version 2.14.0a0+4fdf77b940.nv26.8.63802676 \
  --source-date-epoch "${SOURCE_DATE_EPOCH:?}"

/build-venv/bin/python - <<'PY'
from pathlib import Path
from zipfile import ZipFile

wheel = next(Path("/wheelhouse").glob("lmcache-*.whl"))
with ZipFile(wheel) as archive:
    cuda_extensions = [
        name
        for name in archive.namelist()
        if name.startswith("lmcache/cuda_ops.") and name.endswith(".so")
    ]
if len(cuda_extensions) != 1:
    raise RuntimeError(
        "LMCache wheel must contain exactly one lmcache.cuda_ops extension"
    )
print(f"lmcache_cuda_extension={cuda_extensions[0]}")
PY
