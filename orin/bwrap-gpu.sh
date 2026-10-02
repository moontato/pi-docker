#!/usr/bin/env bash
# Orin image only: @anthropic-ai/sandbox-runtime's --dev /dev hides Jetson GPU
# nodes. Rebind an explicit list of devices *after* --dev; do not bind /dev.
set -Eeuo pipefail
if [[ ${1:-} == --version || ${1:-} == --help ]]; then exec /usr/bin/bwrap "$@"; fi
args=()
inserted=0
while (($#)); do
    if [[ $1 == --dev && ${2:-} == /dev ]]; then
        (( ! inserted )) || { printf 'Orin bwrap: duplicate --dev /dev\n' >&2; exit 1; }
        args+=(--dev /dev)
        shift 2
        for node in /dev/nvidia0 /dev/nvidiactl /dev/nvhost-ctrl-gpu \
            /dev/nvhost-as-gpu /dev/nvhost-gpu /dev/nvmap \
            /dev/dri/renderD128 \
            /dev/nvgpu/igpu0/as /dev/nvgpu/igpu0/channel \
            /dev/nvgpu/igpu0/ctrl /dev/nvgpu/igpu0/nvsched \
            /dev/nvgpu/igpu0/power /dev/nvgpu/igpu0/sched \
            /dev/nvgpu/igpu0/tsg; do
            [[ ! -c $node ]] || args+=(--dev-bind "$node" "$node")
        done
        inserted=1
    else
        args+=("$1")
        shift
    fi
done
(( inserted )) || { printf 'Orin bwrap: expected --dev /dev not found\n' >&2; exit 1; }
exec /usr/bin/bwrap "${args[@]}"
