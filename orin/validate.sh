#!/usr/bin/env bash
# Run inside the opt-in Orin image; no writes to the source tree or model directory.
set -Eeuo pipefail
fail() { printf 'Orin validation FAILED: %s\n' "$*" >&2; exit 1; }
[[ -d /workspace && -f /workspace/CMakeLists.txt ]] || fail 'llama.cpp source is not mounted at /workspace'
[[ -d /models ]] || fail 'models are not mounted at /models'
[[ -x /usr/local/cuda-13.2/bin/nvcc ]] || fail 'host CUDA toolkit is missing'
/usr/local/cuda-13.2/bin/nvcc --version || fail 'nvcc could not run'
command -v ncu >/dev/null || fail 'ncu not on PATH (check /opt/nvidia/nsight-compute mount)'
ncu --version || fail 'ncu could not run'
[[ -e /dev/nvhost-ctrl-gpu || -e /dev/nvidia0 || -e /dev/dri/renderD128 ]] || fail 'no GPU device exposed by the NVIDIA runtime'
# Filesystem check (rather than permission check: root may bypass read-only permissions).
command -v findmnt >/dev/null || fail 'findmnt is required to check mount permissions'
for spec in '/workspace:rw' '/models:ro'; do
    mountpoint=${spec%:*}
    expected=${spec#*:}
    target=$(findmnt -n -o TARGET -T "$mountpoint") || fail "cannot inspect $mountpoint mount"
    [[ $target == "$mountpoint" ]] || fail "$mountpoint is not a dedicated bind mount (found $target)"
    options=$(findmnt -n -o OPTIONS -T "$mountpoint") || fail "cannot inspect $mountpoint options"
    [[ ,$options, == *,"$expected",* ]] || fail "$mountpoint must be $expected: $options"
done
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cat >"$scratch/probe.cu" <<'CUDA'
#include <cstdio>
#include <cuda_runtime.h>
int main() {
    int count = 0;
    cudaError_t err = cudaGetDeviceCount(&count);
    if (err != cudaSuccess || count < 1) {
        fprintf(stderr, "CUDA GPU unavailable: %s (count %d)\n", cudaGetErrorString(err), count);
        return 1;
    }
    cudaDeviceProp prop{};
    err = cudaGetDeviceProperties(&prop, 0);
    if (err != cudaSuccess) {
        fprintf(stderr, "GPU properties unavailable: %s\n", cudaGetErrorString(err));
        return 1;
    }
    printf("GPU: %s; compute capability: %d.%d\n", prop.name, prop.major, prop.minor);
    return (prop.major == 8 && prop.minor == 7) ? 0 : 1;
}
CUDA
/usr/local/cuda-13.2/bin/nvcc -arch=sm_87 "$scratch/probe.cu" -o "$scratch/probe" || fail 'CUDA probe compilation failed'
"$scratch/probe" || fail 'GPU probe failed or compute capability is not 8.7'
printf 'Orin validation OK: nvcc, ncu, GPU SM87, /workspace (rw), /models (ro)\n'
