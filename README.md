# Pi in Docker

Run Pi against one project at a time, sharing your `~/.pi` profile with host Pi (logins, settings, sessions, packages), with access to your Tailscale services. Pass `pi-docker --isolated` to opt back into the old separate profile.

## Set up once

Requires Linux, or macOS with Docker Desktop, plus a working Docker installation, jq, and Tailscale on the host.

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

## macOS

macOS is supported through Docker Desktop; the container image stays Linux.

- **Prerequisites:** Docker Desktop (started), jq, and Tailscale on the Mac. Docker Desktop 4.34+ is only needed for `--tailnet`, and requires **Settings → Resources → Network → Enable host networking**.
- **Networking:** the macOS default is Docker Desktop's normal network and DNS (equivalent to `--no-tailnet` on Linux). Pass `--tailnet` to opt into Docker Desktop host networking. That feature is TCP/UDP-level access from the Desktop VM, not the macOS network namespace: macOS loopback-resolver tricks (for example `PI_DOCKER_DNS=127.0.0.53` with systemd-resolved) do not apply. `PI_DOCKER_DNS` is honored only in `--tailnet` mode and ignored otherwise, same as on Linux.
- **Tailscale:** works through Docker Desktop's normal networking (VPN passthrough) while the host Tailscale is running. Tailnet IP addresses resolve directly; if MagicDNS names fail, check `pi-docker doctor` and Docker Desktop's Network/VPN settings.
- **Local services:** services running natively on the Mac are reachable from the container as `host.docker.internal` (for example `https://host.docker.internal:8889` for a locally run SearXNG).
- **npm packages:** on macOS, `pi-docker` overlays `~/.pi/agent/npm` with a container-local store at `~/.local/share/pi-docker/npm`. Package installs by pi-docker never touch your native macOS Pi installations, and vice versa. Credentials, settings, sessions, and user extensions remain shared.
- **PATH (zsh):** `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`

## Open a project

```bash
cd /path/to/your/project
pi-docker
```

The current directory is writable inside Pi as `/workspace`, or pass `pi-docker --project DIR` to bind another directory. Use `/model` to choose a model and `/sandbox` to check permission-mode status. `pi-docker --help` lists all options. Run the config deployer again only when you change files in `pi_configs/`.

By default pi-docker mounts your host `~/.pi` into the container, so host Pi and pi-docker are one profile: `/login` on either side (for example OpenAI Codex) updates the same `auth.json`, and settings, models, sessions, extensions, and packages are shared. The container's `HOME` itself stays private. Pass `--isolated` to use the old separate profile at `~/.local/share/pi-docker/agent` instead.

The shared profile is writable trusted state: container changes to credentials, packages, or extensions also affect host Pi. Use `--isolated` if you do not want that connection. The container also has writable access to the selected project and can reach host-local services in host-network mode; Docker is not a guarantee against changes to those explicitly shared resources.

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

Host networking is the default on Linux (`--tailnet`); on macOS the default is Docker Desktop's normal networking and `--tailnet` selects Desktop host networking. On Linux, without an override it uses the host's `/etc/resolv.conf` read-only, preserving the host's public and Tailscale split DNS. If OpenAI login reports `fetch failed` / `EAI_AGAIN`, run `pi-docker doctor`. You can override the resolver without rebuilding the image:

```bash
# Linux only; requires a working systemd-resolved stub:
pi-docker config set PI_DOCKER_DNS 127.0.0.53
pi-docker
# Inside Pi: /login, then select ChatGPT/Codex.
```

`PI_DOCKER_DNS` accepts one canonical dotted-quad IPv4 address. The shell environment takes precedence over the saved value; otherwise the host resolver remains. IPv6, hostnames, and multiple servers are not currently accepted. Choose a resolver that handles both public authentication endpoints and your private services: public DNS servers may not resolve tailnet names.

