# Pi in Docker

Run Pi against one project at a time, sharing your `~/.pi` profile with host Pi (logins, settings, sessions, packages), with access to your Tailscale services. Pass `pi-docker --isolated` to opt back into the old separate profile.

## Set up once

Requires Linux, a working Docker installation, jq, and Tailscale on the host.

First fill in your tailnet addresses in `pi_configs/` (see the note below), then:

```bash
chmod +x install-pi-docker.sh
./install-pi-docker.sh
```

The installer builds the image, installs the Pi packages, and reads the SearXNG and llama URLs from `pi_configs/web-search.json` and `pi_configs/models.json`, saving them between runs. Pass `--searxng-url URL` or `--llama-url URL` to override the config files.

**Note:** the URLs in `pi_configs/` are placeholders — replace them with your tailnet services' actual addresses before running the installer: the `llama-server` provider block in `models.json` (`baseUrl` and the `your-model-id` template model; duplicate the block for each additional llama server), `defaultProvider`, `defaultModel` and `modelOverrides` in `settings.json`, and `searxngBaseUrl` plus the `100.100.0.1/32` SSRF range in `web-search.json`.

Sync the provided configuration into the shared profile:

```bash
cd pi_configs
./setup-pi-config.sh --target host --install-packages
cd ..
```

The deployer shows changes and asks before copying. Its default target is `host` (your `~/.pi` profile); `--target docker` and `--target both` are aliases, since pi-docker shares `~/.pi` by default. Use `--check` for a non-interactive drift report (exit 1 if drift), and `--restore` to roll the listed destinations back from their `.bak` backups.

## Open a project

```bash
cd /path/to/your/project
pi-docker
```

The current directory is writable inside Pi as `/workspace`, or pass `pi-docker --project DIR` to bind another directory. Use `/model` to choose a model and `/sandbox` to check permission-mode status. `pi-docker --help` lists all options. Run the config deployer again only when you change files in `pi_configs/`.

By default pi-docker mounts your host `~/.pi` into the container, so host Pi and pi-docker are one profile: `/login` on either side (for example OpenAI Codex) updates the same `auth.json`, and settings, models, sessions, extensions, and packages are shared. The container's `HOME` itself stays private. Pass `--isolated` to use the old separate profile at `~/.local/share/pi-docker/agent` instead.

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
