#!/usr/bin/env bash
# Isolated profile and fake Docker: no daemon, network, or real config changes.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
# -p keeps macOS mktemp (which ignores $TMPDIR without a template) and GNU mktemp consistent.
tmp=$(mktemp -d -p "${TMPDIR:-/tmp}")
# The launcher resolves project paths with pwd -P; on macOS /tmp is a symlink.
tmp=$(cd -- "$tmp" && pwd -P)

# GNU stat -c on Linux, BSD stat -f on macOS.
file_mode() {
    if stat -c %a "$1" 2>/dev/null; then return 0; fi
    stat -f %Lp "$1"
}
trap 'result=$?; if (( result )); then [[ ! -f "$tmp/out" ]] || tail -20 "$tmp/out" >&2; fi; rm -rf "$tmp"' EXIT
awk '/^cat >"\$work_dir\/pi-docker" <<'"'"'LAUNCHER_CONTENT'"'"'/{p=1;next} /^LAUNCHER_CONTENT$/{p=0} p' "$repo/install-pi-docker.sh" > "$tmp/pi-docker"
chmod +x "$tmp/pi-docker"
mkdir -p "$tmp/bin" "$tmp/project" "$tmp/config" "$tmp/.pi/agent/npm/node_modules/"{pi-permission-modes,pi-ext-int-search} "$tmp/data/pi-docker/home"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$DOCKER_CALLS_LOG"
if [[ ${1:-} == image && ${2:-} == inspect ]]; then
    [[ ${3:-} != --format ]] || printf '4\n'
    exit 0
fi
[[ ${1:-} != info ]] || exit 0
if [[ ${1:-} == run ]]; then
    printf '%s\n' "$@" > "$DOCKER_ARGS_LOG"
    if [[ " $* " == *' --entrypoint pi '* ]]; then printf '1.0.0\n'; fi
    if [[ " $* " == *' --entrypoint curl '* ]]; then exit "${MOCK_DNS_FAIL:-0}"; fi
    exit 0
fi
exit 1
MOCK
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
# The launcher detects the host OS at runtime; default to Linux so the
# original assertions hold on any host, and let sections override per-run.
cat > "$tmp/bin/uname" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${UNAME_OS:-Linux}"
STUB
chmod +x "$tmp/bin/"*
export HOME="$tmp" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data"
export PATH="$tmp/bin:/usr/bin:/bin" DOCKER_ARGS_LOG="$tmp/args" DOCKER_CALLS_LOG="$tmp/calls"
unset PI_DOCKER_DNS PI_DOCKER_MEMORY PI_DOCKER_CPUS SEARXNG_URL LLAMA_BASE_URL LLAMA_API_KEY \
    ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY GROQ_API_KEY
cd "$tmp/project"

# Default host resolver, workspace, image, and Docker security boundaries.
"$tmp/pi-docker" --version
grep -qx -- '--network=host' "$tmp/args"
grep -qx -- 'type=bind,source=/etc/resolv.conf,target=/etc/resolv.conf,readonly' "$tmp/args"
! grep -q '^--dns=' "$tmp/args"
grep -qx -- "type=bind,source=$tmp/project,target=/workspace" "$tmp/args"
grep -qx -- 'local/pi-docker:latest' "$tmp/args"
grep -qx -- '--version' "$tmp/args"
! grep -q -e '--privileged' -e 'unconfined' -e '--security-opt' -e 'SYS_ADMIN' "$tmp/args"
! grep -q -e image -e info "$tmp/calls"

"$tmp/pi-docker" config set OPENAI_API_KEY fixture-secret > "$tmp/out"
"$tmp/pi-docker" config set PI_DOCKER_DNS 127.0.0.53 > "$tmp/out"
[[ $("$tmp/pi-docker" config get PI_DOCKER_DNS) == 127.0.0.53 ]]
"$tmp/pi-docker" config list > "$tmp/list"
grep -qx 'PI_DOCKER_DNS=127.0.0.53' "$tmp/list"
grep -qx 'OPENAI_API_KEY=\*\*\*' "$tmp/list"
! grep -q fixture-secret "$tmp/list"
[[ $(file_mode "$tmp/config/pi-docker/env") == 600 ]]
"$tmp/pi-docker"
grep -qx -- '--dns=127.0.0.53' "$tmp/args"
grep -qx -- 'PI_PERMISSION_MODE=yolo' "$tmp/args"
[[ $(grep -c -- '^--dns=' "$tmp/args") == 1 ]]
PI_DOCKER_DNS=1.1.1.1 "$tmp/pi-docker" --tailnet
grep -qx -- '--dns=1.1.1.1' "$tmp/args"
[[ $("$tmp/pi-docker" config get PI_DOCKER_DNS) == 127.0.0.53 ]]

