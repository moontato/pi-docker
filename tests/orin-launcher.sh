#!/usr/bin/env bash
# Synthetic host and fake Docker: no GPU, daemon, real SSD or host CUDA required.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
awk '/^cat >"\$work_dir\/pi-docker" <<'"'"'LAUNCHER_CONTENT'"'"'/{p=1;next} /^LAUNCHER_CONTENT$/{p=0} p' "$repo/install-pi-docker.sh" > "$tmp/pi-docker"
chmod +x "$tmp/pi-docker"
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/data" "$tmp/fixture/source" "$tmp/fixture/models" "$tmp/fixture/cuda/bin"
: > "$tmp/fixture/source/CMakeLists.txt"
: > "$tmp/fixture/models/Qwen3.8-27B-UD-Q4_K_XL.gguf"
: > "$tmp/fixture/cuda/bin/nvcc"
chmod +x "$tmp/fixture/cuda/bin/nvcc"
# Only the extracted test launcher is modified; production paths remain literal in the installer.
python3 - "$tmp/pi-docker" "$tmp/fixture" <<'PY'
import pathlib, sys
path, fixture = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
for old, new in [('/mnt/ssd/llama-orin-test', fixture + '/source'),
                 ('/mnt/ssd/llamacpp_models', fixture + '/models'),
                 ('/usr/local/cuda-13.2', fixture + '/cuda'),
                 ('/opt/nvidia/nsight-compute', fixture + '/ncu'),
                 ('/opt/nvidia/nsight-systems', fixture + '/nsys')]:
    text = text.replace(old, new)
for name, target in [('ncu', '/opt/nvidia/nsight-compute'),
                     ('nsys', '/opt/nvidia/nsight-systems'),
                     ('cuda', '/usr/local/cuda-13.2')]:
    text = text.replace('target=' + fixture + '/' + name, 'target=' + target)
path.write_text(text)
PY
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$DOCKER_CALLS_LOG"
if [[ ${1:-} == image && ${2:-} == inspect ]]; then exit 0; fi
if [[ ${1:-} == info ]]; then printf '{"nvidia":{}}\n'; exit 0; fi
if [[ ${1:-} == version ]]; then printf '29.8.0\n'; exit 0; fi
printf '%s\n' "$@" > "$DOCKER_ARGS_LOG"
MOCK
cat > "$tmp/bin/uname" <<'MOCK'
#!/usr/bin/env bash
if [[ $1 == -m ]]; then printf '%s\n' "${MOCK_ARCH:-aarch64}"; else /usr/bin/uname "$@"; fi
MOCK
chmod +x "$tmp/bin/docker" "$tmp/bin/uname"
export HOME="$tmp" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data"
export PATH="$tmp/bin:$PATH" DOCKER_ARGS_LOG="$tmp/args" DOCKER_CALLS_LOG="$tmp/calls"
mkdir -p "$tmp/config/pi-docker"
: > "$tmp/config/pi-docker/orin-seccomp-docker29-arm64.json"
assert_fail() {
    : > "$tmp/calls"
    if "$tmp/pi-docker" --no-tailnet --orin >"$tmp/out" 2>&1; then echo 'expected launch failure' >&2; exit 1; fi
    ! grep -qx run "$tmp/calls"
    grep -q "$1" "$tmp/out"
}
"$tmp/pi-docker" --no-tailnet
! grep -q -e '--runtime=nvidia' -e '--cap-add=SYS_ADMIN' -e '--security-opt' -e "$tmp/fixture/cuda" "$tmp/args"
grep -qx 'local/pi-docker:latest' "$tmp/args"
! grep -q -e image -e info "$tmp/calls"
: > "$tmp/calls"
"$tmp/pi-docker" --no-tailnet --orin --orin-validate
grep -qx -- '--runtime=nvidia' "$tmp/args"
grep -qx -- 'apparmor=pi-docker-orin' "$tmp/args"
grep -qx -- "seccomp=$tmp/config/pi-docker/orin-seccomp-docker29-arm64.json" "$tmp/args"
[[ $(grep -cx -- '--security-opt' "$tmp/args") == 2 ]]
! grep -q -e 'unconfined' -e '--privileged' "$tmp/args"
grep -qx -- "type=bind,source=$tmp/fixture/models,target=/models,readonly" "$tmp/args"
grep -qx -- "type=bind,source=$tmp/fixture/source,target=/workspace" "$tmp/args"
grep -qx -- 'PI_DOCKER_ORIN_VALIDATE=1' "$tmp/args"
! grep -q -e 'SYS_ADMIN' -e '/mnt/ssd/llama.cpp' -e '--privileged' "$tmp/args"
! grep -q 'nsight' "$tmp/args"
mkdir -p "$tmp/fixture/ncu" "$tmp/fixture/nsys"
: > "$tmp/fixture/cuda/bin/ncu"
"$tmp/pi-docker" --no-tailnet --orin-profile --orin-validate
grep -qx -- '--cap-add=SYS_ADMIN' "$tmp/args"
grep -qx -- 'PI_DOCKER_ORIN_PROFILE=1' "$tmp/args"
grep -qx -- "type=bind,source=$tmp/fixture/ncu,target=/opt/nvidia/nsight-compute,readonly" "$tmp/args"
grep -qx -- "type=bind,source=$tmp/fixture/nsys,target=/opt/nvidia/nsight-systems,readonly" "$tmp/args"
! grep -q -e '/mnt/ssd/llama.cpp' -e '--privileged' "$tmp/args"
[[ $(grep -c -- '--cap-add=' "$tmp/args") == 1 ]]
[[ $(grep -c -- '--runtime=' "$tmp/args") == 1 ]]
[[ $(grep -cx -- '--security-opt' "$tmp/args") == 2 ]]
! grep -q -e 'unconfined' -e '--privileged' "$tmp/args"
rm -rf "$tmp/fixture/ncu" "$tmp/fixture/nsys" "$tmp/fixture/cuda/bin/ncu"
"$tmp/pi-docker" --no-tailnet --orin-profile 2>"$tmp/warnings"
grep -q 'warning: Nsight Compute is unavailable' "$tmp/warnings"
mv "$tmp/config/pi-docker/orin-seccomp-docker29-arm64.json" "$tmp/config/pi-docker/seccomp-away"
assert_fail 'Orin seccomp policy missing'
mv "$tmp/config/pi-docker/seccomp-away" "$tmp/config/pi-docker/orin-seccomp-docker29-arm64.json"
MOCK_ARCH=x86_64 assert_fail 'requires aarch64'
mv "$tmp/fixture/models" "$tmp/fixture/models-away"
assert_fail 'Required Orin directory missing'
mv "$tmp/fixture/models-away" "$tmp/fixture/models"
mv "$tmp/fixture/source" "$tmp/fixture/source-away"
assert_fail 'Required Orin directory missing'
mv "$tmp/fixture/source-away" "$tmp/fixture/source"
mv "$tmp/fixture/cuda" "$tmp/fixture/cuda-away"
assert_fail 'Required Orin directory missing'
mv "$tmp/fixture/cuda-away" "$tmp/fixture/cuda"
printf 'launcher argument and failure-path checks passed\n'
