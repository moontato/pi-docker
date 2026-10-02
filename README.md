# Pi in Docker

Run Pi against one project at a time, with a separate persistent Pi profile and access to your Tailscale services.

## Set up once

Requires Linux, a working Docker installation, jq, and Tailscale on the host.

First fill in your tailnet addresses in `pi_configs/` (see the note below), then:

```bash
chmod +x install-pi-docker.sh
./install-pi-docker.sh
```

The installer builds the image, installs the Pi packages, and reads the SearXNG and llama URLs from `pi_configs/web-search.json` and `pi_configs/models.json`, saving them between runs. Pass `--searxng-url URL` or `--llama-url URL` to override the config files.

**Note:** the URLs in `pi_configs/` are placeholders — replace them with your tailnet services' actual addresses before running the installer: the `llama-server` provider block in `models.json` (`baseUrl` and the `your-model-id` template model; duplicate the block for each additional llama server), `defaultProvider`, `defaultModel` and `modelOverrides` in `settings.json`, and `searxngBaseUrl` plus the `100.100.0.1/32` SSRF range in `web-search.json`.

Sync the provided configuration into the Docker profile:

```bash
cd pi_configs
./setup-pi-config.sh --target docker --install-packages
cd ..
```

The deployer shows changes and asks before copying. `--target host` copies to your regular host Pi profile; `--target both` copies to both. Its default is `host`. Use `--check` for a non-interactive drift report (exit 1 if drift), and `--restore` to roll the listed destinations back from their `.bak` backups.

## Open a project

```bash
cd /path/to/your/project
pi-docker
```

The current directory is writable inside Pi as `/workspace`, or pass `pi-docker --project DIR` to bind another directory. Use `/model` to choose a model and `/sandbox` to check permission-mode status. `pi-docker --help` lists all options. Run the config deployer again only when you change files in `pi_configs/`.

## Jetson AGX Orin CUDA development (opt-in)

This mode targets an **aarch64 Jetson AGX Orin (SM 8.7)** running JetPack 7.2.1 / L4T R39.2.1 with the **host's CUDA 13.2** toolkit at `/usr/local/cuda-13.2`. It does not change the default image or `pi-docker` behavior on other hosts. Docker must have the NVIDIA Container Runtime registered (`docker info` should list `nvidia`), and your user must be able to access Docker. The host CUDA toolkit is bind-mounted read-only; no CUDA toolkit is installed in the image. Host Nsight Compute (`/opt/nvidia/nsight-compute`) and Nsight Systems (`/opt/nvidia/nsight-systems`) are mounted read-only **when present**; neither is required for ordinary CUDA development. The opt-in image uses Ubuntu 24.04 to match host CUDA binary/glibc requirements. The host NVIDIA runtime supplies GPU devices and driver libraries. NVIDIA runtime configuration must support this image on your JetPack installation.

From this repository, install/update the regular Pi bundle and build the *separate* Orin image:

```bash
./install-pi-docker.sh --install-orin
```

If the installer detects custom modifications to the installed launcher, review them first and use `--force` only if you intend to replace them. This step requires Docker access and network access for the initial image build.

Launch development Pi, from any directory (the development tree is always `/workspace`):

```bash
pi-docker --orin
```

Launch Pi with the **additional `SYS_ADMIN` capability** for Nsight Compute GPU performance counters:

```bash
pi-docker --orin-profile
```

