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
