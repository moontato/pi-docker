# macOS support for pi-docker

## Context and scope

The installer currently rejects macOS, and its generated launcher fails syntax checking with macOS's stock Bash 3.2 (`[[ -v ... ]]`). Linux host-network/resolver assumptions and shared npm installations are the other portability risks.

Target **local Docker Desktop on macOS**, supporting stock Bash 3.2 and keeping existing Linux behavior. Keep the Debian container and existing XDG-style paths; verify Apple Silicon and Intel image compatibility. Docker Desktop and jq remain user-installed prerequisites. Colima, OrbStack, remote Docker hosts, automatic Docker installation, and native macOS containers are out of scope.

**Planning changes only now. Do not create the branch or change implementation files until approval.**

## 1. Create the implementation branch after approval

- Recheck for unrelated changes; retain this plan without discarding any work.
- Create **`macos`** from the current `main`: `git switch -c macos`.
- If that branch already exists, stop and confirm rather than resetting it.
- All implementation changes belong on `macos`. Do not merge, push, or modify `main` automatically.

## 2. Make host-side scripts portable

**Files:** `install-pi-docker.sh`, `pi_configs/setup-pi-config.sh`.

- Detect Linux/Darwin in both installer and generated launcher; reject other hosts clearly.
- Replace Bash-4-only variable checks with Bash-3.2-compatible equivalents, retaining unset-variable safety and environment-over-saved-setting precedence.
- Add a portable SHA-256 helper using `sha256sum` or `shasum -a 256` for managed-file upgrade checks.
- Audit temporary files, BSD utilities, quoting, directory permissions, and the deployer under stock Bash.
- Give missing Docker/daemon/jq errors macOS-appropriate guidance. Print PATH instructions suitable for zsh without editing shell startup files.
- Bump the managed launcher marker and register the exact current v6 checksum for safe automatic upgrades. Keep custom-file protection and `--force` semantics. Leave image version 3 unchanged unless an image change proves necessary.

## 3. Use platform-appropriate networking

**File:** generated launcher/help/doctor in `install-pi-docker.sh`.

| Behavior | Linux | macOS |
| --- | --- | --- |
| Default | Existing host networking | Docker Desktop's normal networking/DNS |
| `--tailnet` | Existing host networking | Explicit Desktop host-network opt-in |
| `--no-tailnet` | Existing bridge networking | Normal Desktop networking |
| Resolver file | Existing Linux host mount when applicable | Never mount macOS `/etc/resolv.conf` |

- Document that `--no-tailnet` selects Docker networking; it does **not** disable the host's Tailscale/VPN. Normal Desktop networking may still reach tailnet services.
- macOS `--tailnet` requires Docker Desktop 4.34+ with host networking enabled in Settings. Provide actionable diagnostics; do not silently fall back or change Desktop settings.
- Preserve `PI_DOCKER_DNS` precedence/validation and host-network-only behavior. Explain ignored overrides in bridge mode and that Linux loopback-resolver recipes do not carry over to macOS.
- Document `host.docker.internal` for Mac-local services; do not silently rewrite saved URLs or canonical JSON.
- Extend doctor to report the effective platform/network mode and probe configured SearXNG/llama URLs **from the selected container network**, alongside existing public HTTPS checks. Preserve read-only behavior and secret masking.

## 4. Keep shared credentials/configuration, separate macOS/Linux npm installs

**Files:** `install-pi-docker.sh`, `pi_configs/setup-pi-config.sh`.

- First verify Pi's npm package-resolution behavior with disposable profiles.
- In macOS shared-profile mode, retain the `~/.pi` mount for credentials, settings, sessions, and user extensions, but overlay `/home/pi/.pi/agent/npm` with a container-only npm store at `$DATA_DIR/npm`.
- Install/reconcile container packages there even when native Mac packages already exist. Never overwrite or copy the Mac's installed npm tree into the Linux store.
- Make installer, doctor, and deployer package checks use the correct store. Preserve existing Linux sharing and `--isolated` behavior.
- Package declarations remain shared; document that native Mac Pi maintains its own installations. If Pi's resolver cannot support this narrowly scoped overlay, pause to review the alternative rather than silently making the whole profile isolated.
- Preserve UID/GID execution, nested-mount ordering, private container HOME, and host `auth.json`. Check nonstandard project locations/file-sharing failures with clear guidance.

## 5. Add regression coverage and documentation

**Files:** `tests/test_runtime.py`, `tests/test_configs.py`, `tests/installer.sh`, `tests/launcher.sh`, new `tests/test_macos.py`, `README.md`, `pi_configs/README.md`.

- Make Linux assumptions explicit in fake-Docker fixtures and add mocked Darwin cases so both paths are testable on either host.
- Cover stock Bash parsing, portable hashing, network selection/DNS, UID 501/GID 20, paths with spaces, API-key precedence/masking, doctor failures/read-only behavior, package-store separation, rerun idempotency, and v6 upgrades/custom-file protection.
- Remove GNU-only test assumptions (`stat -c`) and avoid relying on Homebrew tools being present in hard-coded PATHs.
- Document prerequisites, setup/PATH, both networking defaults, Tailscale/MagicDNS troubleshooting, package sharing, OAuth callback fallback, and Docker file-sharing requirements.
- Keep Bubblewrap's existing nested-sandbox limitations explicit; do not add `--privileged`, disable Docker security profiles, or promise nested sandbox enforcement without verification.

## Verification and access boundaries

1. Run stock `/bin/bash -n` on installer, extracted launcher, deployer, and shell tests; run generated entrypoint checks with `sh`.
2. Run offline tests on macOS and Linux:
   ```bash
   python3 -B -m unittest discover -s tests -v
   bash tests/launcher.sh
   bash tests/installer.sh
   ```
3. **Ask before real Docker integration tests.** Use disposable HOME/XDG/profile/project directories, not the user's real Pi profile. Docker daemon access and image/npm downloads are the main broader-access requirements.
4. Smoke-test clean install and rerun; extension loading and sandbox status; shared/isolated profiles; project writes/ownership; public HTTPS; tailnet IPs and MagicDNS; Mac-local service access; optional Desktop host networking; and resource limits.
5. With separate approval, test OAuth login persistence/callback behavior using disposable credentials. Do not print authorization codes or credential contents.
6. Test native arm64 on Apple Silicon and amd64/Intel where available. Report unavailable hardware, tailnet, or authentication checks as unverified—not passed.

## Completion criteria and estimate

macOS installs/runs with stock Bash and Docker Desktop; native Mac npm packages remain untouched; networking limitations are documented and diagnosable; existing Linux behavior and upgrade protections pass regression tests. No unapproved real-profile changes or weakened container security.

Estimate: **1–3 developer days**, with networking and npm-overlay validation as the primary uncertainties. Deliver the branch changes and verification results for review; merging/pushing remains a separate action.

Reference: [Docker Desktop host networking](https://docs.docker.com/engine/network/drivers/host/) and [Desktop VPN/host networking how-tos](https://docs.docker.com/desktop/features/networking/networking-how-tos/).
