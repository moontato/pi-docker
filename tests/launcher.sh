#!/usr/bin/env bash
# Isolated profile and fake Docker: no daemon, network, or real config changes.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'result=$?; if (( result )); then [[ ! -f "$tmp/out" ]] || tail -20 "$tmp/out" >&2; fi; rm -rf "$tmp"' EXIT
awk '/^cat >"\$work_dir\/pi-docker" <<'"'"'LAUNCHER_CONTENT'"'"'/{p=1;next} /^LAUNCHER_CONTENT$/{p=0} p' "$repo/install-pi-docker.sh" > "$tmp/pi-docker"
chmod +x "$tmp/pi-docker"
mkdir -p "$tmp/bin" "$tmp/project" "$tmp/config" "$tmp/data/pi-docker/agent/npm/node_modules/"{pi-permission-modes,pi-ext-int-search} "$tmp/data/pi-docker/home"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$DOCKER_CALLS_LOG"
if [[ ${1:-} == image && ${2:-} == inspect ]]; then
    [[ ${3:-} != --format ]] || printf '2\n'
    exit 0
fi
[[ ${1:-} != info ]] || exit 0
if [[ ${1:-} == run ]]; then printf '%s\n' "$@" > "$DOCKER_ARGS_LOG"; exit 0; fi
exit 1
MOCK
cat > "$tmp/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TIMEOUT_ARGS_LOG"
exit "${MOCK_DNS_FAIL:-0}"
MOCK
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$tmp/bin/"*
export HOME="$tmp" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data"
export PATH="$tmp/bin:$PATH" DOCKER_ARGS_LOG="$tmp/args" DOCKER_CALLS_LOG="$tmp/calls" TIMEOUT_ARGS_LOG="$tmp/timeout-args"
unset PI_DOCKER_DNS PI_DOCKER_MEMORY PI_DOCKER_CPUS SEARXNG_URL LLAMA_BASE_URL LLAMA_API_KEY \
    ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY GROQ_API_KEY
cd "$tmp/project"

# The existing host-network default, workspace, image and security stay unchanged.
"$tmp/pi-docker" --version
grep -qx -- '--network=host' "$tmp/args"
grep -qx -- '--dns=100.100.100.100' "$tmp/args"
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
[[ $(stat -c %a "$tmp/config/pi-docker/env") == 600 ]]
"$tmp/pi-docker"
grep -qx -- '--dns=127.0.0.53' "$tmp/args"
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

# Doctor probes the selected resolver, masks keys, and reports failures honestly.
"$tmp/pi-docker" doctor > "$tmp/out"
grep -q 'Host-network DNS (127.0.0.53:53) reachable' "$tmp/out"
grep -qx '127.0.0.53' "$tmp/timeout-args"
! grep -q '100.100.100.100' "$tmp/timeout-args"
! grep -q fixture-secret "$tmp/out"
if MOCK_DNS_FAIL=1 "$tmp/pi-docker" doctor > "$tmp/out"; then
    echo 'doctor accepted a failed DNS port probe' >&2; exit 1
fi
grep -q 'Host-network DNS (127.0.0.53:53) unreachable' "$tmp/out"
PI_DOCKER_DNS=1.1.1.1 "$tmp/pi-docker" doctor > "$tmp/out"
grep -qx '1.1.1.1' "$tmp/timeout-args"

"$tmp/pi-docker" config unset PI_DOCKER_DNS > "$tmp/out"
[[ $("$tmp/pi-docker" config get OPENAI_API_KEY) == fixture-secret ]]
"$tmp/pi-docker"
grep -qx -- '--dns=100.100.100.100' "$tmp/args"
"$tmp/pi-docker" --no-tailnet
! grep -q -e '--network=host' -e '^--dns=' "$tmp/args"
printf 'generic launcher/DNS checks passed\n'
