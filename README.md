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

## Manage settings

Service URLs, API keys, resource limits, and optional host-network DNS live in `~/.config/pi-docker/env` (mode 600). Manage them without rerunning the installer:

```bash
pi-docker config list                 # show saved settings (API keys masked)
pi-docker config set ANTHROPIC_API_KEY sk-...
pi-docker config set PI_DOCKER_MEMORY 8g
pi-docker config get SEARXNG_URL
pi-docker config unset GROQ_API_KEY
```

Shell environment variables always win over saved values (`SEARXNG_URL`, `LLAMA_BASE_URL`, `LLAMA_API_KEY`, `PI_DOCKER_MEMORY`, `PI_DOCKER_CPUS`, `PI_DOCKER_DNS`, and the provider keys). The installer's URL flags and the values derived from `pi_configs/` write to the same file; the old `searxng-url`/`llama-url` files are migrated into it automatically.

### DNS and OpenAI subscription login

Host networking is enabled by default (`--tailnet`). Without an override it still uses Tailscale DNS (`100.100.100.100`). If private services resolve but OpenAI login reports `fetch failed` / `EAI_AGAIN`, check whether that resolver can resolve public domains. Configure a working resolver without rebuilding the image:

```bash
# Only if this host has a working systemd-resolved stub:
pi-docker config set PI_DOCKER_DNS 127.0.0.53
pi-docker
# Inside Pi: /login, then select ChatGPT/Codex.
```

`PI_DOCKER_DNS` accepts one canonical dotted-quad IPv4 address. The shell environment takes precedence over the saved value; otherwise the original Tailscale default remains. IPv6, hostnames, and multiple servers are not currently accepted. Choose a resolver that handles both public authentication endpoints and your private services: public DNS servers may not resolve tailnet names.

A loopback resolver such as `127.0.0.53` works only when the host actually runs it and the container uses **host networking**. `--no-tailnet` ignores this setting and retains Docker's bridge networking/DNS. Bridge mode may resolve public endpoints while losing private tailnet names, and OAuth browser callbacks may require pasting the redirect URL into Pi when prompted.

Restart the container after changing DNS. This does not modify host DNS, credentials, clipboard access, images, or sandbox policies. It changes which resolver's routing/privacy policy you use within the existing host-network boundary. Login still requires your approval; successful credentials persist in the private mounted Pi profile. Do not commit them or share authorization codes.

To restore the original resolver, run `pi-docker config unset PI_DOCKER_DNS` and restart.

### Copy text from the TUI

Hold **Shift before starting a mouse drag** to use your terminal's native selection, then use its Copy command (often Ctrl+Shift+C on Linux/Windows or Cmd+C on macOS). Pressing Ctrl+Shift+C while Pi owns the highlight may not copy anything. Most terminals support this mouse override, though the exact modifier can vary.

Pi's own copy notification can mean it emitted an OSC 52 clipboard request, not that the terminal accepted it. Terminal/SSH/multiplexer support determines whether that request reaches your clipboard. Native terminal selection avoids needing desktop clipboard sockets or broader container permissions.

## Check health

`pi-docker doctor` checks the Docker daemon, the managed image and its sandbox dependencies, the installed Pi packages, saved settings, URL reachability, the selected host-network DNS server's TCP port, and PATH, and exits nonzero when anything fails.

The local regression checks use fake Docker and isolated profiles; they do not require a daemon or change your installation:

```bash
bash tests/launcher.sh
bash tests/installer.sh
```

## Later

Run `./install-pi-docker.sh` again to apply installer changes; it re-reads the service URLs from `pi_configs/` and skips an image it already manages. Use `--rebuild` only when you intentionally want a fresh image build. `pi-docker` shares the host network namespace, including host-local services, and uses `PI_DOCKER_DNS` when configured, otherwise Tailscale DNS; pass `--no-tailnet` to use Docker's normal network instead. The permission extension's nested Bubblewrap sandbox may be blocked by Docker even when its dependencies are installed; the outer Docker boundary still applies.