Validate either mode without starting Pi (compiles and checks the result of a tiny SM87 CUDA kernel with the host's `nvcc`; profiling validation additionally collects a hardware counter):

```bash
pi-docker --orin --orin-validate
pi-docker --orin-profile --orin-validate
```

Orin modes use a dedicated Docker seccomp policy and AppArmor profile for nested bubblewrap, plus an Orin-image-only wrapper that binds specific NVIDIA GPU nodes into bubblewrap's synthetic `/dev`. See [`orin/security/README.md`](orin/security/README.md) for the exact syscall/mount scope, Engine 29.8.0 version pin, and host-policy rollback. **These are broader mount permissions inside the Orin containers**, not changes to ordinary Docker sessions. `--install-orin` loads the dedicated named AppArmor profile via `sudo`, without editing Docker's defaults. On this host a model-issued `bash` call using the PATH command `pi-docker-orin-validate` passes inside bubblewrap in normal mode (the literal absolute path is rejected as out-of-project by the permission extension).

Both modes mount `/mnt/ssd/llama-orin-test` **read/write** at `/workspace`, `/mnt/ssd/llamacpp_models` **read-only** at `/models`, and the host CUDA toolkit **read-only** at `/usr/local/cuda-13.2`. Optional profiler directories are mounted read-only if available; `--orin-profile` warns if Nsight Compute is missing, but CUDA development can still start. Profiling validation requires working `ncu` and an actual counter result. They share the same Pi profile and network settings as the default launcher. GPU device-owner groups are added to the container user when needed. Neither mode uses `--privileged`; only profiling mode adds `CAP_SYS_ADMIN`. **Never build in `/mnt/ssd/llama.cpp`** (the production installation is not mounted by this mode). For example, inside Pi's shell in the development tree:

```bash
cmake -S /workspace -B /workspace/build-orin -G Ninja -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87 -DGGML_CUDA_FA_QUANTS=f16-f16 -DCMAKE_BUILD_TYPE=Release
cmake --build /workspace/build-orin -j 2
```

The image already sets `CUDAToolkit_ROOT=/usr/local/cuda-13.2`; check the CMake cache for that toolkit's `nvcc`. The permission extension may reject the literal absolute toolkit path passed as a command-line argument, so use the image environment instead.

The validator reports device count, name, SM version and memory, verifies a compiled CUDA kernel returns the correct result, checks `nvcc`, optionally checks `ncu` and `nsys` versions, and checks mount flags **and** file behavior (including reading `/models/Qwen3.8-27B-UD-Q4_K_XL.gguf`). In profiling mode it runs that probe under `ncu` and requires a hardware metric. Probe binaries live in `/tmp`; unique workspace test files are removed, and no existing models are changed. For a model-issued **normal-mode** bash call, ask Pi to run `pi-docker-orin-validate` by PATH (the literal `/usr/local/bin/...` command is blocked by the out-of-project permission rule). That call has passed inside bubblewrap on this host and verifies the GPU, CUDA paths, and mounts. **Do not silently disable bubblewrap** if it fails; diagnose its boundary separately. On this Jetson, hardware counters remain unavailable to the non-root container user even when `SYS_ADMIN` is ambient; the **outer** `--orin-profile --orin-validate` path elevates only `ncu` with `sudo -n`. Counter profiling is a **separate privileged operator workflow outside Pi's inner sandbox**, not a Pi bash-tool workflow. See [`orin/manual-profiling.md`](orin/manual-profiling.md) for exact commands to review before any new privileged workload. The Pi session remains the host UID; normal mode has no `SYS_ADMIN`. **Profiling from a model-issued bash call inside bubblewrap is NOT accepted:** bubblewrap sets `no_new_privs`, so `sudo ncu` cannot elevate; attaching a root Nsight collector to a sandboxed non-root target also fails the host driver's target-process counter-permission check. Do not treat outer validation as proof that Pi's tool sandbox can profile. No privileged helper has been installed. Under the current host driver policy, the non-root target is denied counters even when a root collector attaches; this investigation is closed without changing permissions or target privilege. `SYS_ADMIN` is powerful: use profiling mode only when necessary. The NVIDIA Container Runtime must inject compatible Jetson devices and driver libraries; if your runtime requires a JetPack-specific image or different mapping, hardware validation must identify that before use. CUDA 13.2 is never substituted with a different release.

For a stock-performance acceptance test, first prepare the **host** (`sudo nvpmodel -m 0; sudo jetson_clocks`; use host `tegrastats` as needed). Do not grant the container power-control privileges. The development tree currently contains unrelated local changes; **do not reset, clean, stash or check it out**. Create a separate worktree beneath the mounted development area at a new unused path, then build it *inside* `pi-docker --orin`:

```bash
# On the host, only after ensuring this destination does not already exist:
mkdir -p /mnt/ssd/llama-orin-test/.worktrees
git -C /mnt/ssd/llama-orin-test worktree add --detach /mnt/ssd/llama-orin-test/.worktrees/container-baseline def4d406ae2c2f39573120d68730fbb7760b24bf
# In the Pi container (agent shell/tool):
/usr/local/cuda-13.2/bin/nvcc --version  # must report V13.2.86
cd /workspace/.worktrees/container-baseline
cmake -S . -B build-container -G Ninja -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87 -DGGML_CUDA_FA_QUANTS=f16-f16 -DCMAKE_BUILD_TYPE=Release
cmake --build build-container --target llama-bench -j 2
/workspace/.worktrees/container-baseline/build-container/bin/llama-bench -m /models/Qwen3.8-27B-UD-Q4_K_XL.gguf -p 4096 -n 0 -b 2048 -ub 512 -ngl 999 -fa on -ctk f16 -ctv f16 -r 7
```

Run the **same model and benchmark options** as the 244.44 t/s bare-metal baseline; if its model differs, substitute that exact model in both tests. Record container throughput, absolute difference (`container − 244.44` t/s), and relative difference (`100 × difference / 244.44` %). Aim for roughly 1–2% parity within run variance. If it differs materially, inspect power mode, clocks, build flags, CPU/memory limits, library resolution, and GPU visibility before CUDA tuning. **Current acceptance:** normal Pi-tool CUDA and the isolated stock build pass; outer counter validation passes, inner sandboxed profiling does not. The seven-repetition benchmark has **not** run: available RAM is below the 16.35 GiB model file alone, with an active ~47 GiB RSS `llama-server`. Do not stop that service or start the GPU benchmark until the operator frees sufficient memory. See [`orin/stock-parity.md`](orin/stock-parity.md) for exact stock-build commands, status, and planned result reporting.

## Manage settings

Service URLs, API keys, and resource limits live in `~/.config/pi-docker/env` (mode 600). Manage them without rerunning the installer:

```bash
pi-docker config list                 # show saved settings (API keys masked)
pi-docker config set ANTHROPIC_API_KEY sk-...
pi-docker config set PI_DOCKER_MEMORY 8g
pi-docker config get SEARXNG_URL
pi-docker config unset GROQ_API_KEY
```

Shell environment variables always win over saved values (`SEARXNG_URL`, `LLAMA_BASE_URL`, `LLAMA_API_KEY`, `PI_DOCKER_MEMORY`, `PI_DOCKER_CPUS`, and the provider keys). The installer's URL flags and the values derived from `pi_configs/` write to the same file; the old `searxng-url`/`llama-url` files are migrated into it automatically.

## Check health

`pi-docker doctor` checks the Docker daemon, the managed image and its sandbox dependencies, the installed Pi packages, saved settings, URL reachability, Tailscale DNS, and PATH, and exits nonzero when anything fails.

## Later

Run `./install-pi-docker.sh` again to apply installer changes; it re-reads the service URLs from `pi_configs/` and skips an image it already manages. Use `--rebuild` only when you intentionally want a fresh image build. `pi-docker` shares the host network namespace, including host-local services, and uses Tailscale DNS by default; pass `--no-tailnet` to use Docker's normal network instead. The permission extension's nested Bubblewrap sandbox may be blocked by Docker even when its dependencies are installed; the outer Docker boundary still applies.
