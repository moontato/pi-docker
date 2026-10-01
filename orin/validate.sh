#!/usr/bin/env bash
# Run as the container user, either via --orin-validate or from Pi's shell.
set -Eeuo pipefail
fail() { printf 'Orin validation FAILED: %s\n' "$*" >&2; exit 1; }

[[ -f /workspace/CMakeLists.txt ]] || fail 'llama.cpp source is not mounted at /workspace'
[[ -d /models ]] || fail 'model directory is not mounted at /models'
command -v findmnt >/dev/null || fail 'findmnt is required to check bind mount permissions'
for spec in '/workspace:rw' '/models:ro'; do
    mountpoint=${spec%:*}
    expected=${spec#*:}
    target=$(findmnt -n -o TARGET -T "$mountpoint") || fail "cannot inspect $mountpoint mount"
    [[ $target == "$mountpoint" ]] || fail "$mountpoint is not a dedicated bind mount (found $target)"
    options=$(findmnt -n -o OPTIONS -T "$mountpoint") || fail "cannot inspect $mountpoint mount options"
    [[ ,$options, == *,"$expected",* ]] || fail "$mountpoint must be $expected: $options"
done

scratch=$(mktemp -d) || fail 'could not create temporary build directory'
workspace_probe=''
trap '[[ -z $workspace_probe ]] || rm -f -- "$workspace_probe"; rm -rf -- "$scratch"' EXIT
# mktemp creates a unique new file, never truncating or editing existing source files.
workspace_probe=$(mktemp /workspace/.pi-orin-validate.XXXXXXXX) || fail '/workspace is not writable'
rm -f -- "$workspace_probe" || fail 'could not clean up workspace probe'
workspace_probe=''
model=/models/Qwen3.8-27B-UD-Q4_K_XL.gguf
[[ -f $model && -r $model ]] || fail "expected model is missing or unreadable: $model"
# Mount metadata MUST say ro. Attempt creation as a second behavioral check;
# if unexpectedly successful, delete only the unique file we just created.
if model_probe=$(mktemp /models/.pi-orin-validate.XXXXXXXX 2>"$scratch/model-write-error"); then
    rm -f -- "$model_probe"
    fail 'models directory unexpectedly allowed creation'
fi
[[ -x /usr/local/cuda-13.2/bin/nvcc ]] || fail 'host CUDA 13.2 nvcc is missing'
nvcc_version=$(/usr/local/cuda-13.2/bin/nvcc --version) || fail 'nvcc could not run'
printf '%s\n' "$nvcc_version"
[[ $nvcc_version == *V13.2.86* ]] || fail 'nvcc is not the benchmark-baseline CUDA 13.2.86 compiler'
[[ -e /dev/nvhost-ctrl-gpu || -e /dev/nvidia0 || -e /dev/dri/renderD128 ]] || fail 'no GPU device exposed by the NVIDIA runtime'

cat >"$scratch/probe.cu" <<'CUDA'
#include <cstdio>
#include <cuda_runtime.h>
#define CHECK(call) do { \
    cudaError_t e = (call); \
    if (e != cudaSuccess) { fprintf(stderr, "%s: %s\n", #call, cudaGetErrorString(e)); return 1; } \
} while (0)
__global__ void transform(int *value) {
    if (threadIdx.x == 0 && blockIdx.x == 0) value[0] = value[0] * 3 + 7;
}
int main() {
    int count = 0;
    CHECK(cudaGetDeviceCount(&count));
    printf("CUDA device count: %d\n", count);
    if (count < 1) { fprintf(stderr, "No CUDA devices available\n"); return 1; }
    cudaDeviceProp prop{};
    CHECK(cudaGetDeviceProperties(&prop, 0));
    printf("GPU: %s; compute capability: %d.%d; total memory: %llu bytes\n",
        prop.name, prop.major, prop.minor, (unsigned long long)prop.totalGlobalMem);
    if (prop.major != 8 || prop.minor != 7) { fprintf(stderr, "Expected SM 8.7\n"); return 1; }
    int *device = nullptr;
    CHECK(cudaMalloc(&device, sizeof(int)));
    int value = 5;
    CHECK(cudaMemcpy(device, &value, sizeof(value), cudaMemcpyHostToDevice));
    transform<<<1, 1>>>(device);
    CHECK(cudaGetLastError());
    CHECK(cudaDeviceSynchronize());
    CHECK(cudaMemcpy(&value, device, sizeof(value), cudaMemcpyDeviceToHost));
    CHECK(cudaFree(device));
    if (value != 22) { fprintf(stderr, "Incorrect CUDA kernel output: got %d, expected 22\n", value); return 1; }
    printf("CUDA kernel result: %d (expected 22)\n", value);
    return 0;
}
CUDA
/usr/local/cuda-13.2/bin/nvcc -arch=sm_87 "$scratch/probe.cu" -o "$scratch/probe" || fail 'CUDA probe compilation failed'
"$scratch/probe" || fail 'CUDA runtime, driver, GPU or kernel correctness check failed'

if [[ -x /usr/local/cuda-13.2/bin/ncu && -d /opt/nvidia/nsight-compute ]]; then
    ncu --version || { [[ ${PI_DOCKER_ORIN_PROFILE:-0} != 1 ]] || fail 'Nsight Compute executable is broken'; printf 'Warning: ncu could not run\n' >&2; }
else
    [[ ${PI_DOCKER_ORIN_PROFILE:-0} != 1 ]] || fail 'Nsight Compute is missing (profiling mode requires ncu for validation)'
    printf 'Note: Nsight Compute is unavailable (optional for normal development)\n'
fi
if [[ -x /usr/local/cuda-13.2/bin/nsys && -d /opt/nvidia/nsight-systems ]]; then
    nsys --version || printf 'Warning: nsys could not run (optional)\n' >&2
else
    printf 'Note: Nsight Systems is unavailable (optional)\n'
fi

if [[ ${PI_DOCKER_ORIN_PROFILE:-0} == 1 ]]; then
    # Separate target execution, profiler availability, and counter-access errors.
    # On this Jetson, SYS_ADMIN is needed on the profiling process itself:
    # host ncu succeeds as root but fails as the regular user, even with an
    # ambient SYS_ADMIN capability. Elevate only ncu, not the Pi session.
    if ! sudo -n /usr/local/cuda-13.2/bin/ncu --metrics sm__cycles_active.avg --csv "$scratch/probe" >"$scratch/ncu.csv" 2>"$scratch/ncu-stderr"; then
        if grep -Eqi 'ERR_NVGPUCTRPERM|permission|not permitted|counter.*access' "$scratch/ncu.csv" "$scratch/ncu-stderr" 2>/dev/null; then
            fail 'Nsight Compute cannot access GPU performance counters (check host driver restrictions and SYS_ADMIN)'
        fi
        printf 'Nsight Compute diagnostics:\n' >&2
        tail -20 "$scratch/ncu-stderr" "$scratch/ncu.csv" >&2 || true
        fail 'Nsight Compute failed to profile the CUDA probe (check driver/tool compatibility)'
    fi
    if ! grep -Eq '"?sm__cycles_active\.avg"?,.*[0-9]' "$scratch/ncu.csv"; then
        fail 'Nsight Compute ran but did not return the requested hardware metric'
    fi
    printf 'Nsight Compute counter collection OK: sm__cycles_active.avg\n'
fi
printf 'Orin validation OK: CUDA SM87 kernel, /workspace (rw), /models (ro)\n'
