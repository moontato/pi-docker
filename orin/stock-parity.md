# Orin normal-mode stock parity checkpoint (pending benchmark)

Source: isolated, detached worktree at `/mnt/ssd/llama-orin-test/.worktrees/container-baseline`, `def4d406ae2c2f39573120d68730fbb7760b24bf`. It is under the `/workspace` bind mount in `pi-docker --orin` and remains clean. The development tree at `/mnt/ssd/llama-orin-test` retains its pre-existing modified CUDA header, `results*` directories, and sweep scripts; `/mnt/ssd/llama.cpp` is untouched. The build directory is **only** `/workspace/.worktrees/container-baseline/build-container` (ignored by the baseline source). The installed Pi model called the real `bash` tool under bubblewrap for the build; no root Pi or sandbox bypass was used.

## Reproducible stock build

Original flags: `GGML_CUDA=ON`, `CMAKE_CUDA_ARCHITECTURES=87`, `GGML_CUDA_FA_QUANTS=f16-f16`, `CMAKE_BUILD_TYPE=Release`, CUDA toolkit 13.2.86. In the Orin image `CUDAToolkit_ROOT=/usr/local/cuda-13.2` is already set by `Dockerfile.orin`. The Pi permission extension rejects including the literal absolute toolkit root as a `-D` argument to the tool; the build used the image environment variable instead. The resulting CMake cache verifies `CMAKE_CUDA_COMPILER=/usr/local/cuda-13.2/bin/nvcc`, `GGML_CUDA_FA_QUANTS=f16-f16`, architecture 87 and Release.

Commands executed in normal mode using model-issued `bash` calls:

```bash
cd /workspace/.worktrees/container-baseline && cmake -S . -B build-container -G Ninja -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87 -DGGML_CUDA_FA_QUANTS=f16-f16 -DCMAKE_BUILD_TYPE=Release
cd /workspace/.worktrees/container-baseline && cmake --build build-container --target llama-bench -j2
```

The first 1800-second build invocation timed out partway through compilation; rerunning the exact incremental command completed and linked `build-container/bin/llama-bench` (exit success). A CUDA object build at `-j2` was selected to respect limited free memory, not to change compilation flags. Inside Docker, git version stamping reports `ggml commit: unknown`: the worktree `.git` pointer contains a host-absolute path outside Docker's `/workspace` mount; the host independently verifies `HEAD=def4d406ae2c2f39573120d68730fbb7760b24bf` and a clean source. No source was patched or copied into production to mask this metadata issue.

## Power and resource preflight (2026-10-02)

Host `sudo nvpmodel -q`: **MAXN (mode 0)**; `sudo jetson_clocks --show`: GPU min=max=1300500000 Hz, EMC min=max=3199000000 Hz, CPU min=max=2201600 kHz. `/mnt/ssd` had about 408 GiB free. Host memory was 61 GiB total, ~49 GiB used, **~12 GiB available** (15 GiB swap, not suitable GPU headroom). A pre-existing `llama-server` process had ~47 GiB RSS. The requested model is 17,559,178,144 bytes (**16.35 GiB**) *before* KV cache and benchmark buffers. Do not stop the service or start a seven-repetition GPU test at this headroom; an operator must free sufficient physical memory and confirm no concurrent GPU workload first.

## Pending normal-mode benchmark (NOT executed)

Run from Pi's **actual model-issued `bash` tool** under `pi-docker --orin`, **not** from an unsandboxed host or outer validator, after the memory preflight passes. Use the same stock model as the 244.44 t/s handoff, prompt processing only (`p=4096`, `n=0`), batch 2048, microbatch 512, GPU layers 999, flash attention on, f16 KV, and **seven** repetitions:

```bash
cd /workspace/.worktrees/container-baseline && build-container/bin/llama-bench \
  -m /models/Qwen3.8-27B-UD-Q4_K_XL.gguf \
  -p 4096 -n 0 -b 2048 -ub 512 -ngl 999 -fa on -ctk f16 -ctv f16 -r 7
```

The model is mounted read-only at `/models`. Because the permission extension may reject a literal out-of-project `/models` argument despite the read-only bind, first verify tool access without running a workload. If it blocks, arrange a **narrowly reviewed invocation** inside bubblewrap; never turn off bubblewrap or weaken the model mount. Capture tool-call arguments, command output (including mean ± reported variance), GPU/power/memory state, and error code. Calculate `absolute delta = measured t/s − 244.44 t/s` and `percentage delta = absolute delta / 244.44 × 100`; investigate >~2% differences (model identity, clock/power mode, workload competition, build flags, resolved libraries, memory pressure) before touching CUDA kernels.

**Current result:** baseline `244.44 t/s`; container measured `N/A`; absolute and percentage deltas `N/A`; reported benchmark variance `N/A` (benchmark deliberately not run due to memory pressure). No parity or regression claim is justified yet.
