# pi-docker streamlining: guided setup + single command surface

## Context

pi-docker is a single-repo tool: `install-pi-docker.sh` (builds the managed image, installs
the `~/.local/bin/pi-docker` launcher and Pi packages, derives/saves service URLs from
`pi_configs/`) plus `pi_configs/setup-pi-config.sh` (syncs five canonical files into the
host and/or pi-docker profiles). Work continues on the `features` branch (last commit
`5d61d7d`); `main` stays at the published state.

Current install friction:

- Four manual steps: hand-edit three JSON files (5+ placeholders across
  `models.json`, `settings.json`, `web-search.json`) → run installer → run the deployer
  separately → use.
- Real gap: after installing, the docker profile has **no** `models.json` /
  `settings.json` at all — Pi starts with no llama provider until the user remembers step 3.
- Two scripts with two flag sets to remember; no uninstall, no version visibility, no
  self-update.

This pass builds two feature areas. **F1 (guided setup) is the priority** and is
implemented first; F2 (launcher command surface) follows. The remaining suggestions
(doctor placeholder checks, build-context fix, marker-based auto-upgrade, jq removal,
session logging) are recorded as later considerations only.

## F1 — One guided install (priority)

**Design decision: the wizard lives in the installer, not the launcher.**
`pi_configs/` is the canonical configuration and sits next to the installer
(`$SCRIPT_DIR/pi_configs`); the launcher is a standalone managed file in `~/.local/bin`
with no knowledge of the repo location. Keeping the wizard in the installer preserves the
"pi_configs is canonical" contract and keeps the deployer the single sync mechanism.

### F1.1 — Interactive install, prompted only when needed

`./install-pi-docker.sh` detects missing values and prompts only for those, before the
build:

1. **SearXNG URL** — default: saved `SEARXNG_URL`, else `searxngBaseUrl` in
   `pi_configs/web-search.json` if it passes the existing `is_real_url` check. Skippable
   (empty → left unset).
2. **Llama server URL** — default: saved `LLAMA_BASE_URL`, else the default provider's
   `models.json` `baseUrl` with `/v1` stripped. Skippable.
   - **Normalization**: accept root or `/v1` form from the user; store the **root** in the
     env file (existing contract: `LLAMA_BASE_URL` is the router root, not the `/v1`
     endpoint) and root+`/v1` (appended only if absent) in `models.json`.
3. **Model ID** — default: first model id of the default provider in `models.json` if it
   is not `your-model-id`. Required (this setup targets the local llama server).
4. **Model name** (display) — default: the model ID.
5. **Llama API key** — optional; empty keeps the `dummy` in `models.json`; non-empty also
   writes `LLAMA_API_KEY` to the env file.

Prompt rules:

