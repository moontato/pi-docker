#!/usr/bin/env bash
# Installer checks against fake Docker and an isolated profile; no host changes.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'result=$?; if (( result )); then [[ ! -f "$tmp/out" ]] || tail -20 "$tmp/out" >&2; fi; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config/pi-docker" "$tmp/data/pi-docker/agent/npm/node_modules/"{pi-permission-modes,pi-ext-int-search}
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
if [[ ${1:-} == image && ${2:-} == inspect ]]; then
    [[ ${3:-} != --format ]] || printf '2\n'
    exit 0
fi
case ${1:-} in info|run|build) exit 0 ;; esac
exit 1
MOCK
chmod +x "$tmp/bin/docker"
export HOME="$tmp" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data"
export PATH="$tmp/bin:$PATH" DOCKER_CALLS_LOG="$tmp/calls"
unset PI_DOCKER_DNS SEARXNG_URL LLAMA_BASE_URL
printf 'PI_DOCKER_DNS=127.0.0.53\n' > "$tmp/config/pi-docker/env"
chmod 600 "$tmp/config/pi-docker/env"
"$repo/install-pi-docker.sh" > "$tmp/out" 2>&1
! grep -q '^build ' "$tmp/calls"
grep -q -- '--dns=127.0.0.53' "$tmp/calls"
launcher="$tmp/.local/bin/pi-docker"
grep -q 'Managed by install-pi-docker.sh (v3.1)' "$launcher"
[[ $("$launcher" config get PI_DOCKER_DNS) == 127.0.0.53 ]]
cp "$launcher" "$tmp/expected"
"$repo/install-pi-docker.sh" > "$tmp/out" 2>&1
cmp "$launcher" "$tmp/expected"
! grep -q '^build ' "$tmp/calls"

# Verify the real v3 checksum upgrade when the baseline history is available.
if git -C "$repo" cat-file -e 66b4e4f:install-pi-docker.sh 2>/dev/null; then
    git -C "$repo" show 66b4e4f:install-pi-docker.sh |
        awk '/^cat >"\$work_dir\/pi-docker" <<'"'"'LAUNCHER_CONTENT'"'"'/{p=1;next} /^LAUNCHER_CONTENT$/{p=0} p' > "$launcher"
    [[ $(sha256sum "$launcher" | cut -d' ' -f1) == 2d5091b3c014a0419851cba9b70536e2895cdde0c32dccfe9c0c816f67084cd3 ]]
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
printf 'generic installer checks passed\n'
