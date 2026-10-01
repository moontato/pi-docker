#!/usr/bin/env bash
# Installer smoke test: fake Docker and isolated HOME; never modifies the real Pi install.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'result=$?; if (( result )); then for log in "$tmp/normal.out" "$tmp/orin.out"; do [[ ! -f $log ]] || tail -30 "$log" >&2; done; fi; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/data/pi-docker/agent/npm/node_modules/pi-permission-modes" \
    "$tmp/data/pi-docker/agent/npm/node_modules/pi-ext-int-search"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
if [[ ${1:-} == image && ${2:-} == inspect ]]; then
    if [[ ${3:-} == --format ]]; then printf '2\n'; fi
    exit 0
fi
case ${1:-} in info|run|build) exit 0 ;; esac
exit 1
MOCK
cat > "$tmp/bin/uname" <<'MOCK'
#!/usr/bin/env bash
if [[ $1 == -m ]]; then echo aarch64; else /usr/bin/uname "$@"; fi
MOCK
chmod +x "$tmp/bin/docker" "$tmp/bin/uname"
export HOME="$tmp" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data"
export PATH="$tmp/bin:$PATH" DOCKER_CALLS_LOG="$tmp/calls"
"$repo/install-pi-docker.sh" >"$tmp/normal.out" 2>&1
! grep -q -e 'orin-sm87' -e 'Dockerfile.orin' "$tmp/calls"
: > "$tmp/calls"
"$repo/install-pi-docker.sh" --install-orin >"$tmp/orin.out" 2>&1
[[ $(grep -c 'Dockerfile.orin' "$tmp/calls") == 1 ]]
grep -q 'local/pi-docker:orin-sm87' "$tmp/calls"
! grep -q 'build --tag local/pi-docker:latest' "$tmp/calls"
printf 'installer opt-in checks passed\n'
