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

The deployer shows changes and asks before copying. `--target host` copies to your regular host Pi profile; `--target both` copies to both. Its default is `host`.

## Open a project

```bash
cd /path/to/your/project
pi-docker
```

The current directory is writable inside Pi as `/workspace`. Use `/model` to choose a model and `/sandbox` to check permission-mode status. Run the config deployer again only when you change files in `pi_configs/`.

## Later

Run `./install-pi-docker.sh` again to apply installer changes; it re-reads the service URLs from `pi_configs/` and skips an image it already manages. Use `--rebuild` only when you intentionally want a fresh image build. `pi-docker` shares the host network namespace, including host-local services, and uses Tailscale DNS by default; pass `--no-tailnet` to use Docker's normal network instead. The permission extension's nested Bubblewrap sandbox may be blocked by Docker even when its dependencies are installed; the outer Docker boundary still applies.
