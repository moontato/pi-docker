# Local compaction-thinking extension for pi-docker

This bundle replaces the old `npm:pi-compaction-model` installer integration with a local extension that uses the active model for compaction and applies a separate thinking level. Based on JMHSV/pi-compaction-model (MIT), with an optional active-model fallback.

## Add these files to your existing pi-docker repository

Copy `install-pi-docker.sh` over the existing installer, add `extensions/pi-compaction-thinking.ts` and `extensions/LICENSE.pi-compaction-thinking`, and update `tests/installer.sh` and `tests/launcher.sh`. Keep `tests/fixtures/pi-docker-v10` for the v10 -> v11 upgrade regression test. Do not replace your entire repository with this bundle.

The installer installs the local extension in the *shared profile* at `~/.pi/agent/extensions/pi-compaction-thinking.ts`, where the container sees it at `/home/pi/.pi/agent/extensions/pi-compaction-thinking.ts`. It checks whether an identical file exists first. If absent it installs it; if present and identical it skips; if different it refuses overwrite unless `--force` is explicitly passed. There is no Dockerfile or image change.

## Separate configuration step (your configuration sync, not the installer)

Remove `"npm:pi-compaction-model"` from your canonical `settings.json` packages list to avoid double compaction handlers. Leave other packages as they are.

Add at the top level:

```json
"compactionModel": {
  "thinkingLevel": "medium"
}
```

No `model` field is needed. You can optionally set `"model": "provider/model-id"` to pin compaction. Empty `model` also uses the active model. `reasons` can optionally restrict handling to `"manual"`, `"threshold"`, `"overflow"`; by default all three are handled.

Pi loads local extensions automatically; DO NOT register this local `.ts` file in `packages`.

## Deploy

From your actual repository on the machine running pi-docker:

```bash
bash tests/installer.sh
bash tests/launcher.sh
./install-pi-docker.sh
pi-docker doctor
```

Look for `Local extension installed: pi-compaction-thinking.ts`. Run `/reload` or restart Pi to load it.

The old npm package will not be installed on new deployments. If it's already on disk, remove its **configuration registration** using your existing configuration-sync workflow. It is safe to leave unused npm files on disk; optionally use `pi-docker remove npm:pi-compaction-model` to uninstall it, noting that command modifies Pi's live settings and should be followed by your config sync.

**Runtime verification belongs on your actual system:** a successful `/compact` alone is not proof Medium was requested. Examine your router's request logs to confirm the reasoning setting and that normal turns remain at XHigh.

## Versioning and tests

The generated launcher is v11. The previous exact v10 launcher SHA-256 is whitelisted so existing unmodified installations upgrade without `--force`. Existing earlier allowed hashes are retained. The shell tests use a mock Docker and temporary profile, so they don't access your running Pi system. `tests/fixtures/pi-docker-v10` makes the v10 upgrade regression test independent of Git history.
