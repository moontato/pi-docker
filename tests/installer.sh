#!/usr/bin/env bash
# Installer checks against fake Docker and an isolated profile; no host changes.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
# -p keeps macOS mktemp (which ignores $TMPDIR without a template) and GNU mktemp consistent.
tmp=$(mktemp -d -p "${TMPDIR:-/tmp}")

# GNU sha256sum and BSD shasum both print the hex digest in field 1.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}
trap 'result=$?; if (( result )); then [[ ! -f "$tmp/out" ]] || tail -20 "$tmp/out" >&2; fi; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config/pi-docker" "$tmp/.pi/agent/npm/node_modules/"{pi-permission-modes,pi-ext-int-search}
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
if [[ ${1:-} == image && ${2:-} == inspect ]]; then
    [[ ${3:-} != --format ]] || printf '3\n'
    exit 0
fi
case ${1:-} in info|run|build) exit 0 ;; esac
exit 1
MOCK
# The installer detects the host OS at runtime; default to Linux so the
# original assertions hold on any host, and let sections override per-run.
cat > "$tmp/bin/uname" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${UNAME_OS:-Linux}"
STUB
chmod +x "$tmp/bin/docker" "$tmp/bin/uname"
export HOME="$tmp" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data"
export PATH="$tmp/bin:/usr/bin:/bin" DOCKER_CALLS_LOG="$tmp/calls"
unset PI_DOCKER_DNS SEARXNG_URL LLAMA_BASE_URL
printf 'PI_DOCKER_DNS=127.0.0.53\n' > "$tmp/config/pi-docker/env"
chmod 600 "$tmp/config/pi-docker/env"
"$repo/install-pi-docker.sh" > "$tmp/out" 2>&1
! grep -q '^build ' "$tmp/calls"
grep -q -- '--dns=127.0.0.53' "$tmp/calls"
launcher="$tmp/.local/bin/pi-docker"
grep -q 'Managed by install-pi-docker.sh (v7)' "$launcher"
[[ $("$launcher" config get PI_DOCKER_DNS) == 127.0.0.53 ]]
cp "$launcher" "$tmp/expected"
"$repo/install-pi-docker.sh" > "$tmp/out" 2>&1
cmp "$launcher" "$tmp/expected"
! grep -q '^build ' "$tmp/calls"

# Verify the real v3 checksum upgrade when the baseline history is available.
if git -C "$repo" cat-file -e 66b4e4f:install-pi-docker.sh 2>/dev/null; then
    git -C "$repo" show 66b4e4f:install-pi-docker.sh |
        awk '/^cat >"\$work_dir\/pi-docker" <<'"'"'LAUNCHER_CONTENT'"'"'/{p=1;next} /^LAUNCHER_CONTENT$/{p=0} p' > "$launcher"
    [[ $(sha256_of "$launcher") == 2d5091b3c014a0419851cba9b70536e2895cdde0c32dccfe9c0c816f67084cd3 ]]
    "$repo/install-pi-docker.sh" > "$tmp/out" 2>&1
    cmp "$launcher" "$tmp/expected"
    printf 'exact v3 launcher auto-upgrade passed\n'
fi

printf '\n# user customization\n' >> "$launcher"
cp "$launcher" "$tmp/custom"
if "$repo/install-pi-docker.sh" > "$tmp/out" 2>&1; then
    echo 'installer overwrote a customized launcher without --force' >&2; exit 1
fi
grep -q 'differs from this installer' "$tmp/out"
cmp "$launcher" "$tmp/custom"
"$repo/install-pi-docker.sh" --force > "$tmp/out" 2>&1
cmp "$launcher" "$tmp/expected"
! grep -q '^build ' "$tmp/calls"

# macOS install: same managed launcher (OS is detected at runtime), and the
# container-local npm store is pre-seeded so package installs are skipped.
mkdir -p "$tmp/data/pi-docker/npm/node_modules/"{pi-permission-modes,pi-ext-int-search}
UNAME_OS=Darwin "$repo/install-pi-docker.sh" > "$tmp/out" 2>&1
cmp "$launcher" "$tmp/expected"
! grep -q '^build ' "$tmp/calls"

printf 'generic installer checks passed\n'
