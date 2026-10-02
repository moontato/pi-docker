# Orin normal-mode stock parity: passed

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

Host `sudo nvpmodel -q`: **MAXN (mode 0)**; `sudo jetson_clocks --show`: GPU min=max=1300500000 Hz, EMC min=max=3199000000 Hz, CPU min=max=2201600 kHz. `/mnt/ssd` had about 408 GiB free. At the initial blocked checkpoint, host memory was 61 GiB total, ~49 GiB used, **~12 GiB available** (15 GiB swap, not suitable GPU headroom). A pre-existing `llama-server` process had ~47 GiB RSS. The requested model is 17,559,178,144 bytes (**16.35 GiB**) *before* KV cache and benchmark buffers. That initial benchmark was deliberately not started; the operator subsequently cleared the large server target, allowing the completed run below.

## Completed normal-mode benchmark (2026-10-02)

After the operator cleared the large server target, the host had about 51 GiB available. Pi's usual local 47 GiB model would reload when asked to issue a tool call, so the benchmark used the same authenticated provider with a temporary `LFM2.5-8B` model entry in the private Docker profile. That entry was restored afterward; no provider credentials or server settings changed. The lightweight server remained loaded but was waiting for the tool result, not generating during the benchmark. The actual tool preflight had **46.59 GiB available**.

The benchmark ran from Pi's **actual model-issued `bash` tool** under normal `pi-docker --orin`, **not** from an unsandboxed host or outer validator. The model-issued command was `python3 /workspace/.worktrees/container-baseline/build-container/run-stock-parity.py`, timeout 900 seconds. This fixed, nonprivileged runner executes the following command, records JSON plus a Markdown table (`-o json -oe md`), and saves stdout/stderr and status; it refuses root, missing `no_new_privs`, profile mode, insufficient RAM or force-CUDA overrides. Use the same stock model as the 244.44 t/s handoff, prompt processing only (`p=4096`, `n=0`), batch 2048, microbatch 512, GPU layers 999, flash attention on, f16 KV, and **seven** repetitions:

```bash
cd /workspace/.worktrees/container-baseline && build-container/bin/llama-bench \
  -m /models/Qwen3.8-27B-UD-Q4_K_XL.gguf \
  -p 4096 -n 0 -b 2048 -ub 512 -ngl 999 -fa on -ctk f16 -ctv f16 -r 7
```

The model remains mounted read-only at `/models`. The trusted fixed runner refers to that exact model without asking for broad external-directory permissions. No permission policy, GPU-device list, syscall policy or bubblewrap flag was changed for this benchmark.

## Parity report

| Metric | Result |
| --- | ---: |
| Baseline | 244.44 t/s |
| Container pp4096, seven repetitions | **244.144465 t/s** |
| Absolute delta (container minus baseline) | **-0.295535 t/s** |
| Percentage delta | **-0.120903%** |
| Benchmark-reported throughput standard deviation | **0.008365 t/s** |
| Table output | 244.14 ± 0.01 t/s |
| Benchmark-reported duration standard deviation | 574,808 ns |
| Variance computed as reported throughput stddev squared | 0.000069973225 (t/s)^2 |

The benchmark reports **standard deviation**, not a variance column; the last row is explicitly derived, not an independently reported metric. All seven samples are in the raw JSON. Exit code was 0. UID/GID were 2002, effective/permitted/ambient capabilities were zero, `NoNewPrivs=1`, `Seccomp=2`, and `NSpid=2`, consistent with the existing inner bubblewrap boundary. MAXN and pinned CPU/GPU/EMC clocks were unchanged before and after the run. CMake git stamping remains `unknown` because of the host-absolute worktree pointer; source identity is independently verified on the host.

**Stock parity passes:** the difference is about 0.12%, comfortably inside the requested roughly 2% threshold. This does not prove statistical equality with an old baseline whose variance is unavailable. No kernel changes, extra profiling, power changes or optimization experiments were run. Stop at this report.

Evidence: [`results/20261002-stock-parity/`](results/20261002-stock-parity/) contains the exact benchmark command, raw JSON, stderr/table, exit code, sanitized model-issued tool events, sandbox status, pre/post memory, environment, postflight clocks/source/cache verification, summary and the archived fixed runner. The original results remain under the isolated worktree's `build-container/parity-results/20261002T141843Z`.
