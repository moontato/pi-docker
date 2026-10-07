# Pi configuration

Keep the JSON and extension files in this folder as the canonical copies. The deployer previews changes, backs up changed destinations by default, and leaves identical files untouched.

```bash
./setup-pi-config.sh --target host --install-packages
```

That command syncs this folder into the shared `~/.pi` profile and installs missing `pi-permission-modes` and `pi-ext-int-search` packages. The `install-pi-docker.sh` installer also installs those packages, so `--install-packages` is most useful when restoring the configuration on another computer. No Docker image rebuild is needed for configuration changes. On macOS, `--install-packages` checks the container-local store at `~/.local/share/pi-docker/npm` (the directory `pi-docker` overlays onto the shared profile), not the host's `~/.pi/agent/npm`.

Run without flags (default `--target host`) to sync the shared profile; `--target docker` and `--target both` are aliases, since pi-docker now shares `~/.pi` by default. Add `--yes` to apply the previewed changes and make `.bak` backups without prompting. `--check` reports drift without applying anything (exit 1 if drift), and `--restore` rolls the selected target back from its `.bak` backups.

| Canonical file | Shared profile destination |
| --- | --- |
| `models.json` | `~/.pi/agent/models.json` |
| `settings.json` | `~/.pi/agent/settings.json` |
| `permission-mode.json` | `~/.pi/agent/permission-mode/permission-mode.json` |
| `friendly-model-footer.ts` | `~/.pi/agent/extensions/friendly-model-footer.ts` |
| `web-search.json` | `~/.pi/web-search.json` |

Both host Pi and pi-docker read these same files. This folder's `settings.json` already lists both packages, and `web-search.json` selects your SearXNG endpoint for `pi-ext-int-search`. If you previously installed a separate SearXNG search extension in pi-docker, syncing `settings.json` replaces that declaration; check `pi-docker list` if you see duplicate `web_search` tools.

`pi-permission-modes` is an additional prompt and policy layer inside Pi. Its nested Bubblewrap sandbox may not initialize under Docker's default seccomp/AppArmor settings. Use `/sandbox` in Pi to check. The outer Docker container remains the filesystem boundary; the `host-nosandbox` mode in this folder skips the nested sandbox while keeping the mode's permission prompts. `pi-docker` shares the host network namespace by default to reach your tailnet services.