A loopback resolver such as `127.0.0.53` works only when the host actually runs it and the container uses **host networking**. `--no-tailnet` ignores this setting and retains Docker's bridge networking/DNS. Bridge mode may resolve public endpoints while losing private tailnet names, and OAuth browser callbacks may require pasting the redirect URL into Pi when prompted.

Restart the container after changing DNS. This does not modify host DNS, credentials, clipboard access, images, or sandbox policies. It changes which resolver's routing/privacy policy you use within the existing host-network boundary. Login still requires your approval; successful credentials persist in the selected mounted Pi profile (shared with host Pi by default). Do not commit them or share authorization codes.

To restore the host resolver, run `pi-docker config unset PI_DOCKER_DNS`, unset any shell `PI_DOCKER_DNS` override, and restart.

### Copy text from the TUI

Hold **Shift before starting a mouse drag** to use your terminal's native selection, then use its Copy command (often Ctrl+Shift+C on Linux/Windows or Cmd+C on macOS). Pressing Ctrl+Shift+C while Pi owns the highlight may not copy anything. Most terminals support this mouse override, though the exact modifier can vary.

Pi's own copy notification can mean it emitted an OSC 52 clipboard request, not that the terminal accepted it. Terminal/SSH/multiplexer support determines whether that request reaches your clipboard. Native terminal selection avoids needing desktop clipboard sockets or broader container permissions.

## Check health

`pi-docker doctor` checks Docker, image dependencies (including `fd`), packages, the selected profile's accessibility as your UID, saved settings, and DNS/HTTPS to GitHub, OpenAI, and the configured service URLs **from the container**, plus PATH. It also reports container Pi's version and notes mismatches with host Pi. It exits nonzero when a check fails, masks saved API keys, and does not display `auth.json` contents. Use `pi-docker doctor --no-tailnet` or `pi-docker doctor --isolated` to check those modes.

### Startup/authentication troubleshooting

After updating this repository, run `./install-pi-docker.sh` again. The v7 launcher and v4 image upgrade automatically from the unmodified managed versions; no `--force` or manual profile copying is needed. The image includes `fd` so startup does not download it from GitHub.

The entrypoint restores `HOME=/home/pi` **after** `gosu` switches users. Otherwise UID 1000 resolves to the Node image's `/home/node`, and Pi misses the shared profile. Default networking uses the host resolver rather than forcing `100.100.100.100`, preserving both public DNS and Tailscale split DNS.

If `No models available` remains, confirm you have logged in with host Pi (`pi`, then `/login`). Logins that exist only in the old isolated profile are not migrated automatically; use `--isolated` to keep using them. For `EAI_AGAIN`/`fetch failed`, run `pi-docker doctor` and compare with `pi-docker doctor --no-tailnet`.

## Later

Run `./install-pi-docker.sh` again to apply installer changes; it re-reads the service URLs from `pi_configs/` and skips an image it already manages. Sharing the profile does **not** synchronize Pi binaries: even an automatic image upgrade can reuse the cached npm install. Use `./install-pi-docker.sh --rebuild` to install the latest published Pi in the container, then compare `pi --version` and `pi-docker --version`. This does not pin the container to the host's exact version.

On Linux, `pi-docker` shares the host network namespace, including host-local services, and uses `PI_DOCKER_DNS` when configured, otherwise the host's `/etc/resolv.conf` mounted read-only; pass `--no-tailnet` to use Docker's normal network and DNS instead. On macOS it uses Docker Desktop's normal networking by default (see the macOS section), and `--tailnet` selects Desktop host networking without mounting any macOS resolver file. The permission extension's nested Bubblewrap sandbox may be blocked by Docker even when its dependencies are installed; the outer Docker boundary still applies.

## Tests

Run offline regression tests (no Docker daemon or network required; they pass on Linux and macOS, including stock macOS Bash 3.2):

```bash
python3 -B -m unittest discover -s tests -v
bash tests/launcher.sh
bash tests/installer.sh
```