- Prompt only for values that are missing or still placeholders → a plain rerun prompts
  nothing (today's behavior is preserved).
- Existing `--searxng-url` / `--llama-url` suppress the matching prompt and write the env
  file (behavior unchanged).
- New flags for fully non-interactive installs: `--model-id ID`, `--model-name NAME`,
  `--llama-api-key KEY`.
- `--yes`: never prompt; use saved/default values as-is (skipped ones stay unset).
- `jq` remains required in this pass (its removal is a later consideration).

### F1.2 — Where the wizard writes

- **Env file** (`env_file_set`): `SEARXNG_URL`, `LLAMA_BASE_URL`, `LLAMA_API_KEY`.
- **`pi_configs/models.json`** (jq in-place edit): default provider `baseUrl`, first
  model `id` and `name`.
- **`pi_configs/settings.json`** (jq in-place edit): `defaultModel`, and the
  `compaction.modelOverrides` key becomes `<defaultProvider>/<model-id>`. The placeholder
  appears in three places today; the wizard keeps them consistent in one edit.
- **`pi_configs/web-search.json`** (jq in-place edit): `searxngBaseUrl`. If the SearXNG
  host is outside `100.100.0.1/32`, offer (optional) to append its range to
  `ssrf.allowRanges`.
- The existing URL-derivation block stays as the non-wizard fallback; values written by
  the wizard are consistent with it, so no logic changes there.

### F1.3 — Installer auto-syncs the docker profile (closes the gap)

After the package installs, the installer syncs `pi_configs/` → docker profile by
invoking the deployer:

- `pi_configs/setup-pi-config.sh --target docker --yes` (no `--install-packages`; the
  installer already handles packages).
- Host profile is untouched (the installer's scope is pi-docker; `--target host` remains
  an explicit user choice).
- If the deployer script is missing or broken: warn and fall back to a plain `cp` of the
  five files (no `.bak`).
- A deployer failure fails the install — it is the step that makes the profile usable.

### F1.4 — Final doctor

The installer runs `"$LAUNCHER" doctor` at the end (after the existing `--version` smoke
test). Output is shown; failures do not fail the install (exit stays 0), they just list
what is still missing. This replaces the current two-line "Ready" footer.

### F1.5 — README rewrite

- "Set up once" → prerequisites, then a single `./install-pi-docker.sh` (asks for the
  SearXNG URL, llama URL, and model ID once).
- New "Non-interactive install" note listing the full flag set.
- The "Sync the provided configuration" section moves down and is reframed as "when you
  edit `pi_configs/` by hand."

## F2 — One command surface (launcher subcommands)

Launcher managed version v3 → v4.

**Shared infra: `PI_DOCKER_CONFIGS_DIR`** — an internal env-file key, not in the
`config_keys` whitelist (so not settable via `pi-docker config set`; it does show in
`config list` output, which is acceptable — it is not secret). The installer writes it at
install time (absolute path of `pi_configs/`). Used by `sync` and `update`.

### `pi-docker sync [--target host|docker|both] [--check] [--restore] [--yes]`

- Locates the deployer at `$PI_DOCKER_CONFIGS_DIR/setup-pi-config.sh` (shell variable,
  else the env file).
- If not found: clear error with both remedies (set the variable, or run the script
  directly from the repo).
- Otherwise execs the deployer with the mapped flags. The deployer keeps its own
  interface for repo/CI use; users no longer need to remember the second script, and
  `pi-docker sync --check` is the drift check.

### `pi-docker version`

- Launcher version (parsed from the managed-marker line).
- Image label `io.pi-docker.installer` (or "image missing").
- Pi version inside the image: `docker run --rm --entrypoint sh $IMAGE -c 'pi --version'`
  (skipped with a note when the image is absent).

### `pi-docker update`

- Resolves the installer as `$(dirname "$PI_DOCKER_CONFIGS_DIR")/install-pi-docker.sh`.
- Found: `exec bash <installer> "$@"` — flags pass through (`--rebuild`, `--force`,
  URL/model flags, `--yes`).
- Not found: message pointing at the repo / README for `git pull` + rerun.

### `pi-docker uninstall`

- Shows what will be removed: image `local/pi-docker:latest`, launcher
  `~/.local/bin/pi-docker`, `~/.config/pi-docker`, `~/.local/share/pi-docker` (profile +
  packages).
- `--keep-data` preserves the data directory (profile + packages); `--yes` skips the
  confirmation prompt.
- Never touches `~/.pi` (the host Pi profile).

### Launcher usage / README

- `usage()` gains the four subcommands.
- README gets a management section covering `sync`, `version`, `update`, `uninstall`,
  and the `PI_DOCKER_CONFIGS_DIR` note.

## Shared housekeeping

- Launcher managed marker `(v3)` → `(v4)`; add the sha256 of the current v3 launcher
  (extracted from `LAUNCHER_CONTENT` at implementation time) to the `check_file`
  auto-upgrade list so existing installs pick up v4 on rerun without `--force`.
  (Replacing that hash list with marker-based comparison is a later consideration.)
- Installer `usage()`: document the interactive default plus `--model-id`,
  `--model-name`, `--llama-api-key`, `--yes`.
- `IMAGE_VERSION` stays 2 (no image changes).

## Later considerations (documented only, not built)

- `doctor`: placeholder/coherence checks (`your-model-id`, `*.example` in synced
  settings; `defaultProvider`/`defaultModel` exist in `models.json`) and a non-blocking
  Tailscale probe at launcher start with a `--no-tailnet` hint.
- Build-context fix: build from the temp `work_dir` instead of `$CONFIG_DIR` — the env
  file with API keys is currently uploaded to the Docker daemon as build context.
- Marker-based auto-upgrade replacing the sha256 list in `check_file`.
- Drop the `jq` requirement (flag/env-file-first derivation).
- Session logging (`--log` to `~/.local/share/pi-docker/logs/` with rotation), since
  `--rm` discards crashed-session transcripts.

## Implementation order

1. F1 wizard: detection + prompts + new flags (installer)
2. F1 writes: env file + jq edits to the three `pi_configs` files
3. F1 auto-sync (deployer invocation) + final doctor + README setup rewrite
4. F2: `PI_DOCKER_CONFIGS_DIR` + `sync` / `version` / `update` / `uninstall`
   (launcher; installer writes the key)
5. Housekeeping: v4 marker, `check_file` hash, usage text, README management section
6. Full test pass, then commit

## Verification

- `bash -n` on installer, extracted launcher, and deployer; JSON files validate.
- Installer end-to-end (fake-docker harness, temp HOME/XDG):
  - Fresh clone, piped stdin: env and `pi_configs` get real values; `models.json`
    baseUrl is root+`/v1`; env `LLAMA_BASE_URL` has no `/v1`; `settings.json`
    `defaultModel` and `modelOverrides` key match the model ID.
  - Rerun with real values: no prompts, exit 0.
  - `--yes` with placeholders: no prompts, placeholders remain.
  - Flags: `--model-id` / `--model-name` / `--llama-api-key` / `--searxng-url` /
    `--llama-url` fully non-interactive.
  - Auto-sync: docker profile files match `pi_configs`; `.bak` created on overwrite;
    host profile untouched; missing deployer → fallback copy with warning.
  - Final doctor runs; install exits 0 even with unreachable URLs.
- Launcher (fake-docker harness): `sync` with path set/unset, `version` output,
  `update` invoking a stub installer with passthrough args, `uninstall` removing temp
  dirs (`--keep-data`, `--yes`).
- Deployer regression: `--check` in-sync/drift exit codes, `--restore` round-trip.
- `git grep` for secrets and placeholders; no real URLs or keys in the tree.

## Commits (on `features`)

1. Installer: interactive setup wizard (detection, prompts, flags, `pi_configs` writes)
2. Installer: auto-sync to docker profile + final doctor + README setup rewrite
3. Launcher: `sync` / `version` / `update` / `uninstall` + `PI_DOCKER_CONFIGS_DIR`
4. Housekeeping: v4 marker, `check_file` hash, usage text, README management section