"$tmp/pi-docker" --no-tailnet
! grep -q -e '--network=host' -e '^--dns=' "$tmp/args"
PI_DOCKER_DNS=invalid "$tmp/pi-docker" --no-tailnet
! grep -q -e '--network=host' -e '^--dns=' "$tmp/args"
for bad in '' 256.1.1.1 127.0.0 127.0.0.01 localhost '::1' '127.0.0.53:53' '127.0.0.53 1.1.1.1' '$(touch INJECTED)'; do
    : > "$tmp/calls"
    if "$tmp/pi-docker" config set PI_DOCKER_DNS "$bad" > "$tmp/out" 2>&1; then
        echo 'invalid DNS setting accepted' >&2; exit 1
    fi
    [[ $("$tmp/pi-docker" config get PI_DOCKER_DNS) == 127.0.0.53 ]]
    ! grep -qx run "$tmp/calls"
done
[[ ! -e INJECTED ]]
: > "$tmp/calls"
if PI_DOCKER_DNS=256.0.0.1 "$tmp/pi-docker" > "$tmp/out" 2>&1; then
    echo 'invalid environment DNS override accepted' >&2; exit 1
fi
! grep -qx run "$tmp/calls"
grep -q 'PI_DOCKER_DNS must be one IPv4 address' "$tmp/out"

# Doctor probes DNS/HTTPS in the selected container, not just the DNS TCP port.
"$tmp/pi-docker" doctor > "$tmp/out"
grep -q 'Host-network DNS: 127.0.0.53' "$tmp/out"
grep -qx -- '--dns=127.0.0.53' "$tmp/args"
grep -q 'Container DNS/HTTPS reachable: https://auth.openai.com' "$tmp/out"
! grep -q fixture-secret "$tmp/out"
if MOCK_DNS_FAIL=1 "$tmp/pi-docker" doctor > "$tmp/out"; then
    echo 'doctor accepted a failed container DNS/HTTPS probe' >&2; exit 1
fi
grep -q 'Container DNS/HTTPS failed: https://auth.openai.com' "$tmp/out"
PI_DOCKER_DNS=1.1.1.1 "$tmp/pi-docker" doctor > "$tmp/out"
grep -qx -- '--dns=1.1.1.1' "$tmp/args"
PI_DOCKER_DNS=invalid "$tmp/pi-docker" doctor --no-tailnet > "$tmp/out"
grep -q 'Bridge-network DNS: Docker default' "$tmp/out"

"$tmp/pi-docker" config unset PI_DOCKER_DNS > "$tmp/out"
[[ $("$tmp/pi-docker" config get OPENAI_API_KEY) == fixture-secret ]]
"$tmp/pi-docker"
! grep -q '^--dns=' "$tmp/args"
grep -qx -- 'type=bind,source=/etc/resolv.conf,target=/etc/resolv.conf,readonly' "$tmp/args"
"$tmp/pi-docker" --no-tailnet
! grep -q -e '--network=host' -e '^--dns=' "$tmp/args"

# macOS: normal Docker networking by default, Desktop host networking with
# --tailnet, and a container-local npm store in shared mode.
UNAME_OS=Darwin "$tmp/pi-docker" --version
! grep -q -e '--network=host' -e '^--dns=' -e 'resolv.conf' "$tmp/args"
grep -qx -- "type=bind,source=$tmp/.pi,target=/home/pi/.pi" "$tmp/args"
grep -qx -- "type=bind,source=$tmp/data/pi-docker/npm,target=/home/pi/.pi/agent/npm" "$tmp/args"
UNAME_OS=Darwin "$tmp/pi-docker" --tailnet
grep -qx -- '--network=host' "$tmp/args"
! grep -q -e '^--dns=' -e 'resolv.conf' "$tmp/args"
UNAME_OS=Darwin PI_DOCKER_DNS=1.1.1.1 "$tmp/pi-docker" --tailnet
grep -qx -- '--dns=1.1.1.1' "$tmp/args"
# Seed the container-local npm store so doctor reports packages present.
mkdir -p "$tmp/data/pi-docker/npm/node_modules/"{pi-permission-modes,pi-ext-int-search}
UNAME_OS=Darwin "$tmp/pi-docker" doctor --tailnet > "$tmp/out"
grep -q 'Host-network (Docker Desktop) DNS: Docker default' "$tmp/out"
UNAME_OS=Darwin "$tmp/pi-docker" doctor > "$tmp/out"
grep -q 'Bridge-network DNS: Docker default' "$tmp/out"
printf 'generic launcher/DNS checks passed\n'
