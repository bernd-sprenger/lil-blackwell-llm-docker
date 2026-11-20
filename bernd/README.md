# bernd: our build of the Local Inference Lab vLLM image

`build.sh` builds `ghcr.io/bernd-sprenger/lil-vllm:kk-20261020-cb1`. It is
LIL's canonical `karmic-kraken-20261020` image with two components built from
our forks:

| Component | Source | Change |
|---|---|---|
| vLLM | [lil-vllm](https://github.com/bernd-sprenger/lil-vllm) `bernd/dev/karmic-kraken` | LIL's `8244d1c44` + the NVFP4-CSF flat slab fix |
| InstantTensor | [lil-InstantTensor](https://github.com/bernd-sprenger/lil-InstantTensor) `bernd/main` | upstream v0.2.2 instead of LIL's 0.1.9, + 3 patches |

Everything else comes as LIL published it: the recipe (this branch is LIL's
`8bb0967` plus this directory), the nccl, flashinfer (with B12X) and lmcache
bundles from the release's `community-assembly.json`, fetched and verified by
LIL's own `container_channel.py download`, and the image assembly by LIL's
`build_local_runtime.py` over the pinned NGC PyTorch foundation.

## Why

**InstantTensor 0.1.9 hangs at startup.** Every LIL image up to 2026-10-20
ships it, and it has a use-after-free race: the loader thread's destructor
frees the RPC reply queue while `close()` may still be polling it. When the
race hits, one tensor-parallel rank spins forever in
`LoaderManager::get_result` at the end of a weight load, and the others wait on
it. GLM-5.3 hung like this in 4 of 7 boots, on different ranks. The I/O backend
doesn't matter; `INSTANTTENSOR_BACKEND=MMAP` didn't prevent it. Upstream fixed
it in scitix/InstantTensor 610338f (v0.2.1). Our branch is v0.2.2 (`77e6364`)
plus:

1. LIL's fork changes carried onto v0.2.2: the wheel CI (`ci/lil_wheels`,
   which `build.sh` builds the bundle with) and the pinned-host-memory
   fallback.
2. A compat shim. LIL's vLLM calls the 0.1.9 method
   `safe_open._determine_buffer_size` (renamed in v0.2) after narrowing the
   tensor lists. The shim maps it to `_finalize_buffer_size` and clears v0.2.2's
   `tensor_keep` mask, which no longer matches the narrowed lists.
3. The device memory budget check (new in v0.2) moves from `__init__` to open
   time when `load_now=False`, so it sees the narrowed buffer. Without it,
   GLM-5.3's MTP draft load fails: its shards also hold the 1.9 GB
   `embed_tokens` and `lm_head`, which vLLM drops, but checked before narrowing
   the 3.8 GB buffer exceeds the budget left after the main model.

**vLLM can't load the GLM-5.3 NVFP4-CSF container.** The container stores each
projection's slab `fixed` scale stream flat. `Nvfp4CsfMoEMethod.weight_loader`
passes it unchanged to FlashInfer, whose `CsfSource.validate` rejects it. The
bytes already match the expected shape, so the fix views the stream as
`(rows // 16, -1)`. LIL's #1039 fixes only the MXFP4 path.

The vLLM change is Python only, so `build.sh` builds the wheel over LIL's
native vLLM bundle (`VLLM_PRECOMPILED_BUNDLE`) instead of recompiling. vLLM's
`build_bundle.sh` refuses this unless the native sources, locks and build tools
are identical to the bundle's source commit.

## Build

On Babbler, once: `sudo apt install zstd jq unzip`. Then, from a clean checkout
of this branch:

```
bernd/build.sh                  # ~25 GB NGC pull on the first run
PUSH=1 bernd/build.sh           # build and push to ghcr.io (docker login first)
```

The work tree and caches go to `/opt/data/build/lil-image` (`WORK=`). Each run
ends with a `BUILT` record in its run directory: image ID, recipe commit, and
every component's source commit. `gh-shim/gh` answers the `gh api` calls in
LIL's tools with anonymous curl, so no GitHub login is needed.
`buildkitd.toml` sizes BuildKit's garbage collection for Babbler.

## Stock LMCache (cb2 recipe)

The assembly's LMCache is LIL's fork
(`0.5.3.dev457+lil`, forked from upstream 2026-08-30): frozen before upstream's
hybrid-GDN maturity train — the Qwen3.8-27B recipe landed in 0.5.5, Mamba
full-hit restoration and the MTP scratch-block fix in 0.5.6, engine-driven
multi-group transfers in 0.5.7. The upstream release wheels cannot simply be
pip-installed over it: they are built against *stable* torch 2.14.0 while this
foundation is the NGC alpha `2.14.0a0+nv26.08`, and their `cuda_ops` fails to
load (verified against v0.5.7.post1: undefined symbol
`_ZN3c104cuda19CUDAErrorLogCaptureC1Ev`). The fork's vLLM side anticipated a
swap, though: its `LMCacheMPConnector` resolver prefers
`LMCACHE_USE_UPSTREAM_MP=1` / falls back to a builtin upstream connector.

`bernd/stock-lmcache/` therefore rebuilds STOCK upstream LMCache — LIL's own
Dockerfile, builder image, toolchain pins and wheel normalization over an
unmodified upstream tag — and packages it in the assembly's bundle envelope.
The engine side then uses vLLM's builtin connector via `LMCACHE_USE_UPSTREAM_MP=1`
(or the ImportError fallback). LIL's runtime cache service (the `+lil`
engine-driven path glm53-flash uses) is NOT preserved by this: deployments
needing it stay on an image with the `+lil` bundle.

