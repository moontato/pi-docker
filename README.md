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

This mode targets an **aarch64 Jetson AGX Orin (SM 8.7)** running JetPack 7.2.1 / L4T R39.2.1 with the **host's CUDA 13.2** toolkit at `/usr/local/cuda-13.2`. It does not change the default image or `pi-docker` behavior on other hosts. Docker must have the NVIDIA Container Runtime registered (`docker info` should list `nvidia`), and your user must be able to access Docker. Ensure `/opt/nvidia/nsight-compute` exists on the host. The host CUDA toolkit and Nsight Compute are bind-mounted read-only; no CUDA toolkit is installed in the image. The opt-in image uses Ubuntu 24.04 to match host CUDA binary/glibc requirements. The host NVIDIA runtime supplies GPU devices and driver libraries. NVIDIA runtime configuration must support this image on your JetPack installation.

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

Validate either mode without starting Pi (runs a CUDA kernel-independent GPU properties probe compiled by the host's `nvcc`):

```bash
pi-docker --orin --orin-validate
pi-docker --orin-profile --orin-validate
```

Both modes mount `/mnt/ssd/llama-orin-test` **read/write** at `/workspace`, `/mnt/ssd/llamacpp_models` **read-only** at `/models`, and the host CUDA toolkit at `/usr/local/cuda-13.2` and Nsight Compute at `/opt/nvidia/nsight-compute` (both read-only). They share the same Pi profile and network settings as the default launcher. GPU device-owner groups are added to the container user when needed. Neither mode uses `--privileged`; only profiling mode adds `CAP_SYS_ADMIN`. **Never build in `/mnt/ssd/llama.cpp`** (the production installation is not mounted by this mode). For example, inside Pi's shell in the development tree:

```bash
cmake -S /workspace -B /workspace/build-orin -G Ninja -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87 -DCUDAToolkit_ROOT=/usr/local/cuda-13.2
cmake --build /workspace/build-orin -j 8
```

The validation checks GPU visibility, reports and requires compute capability 8.7, runs `/usr/local/cuda-13.2/bin/nvcc --version` and `ncu --version`, checks the source tree and models mount, and verifies the model bind is read-only. It writes temporary probe files only under the container's temporary directory. `ncu --version` does **not** test performance counters: run an actual `ncu` profiling command in `--orin-profile` mode to test counters. Driver-level profiling restrictions or other host configuration can still block counters even with `SYS_ADMIN`. `SYS_ADMIN` is powerful: use profiling mode only when necessary. The NVIDIA Container Runtime must inject compatible Jetson device and driver libraries; if your runtime requires a JetPack-specific image or a different host library mapping, validation will fail and the runtime setup needs adjustment. CUDA 13.2 itself is never substituted with a different release.

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
