# Orin hardware-counter workflow (operator review only)

**Normal mode is accepted:** a model-issued `bash` call to `pi-docker-orin-validate` runs CUDA inside bubblewrap as the non-root Pi user with `no_new_privs`; `/workspace` is writable and `/models` is read-only. This is the supported Pi CUDA workflow. No counter-collection helper exists in Pi's sandbox.

**Counter profiling is separate:** the host's current NVIDIA driver denies `sm__cycles_active.avg` to a non-root CUDA *target*. Nsight Compute's root `--mode attach` collector connected to a non-root target (both in and out of bubblewrap) but counter collection failed with `The user does not have permission to access NVIDIA GPU Performance Counters on the target vGPU device 0.` `sudo` cannot elevate from bubblewrap with `no_new_privs`. This investigation is closed. Do not change driver counter permissions, elevate Pi, disable bubblewrap, or try to treat an outer validator result as a sandboxed profiling acceptance result.

## Already supported outer validation

From an **operator's host shell**, after confirming the Jetson has available memory and no competing GPU workload:

```bash
pi-docker --orin-profile --orin-validate
```

This opt-in container starts Pi's entrypoint validator **outside the inner bubblewrap**. The container user compiles and runs a small CUDA probe; the validator executes `sudo -n /usr/local/cuda-13.2/bin/ncu --metrics sm__cycles_active.avg --csv "$scratch/probe"` on a separate probe target. On this host it prints `Nsight Compute counter collection OK: sm__cycles_active.avg`. The profiler launches the target under its elevated credentials; this is *not* a non-root Pi bash-tool profile and is *not* proof of sandboxed profiling. Only this pre-existing validation has been executed.

## Proposed manual workload (DO NOT EXECUTE without separate operator review)

If an operator later approves a **privileged target outside Pi's inner sandbox**, this is an exact illustrative host command to collect the same metric for one stock `llama-bench` prompt run. It is **not** a Pi tool call, not accepted under Pi's sandbox boundary, and has **not been executed**. It runs both Nsight Compute and its CUDA target as root on the host; check the intended binary/model and memory headroom first. Keep any report in a private operator-owned path; the `--csv` form streams results to stdout without opening an unrestricted output directory in the Pi session.

```bash
# Operator only. No concurrent production workload; review this privileged invocation first.
sudo -n /usr/bin/env LD_LIBRARY_PATH=/mnt/ssd/llama-orin-test/.worktrees/container-baseline/build-container/bin:/usr/local/cuda-13.2/lib64 \
  /usr/local/cuda-13.2/bin/ncu --metrics sm__cycles_active.avg --csv --target-processes application-only \
  /mnt/ssd/llama-orin-test/.worktrees/container-baseline/build-container/bin/llama-bench \
  -m /mnt/ssd/llamacpp_models/Qwen3.8-27B-UD-Q4_K_XL.gguf \
  -p 4096 -n 0 -b 2048 -ub 512 -ngl 999 -fa on -ctk f16 -ctv f16 -r 1
```

The command supplies `LD_LIBRARY_PATH` for the container-built shared libraries; the container build and host libraries must still be checked for compatibility before an operator attempts this. A safer future container-specific procedure must likewise launch a privileged **target outside Pi's bubblewrap**, with explicit review; a privileged collector attached to a non-root sandboxed target will not solve this host-driver restriction. Neither manual procedure is needed for the normal-mode stock parity benchmark.