```
`bernd/stock-lmcache/build_bundle.sh /opt/data/build/lil-image/lmcache-stock
LMCACHE_BUNDLE=/opt/data/build/lil-image/lmcache-stock/bundle \
IMAGE=ghcr.io/bernd-sprenger/lil-vllm:kk-20261120-cb2 \
PUSH=1 bernd/build.sh
```

`LMCACHE_BUNDLE` drops the assembly's lmcache component from the download and
substitutes the bundle; the `BUILT` record and the image description carry the
stock provenance (tag, commit, `package_version` like
`0.5.7.post1+bernd.cu134.g<sha>`). The fork-only cuMem interposer is marked
absent through the whole chain (`prepare_runtime_auxiliary` →
`install_runtime_auxiliary` → `verify_qwen38_runtime`, all keyed on the
bundle's `source.upstream` marker): no fork files leak in, no fetch 404s.

# Babbler's logind has no linger, so a build driver run over ssh gets its
# user scope reaped minutes into the run. Run the driver in a detached
# container instead (daemon-owned, survives disconnects):
#
#   docker run -d --name cb2-builder \
#     -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v /opt/data/build:/build -v /home/bernd/.docker:/root/.docker -w /build \
#     docker:27 sh -c "apk add -q --no-cache bash git python3 jq curl unzip zstd coreutils tar \
#                      && bash /build/cb2-stageb.sh"
#
# coreutils/tar are required (busybox sha256sum lacks --quiet; busybox tar
# lacks --sort/--numeric-owner), and safe.directory=* is required because
# the recipe checkout is host-user-owned while the container runs as root.
# Watch it with: docker logs -f cb2-builder

Rollback everywhere is the pin: point `IMAGE` back at a `+lil` build.

## Combined launcher (cb3)

`build_combined.sh` builds the cb3 image: a cb2 base plus ONE thin layer
that bakes in `combined-launcher/lil-mp-launcher` as the entrypoint. It
runs the stock-LMCache MP server as a background child of the container
(L1 host RAM / L2 NVMe under `/l2`, sized by `LMCACHE_L1_GB` /
`LMCACHE_L2_GB`), waits for the server's health endpoint, then execs
`vllm serve` with the caller's args and — unless the args bring their own
`--kv-transfer-config` — a `LMCacheMPConnector` at `tcp://localhost:5555`.

This is LIL's own deployment shape, and it exists because the two-container
alternative is a dead end on this stack: `lmcache_driven` (CUDA IPC)
transfer needs shared `/dev/shm`, and even with `ipc: host` on both
containers the server keeps IPC handles into the engine's KV tensors —
after an engine-only restart the engine cannot re-allocate its VRAM (the
server pins ~53 GiB of the dead engine's memory) and crash-loops until the
server restarts too. One container makes the pair one lifecycle; the
supervisor script stops being per-deployment compose boilerplate and
becomes part of the image, so any engine (qwen38-27b today, glm53-flash
next) gets the tiered cache by just passing model args.

```
IMAGE=ghcr.io/bernd-sprenger/lil-vllm:kk-20261120-cb3 \
PUSH=1 bernd/build_combined.sh     # on Babbler; cb2 must be present
```

A deployment then only mounts `/l2`, sets the two tier knobs, sizes
`shm_size`, and passes `vllm serve` args as the compose `command:` —
no `entrypoint:` override, no inline supervisor script.

## Updating

- **New LIL release:** merge its recipe commit into this branch, and take the
  `community-assembly.json` tag and sha256 from its release
  (`karmic-kraken-<assembly sha>`). Rebase the fork branches onto the
  release's vLLM and InstantTensor commits, update the pins in `build.sh`,
  and bump the tag (`-cb2`, ...). Check that its vLLM still calls
  `_determine_buffer_size`.
- **Drop a fork** once LIL ships the fix: remove its build step and use LIL's
  bundle again. Drop this image entirely once LIL ships InstantTensor >= 0.2.1
  and a vLLM that loads the NVFP4-CSF container.
