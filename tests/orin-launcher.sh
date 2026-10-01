#!/usr/bin/env bash
# Tests launcher argument construction without requiring Docker daemon or GPU.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
awk '/^cat >"\$work_dir\/pi-docker" <<'"'"'LAUNCHER_CONTENT'"'"'/{p=1;next} /^LAUNCHER_CONTENT$/{p=0} p' "$repo/install-pi-docker.sh" > "$tmp/pi-docker"
chmod +x "$tmp/pi-docker"
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/data"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ ${1:-} == image && ${2:-} == inspect ]]; then exit 0; fi
if [[ ${1:-} == info ]]; then printf '{"nvidia":{}}\n'; exit 0; fi
printf '%s\n' "$@" > "$DOCKER_ARGS_LOG"
MOCK
chmod +x "$tmp/bin/docker"
export HOME="$tmp" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data"
export PATH="$tmp/bin:$PATH" DOCKER_ARGS_LOG="$tmp/args"
"$tmp/pi-docker" --no-tailnet
! grep -q -e '--runtime=nvidia' -e '--cap-add=SYS_ADMIN' -e '/mnt/ssd/llama-orin-test' "$tmp/args"
grep -qx 'local/pi-docker:latest' "$tmp/args"
if [[ $(uname -m) == aarch64 && -d /mnt/ssd/llama-orin-test && -d /mnt/ssd/llamacpp_models && -d /opt/nvidia/nsight-compute && -d /usr/local/cuda-13.2 ]]; then
    "$tmp/pi-docker" --no-tailnet --orin --orin-validate
    grep -qx -- '--runtime=nvidia' "$tmp/args"
    grep -qx -- 'type=bind,source=/mnt/ssd/llamacpp_models,target=/models,readonly' "$tmp/args"
    grep -qx -- 'type=bind,source=/mnt/ssd/llama-orin-test,target=/workspace' "$tmp/args"
    grep -qx -- 'PI_DOCKER_ORIN_VALIDATE=1' "$tmp/args"
    ! grep -q -e 'SYS_ADMIN' -e '/mnt/ssd/llama.cpp,target=' "$tmp/args"
    "$tmp/pi-docker" --no-tailnet --orin-profile
    grep -qx -- '--cap-add=SYS_ADMIN' "$tmp/args"
    ! grep -q -- '--privileged' "$tmp/args"
fi
printf 'launcher argument checks passed\n'
