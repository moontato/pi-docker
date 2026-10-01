#!/usr/bin/env bash
# Managed by install-pi-docker.sh (v3)
set -Eeuo pipefail
umask 077

IMAGE=local/pi-docker:latest
ORIN_IMAGE=local/pi-docker:orin-sm87
IMAGE_VERSION=2
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pi-docker"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pi-docker"
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/pi-docker"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIGS_DIR="$SCRIPT_DIR/pi_configs"
DOCKERFILE="$CONFIG_DIR/Dockerfile"
ENV_FILE="$CONFIG_DIR/env"
REBUILD=0
INSTALL_ORIN=0
FORCE=0
SEARXNG_URL_ARG=''
SET_SEARXNG=0
LLAMA_URL_ARG=''
SET_LLAMA=0

usage() {
    cat <<'USAGE'
Usage: ./install-pi-docker.sh [--rebuild] [--install-orin] [--force] [--searxng-url URL] [--llama-url URL]
  --rebuild  Pull the base image and rebuild the managed Pi image (updates Pi).
  --install-orin  Build the separate Ubuntu 24.04 arm64 Orin development image.
  --force    Replace conflicting files or image tag deliberately.
  --searxng-url URL  Override the SearXNG URL; default is searxngBaseUrl in pi_configs/web-search.json.
  --llama-url URL    Override the llama.cpp router URL; default is the defaultProvider's baseUrl in pi_configs/models.json.

URLs, keys, and resource limits are stored in ~/.config/pi-docker/env
(manage them with: pi-docker config; see pi-docker --help).

Requires a working Docker daemon; does not install Docker.
jq is required to derive the URLs from pi_configs/ when the flags are omitted.
pi-docker uses the host's Tailscale network and DNS by default;
pass --no-tailnet to use Docker's normal network.
Installs pi-permission-modes and pi-ext-int-search in the isolated Pi agent directory.
The image includes bubblewrap, socat, and ripgrep for pi-permission-modes.
USAGE
}

die() { printf 'pi-docker setup: %s\n' "$*" >&2; exit 1; }

# A URL worth saving: well-formed, no angle brackets, and not the shipped template.
is_real_url() {
    [[ $1 =~ ^https?://[^[:space:]]+$ ]] && [[ $1 != *'<'* && $1 != *'>'* ]] && [[ $1 != *.example* ]]
}

require_jq() {
    command -v jq >/dev/null || die 'jq is required to derive URLs from pi_configs/*.json; install jq or pass --searxng-url/--llama-url explicitly.'
}

# --- Saved settings: ENV_FILE holds one KEY=VALUE per line (mode 600). ---

env_file_get() {
    local line
    [[ -f $ENV_FILE ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "$1="* ]]; then
            printf '%s' "${line#*=}"
            return 0
        fi
    done < "$ENV_FILE"
    return 0
}

env_file_set() {
    local key=$1 value=$2 line tmp
    tmp=$(mktemp)
    if [[ -f $ENV_FILE ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line != "$key="* ]]; then
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$ENV_FILE"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    install -m 600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}

migrate_legacy_url_files() {
    local pair file key value
    for pair in "searxng-url:SEARXNG_URL" "llama-url:LLAMA_BASE_URL"; do
        file="$CONFIG_DIR/${pair%%:*}"
        key="${pair#*:}"
        if [[ -f $file ]]; then
            value=''
            IFS= read -r value < "$file" || true
            if [[ -z $(env_file_get "$key") && -n $value ]]; then
                env_file_set "$key" "$value"
                printf 'Migrated %s into %s\n' "$file" "$ENV_FILE"
            fi
            rm -f "$file"
        fi
    done
}

while (($#)); do
    case "$1" in
        --rebuild) REBUILD=1 ;;
        --install-orin) INSTALL_ORIN=1 ;;
        --force) FORCE=1 ;;
        --searxng-url)
            (($# >= 2)) || die '--searxng-url requires a URL.'
            SEARXNG_URL_ARG=$2
            SET_SEARXNG=1
            shift
            ;;
        --llama-url)
            (($# >= 2)) || die '--llama-url requires a URL.'
            LLAMA_URL_ARG=$2
            SET_LLAMA=1
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

if ((SET_SEARXNG)); then
    [[ $SEARXNG_URL_ARG =~ ^https?://[^[:space:]]+$ ]] || die 'SearXNG URL must start with http:// or https:// and contain no whitespace.'
    [[ $SEARXNG_URL_ARG != *'<'* && $SEARXNG_URL_ARG != *'>'* ]] || die 'Replace the placeholder with your actual SearXNG address.'
fi
if ((SET_LLAMA)); then
    [[ $LLAMA_URL_ARG =~ ^https?://[^[:space:]]+$ ]] || die 'llama URL must start with http:// or https:// and contain no whitespace.'
    [[ $LLAMA_URL_ARG != *'<'* && $LLAMA_URL_ARG != *'>'* ]] || die 'Replace the placeholder with your actual llama-server address.'
fi

[[ $(uname -s) == Linux ]] || die 'Linux is required.'
command -v docker >/dev/null || die 'Docker is not installed or is not on PATH.'
docker info >/dev/null 2>&1 || die 'Cannot access the Docker daemon as this user.'
[[ -d $HOME ]] || die 'HOME must be a real directory.'

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

cat >"$work_dir/Dockerfile" <<'DOCKERFILE_CONTENT'
# Managed by install-pi-docker.sh (v2)
FROM node:24-bookworm-slim

LABEL io.pi-docker.installer="2"

# sudo and gosu let Pi run as the host UID and install OS packages on demand.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl wget git jq ripgrep \
        python3 python3-pip python3-venv build-essential \
        sudo gosu \
    && rm -rf /var/lib/apt/lists/* \
    && printf 'ALL ALL=(root) NOPASSWD: ALL\n' > /etc/sudoers.d/pi-docker \
    && chmod 0440 /etc/sudoers.d/pi-docker

RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

# Keep these after Pi's npm layer so the one-time dependency upgrade can reuse
# the cached base packages and Pi install. Docker's own security profile stays on.
RUN apt-get update \
    && apt-get install -y --no-install-recommends bubblewrap socat \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/pi-docker-entrypoint
RUN chmod 0755 /usr/local/bin/pi-docker-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/pi-docker-entrypoint"]
DOCKERFILE_CONTENT

cat >"$work_dir/entrypoint.sh" <<'ENTRYPOINT_CONTENT'
#!/bin/sh
# Managed by install-pi-docker.sh (v1)
set -eu

case "${PI_DOCKER_UID:-}" in ''|*[!0-9]*) echo 'Invalid PI_DOCKER_UID' >&2; exit 1 ;; esac
case "${PI_DOCKER_GID:-}" in ''|*[!0-9]*) echo 'Invalid PI_DOCKER_GID' >&2; exit 1 ;; esac

if ! getent group "$PI_DOCKER_GID" >/dev/null; then
    groupadd --gid "$PI_DOCKER_GID" pi-docker
fi
if ! getent passwd "$PI_DOCKER_UID" >/dev/null; then
    useradd --no-create-home --uid "$PI_DOCKER_UID" --gid "$PI_DOCKER_GID" \
        --home-dir /home/pi --shell /bin/bash pi-docker
fi

exec gosu "$PI_DOCKER_UID:$PI_DOCKER_GID" pi "$@"
ENTRYPOINT_CONTENT

cat >"$work_dir/pi-docker" <<'LAUNCHER_CONTENT'
#!/usr/bin/env bash
# Managed by install-pi-docker.sh (v4)
set -Eeuo pipefail

IMAGE=local/pi-docker:latest
ORIN_IMAGE=local/pi-docker:orin-sm87
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pi-docker"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pi-docker"
AGENT_DIR="$DATA_DIR/agent"
SANDBOX_HOME="$DATA_DIR/home"
TAILNET=1
PROJECT_DIR=''
ORIN_MODE=0
ORIN_VALIDATE=0
ENV_FILE="$CONFIG_DIR/env"

config_keys="SEARXNG_URL LLAMA_BASE_URL LLAMA_API_KEY PI_DOCKER_MEMORY PI_DOCKER_CPUS ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY GROQ_API_KEY"

die() { printf 'pi-docker: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: pi-docker [options] [pi args...]
       pi-docker config [list|get|set|unset] [KEY [VALUE]]
       pi-docker doctor

Options:
  --tailnet          Use the host network and Tailscale DNS (default).
  --no-tailnet       Use Docker's normal network instead.
  --project DIR      Bind DIR as /workspace instead of the current directory.
  --orin             Jetson AGX Orin CUDA development (no extra capabilities).
  --orin-profile     Same as --orin, plus CAP_SYS_ADMIN for ncu counters.
  --orin-validate    Run the Orin validation probe instead of Pi.
  -h, --help         Show this help.

Commands:
  config             Manage settings saved in ~/.config/pi-docker/env:
                       pi-docker config list           show settings (keys masked)
                       pi-docker config get KEY        show one value
                       pi-docker config set KEY VALUE  save a value
                       pi-docker config unset KEY      remove a value
  doctor             Check Docker, image, packages, settings, and network.

Recognized settings (shell environment always wins over saved values):
  SEARXNG_URL, LLAMA_BASE_URL, LLAMA_API_KEY, PI_DOCKER_MEMORY, PI_DOCKER_CPUS,
  ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, GOOGLE_GENERATIVE_AI_API_KEY,
  GROQ_API_KEY.

Known options are consumed; everything else is passed to Pi unchanged.
USAGE
}

# --- Saved settings: ENV_FILE holds one KEY=VALUE per line (mode 600). ---

env_get() {
    local line
    [[ -f $ENV_FILE ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "$1="* ]]; then
            printf '%s' "${line#*=}"
            return 0
        fi
    done < "$ENV_FILE"
    return 0
}

env_set() {
    local key=$1 value=$2 line tmp
    tmp=$(mktemp)
    if [[ -f $ENV_FILE ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line != "$key="* ]]; then
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$ENV_FILE"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    install -m 600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}

env_unset() {
    local key=$1 line tmp found=0
    tmp=$(mktemp)
    if [[ -f $ENV_FILE ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line == "$key="* ]]; then
                found=1
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$ENV_FILE"
        if (( found )); then
            install -m 600 "$tmp" "$ENV_FILE"
        fi
    fi
    rm -f "$tmp"
    (( found ))
}

is_config_key() {
    local key
    for key in $config_keys; do
        if [[ $key == "$1" ]]; then
            return 0
        fi
    done
    return 1
}

is_valid_url() {
    [[ $1 =~ ^https?://[^[:space:]]+$ ]] && [[ $1 != *'<'* && $1 != *'>'* ]]
}

config_set() {
    local key=$1 value=$2
    is_config_key "$key" || die "Unknown setting: $key"
    if [[ -z $value ]]; then
        die "Value for $key must not be empty."
    fi
    case $key in
        SEARXNG_URL|LLAMA_BASE_URL)
            is_valid_url "$value" || die "$key must be a URL like https://host:port, with no whitespace or angle brackets."
            ;;
        PI_DOCKER_MEMORY)
            [[ $value =~ ^[0-9]+(\.[0-9]+)?([bkmgBKMGtT])?$ ]] || die "PI_DOCKER_MEMORY must be a number with an optional b/k/m/g/t suffix (e.g. 8g)."
            ;;
        PI_DOCKER_CPUS)
            [[ $value =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "PI_DOCKER_CPUS must be a number (e.g. 4 or 2.5)."
            ;;
    esac
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    env_set "$key" "$value"
    printf 'Saved %s to %s\n' "$key" "$ENV_FILE"
}

config_get() {
    local key=$1 value
    is_config_key "$key" || die "Unknown setting: $key"
    value=$(env_get "$key")
    if [[ -z $value ]]; then
        die "$key is not set (pi-docker config set $key VALUE)"
    fi
    printf '%s\n' "$value"
}

config_unset() {
    local key=$1
    is_config_key "$key" || die "Unknown setting: $key"
    env_unset "$key" || die "$key is not set."
    printf 'Removed %s from %s\n' "$key" "$ENV_FILE"
}

config_list() {
    local line key
    if [[ ! -f $ENV_FILE ]]; then
        printf 'No saved settings (pi-docker config set KEY VALUE).\n'
        return 0
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        key=${line%%=*}
        case $key in
            *API_KEY) printf '%s=***\n' "$key" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$ENV_FILE"
}

run_config() {
    local cmd=${1:-list}
    if (( $# > 0 )); then shift; fi
    case $cmd in
        list) config_list ;;
        get)
            (( $# == 1 )) || die 'Usage: pi-docker config get KEY'
            config_get "$1"
            ;;
        set)
            (( $# == 2 )) || die 'Usage: pi-docker config set KEY VALUE'
            config_set "$1" "$2"
            ;;
        unset)
            (( $# == 1 )) || die 'Usage: pi-docker config unset KEY'
            config_unset "$1"
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown config command: $cmd (expected list, get, set, or unset)" ;;
    esac
    exit 0
}

# One-time migration from the pre-v3 URL files into the env file.
migrate_legacy_url_files() {
    local pair file key value
    for pair in "searxng-url:SEARXNG_URL" "llama-url:LLAMA_BASE_URL"; do
        file="$CONFIG_DIR/${pair%%:*}"
        key="${pair#*:}"
        if [[ -f $file ]]; then
            value=''
            IFS= read -r value < "$file" || true
            if [[ -z $(env_get "$key") && -n $value ]]; then
                env_set "$key" "$value"
                printf 'Migrated %s into %s\n' "$file" "$ENV_FILE"
            fi
            rm -f "$file"
        fi
    done
}

# --- Health checks ---

DOCTOR_PASS=0
DOCTOR_FAIL=0

doc_ok()   { printf '  [ok]   %s\n' "$1"; DOCTOR_PASS=$((DOCTOR_PASS + 1)); }
doc_bad()  { printf '  [FAIL] %s\n' "$1"; DOCTOR_FAIL=$((DOCTOR_FAIL + 1)); }
doc_note() { printf '  [note] %s\n' "$1"; }

launcher_version() {
    local v
    v=$(sed -n '2s/^#.*(\(.*\))$/\1/p' "$0")
    printf '%s' "${v:-unknown}"
}

doctor() {
    local url key line label have_docker
    printf 'pi-docker doctor (launcher %s)\n\n' "$(launcher_version)"

    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
        doc_ok 'Docker daemon reachable'
        have_docker=1
    else
        doc_bad 'Docker daemon not reachable (is Docker installed and running?)'
        have_docker=0
    fi

    if (( have_docker )); then
        if docker image inspect "$IMAGE" >/dev/null 2>&1; then
            label=$(docker image inspect --format '{{ index .Config.Labels "io.pi-docker.installer" }}' "$IMAGE" 2>/dev/null || true)
            if [[ -n $label ]]; then
                doc_ok "Image $IMAGE present (managed, installer version $label)"
            else
                doc_bad "Image $IMAGE exists but is not managed by install-pi-docker.sh"
            fi
            if docker run --rm --entrypoint sh "$IMAGE" -c 'command -v bwrap && command -v socat && command -v rg' >/dev/null 2>&1; then
                doc_ok 'Image sandbox dependencies present (bwrap, socat, rg)'
            else
                doc_bad 'Image sandbox dependencies missing (rerun: ./install-pi-docker.sh --rebuild)'
            fi
        else
            doc_bad "Image $IMAGE missing (run ./install-pi-docker.sh)"
        fi
    fi

    doc_ok "Launcher version: $(launcher_version)"

    for key in pi-permission-modes pi-ext-int-search; do
        if [[ -d $AGENT_DIR/npm/node_modules/$key ]]; then
            doc_ok "Package installed: $key"
        else
            doc_bad "Package missing: $key (rerun the installer, or: pi-docker install npm:$key)"
        fi
    done

    for line in "$CONFIG_DIR" "$DATA_DIR" "$AGENT_DIR" "$SANDBOX_HOME"; do
        if [[ -d $line ]]; then
            doc_ok "Directory: $line"
        else
            doc_bad "Directory missing: $line"
        fi
    done

    if [[ -f $ENV_FILE ]]; then
        doc_ok "Settings file: $ENV_FILE"
        while IFS= read -r line || [[ -n $line ]]; do
            key=${line%%=*}
            case $key in
                *API_KEY) doc_note "set: $key=***" ;;
                *) doc_note "set: $line" ;;
            esac
        done < "$ENV_FILE"
    else
        doc_note 'No settings file yet (pi-docker config set KEY VALUE)'
    fi

    if command -v curl >/dev/null; then
        for key in SEARXNG_URL LLAMA_BASE_URL; do
            url=''
            if [[ -v $key ]]; then url=${!key}; fi
            if [[ -z $url ]]; then url=$(env_get "$key"); fi
            if [[ -n $url ]]; then
                if curl -s -o /dev/null --max-time 3 "$url"; then
                    doc_ok "$key reachable: $url"
                else
                    doc_bad "$key not reachable: $url"
                fi
            else
                doc_note "$key not configured"
            fi
        done
    else
        doc_note 'curl not found; skipping URL reachability checks'
    fi

    if command -v timeout >/dev/null; then
        if timeout 2 bash -c 'exec 3<>/dev/tcp/100.100.100.100/53' 2>/dev/null; then
            doc_ok 'Tailscale DNS (100.100.100.100:53) reachable'
        else
            doc_bad 'Tailscale DNS unreachable (is tailscaled running? use --no-tailnet to fall back)'
        fi
    else
        doc_note 'timeout not found; skipping Tailscale DNS probe'
    fi

    if [[ :$PATH: == *":$HOME/.local/bin:"* ]]; then
        doc_ok '~/.local/bin on PATH'
    else
        doc_note "Add $HOME/.local/bin to PATH to run pi-docker by name"
    fi

    printf '\n%d passed, %d failed\n' "$DOCTOR_PASS" "$DOCTOR_FAIL"
    if (( DOCTOR_FAIL > 0 )); then
        return 1
    fi
    return 0
}

case ${1:-} in
    config) shift; run_config "$@" ;;
    doctor) doctor || exit 1; exit 0 ;;
esac

while (($#)); do
    case $1 in
        --tailnet) TAILNET=1 ;;
        --no-tailnet) TAILNET=0 ;;
        --orin) (( ORIN_MODE == 0 )) || die 'Select only one Orin mode.'; ORIN_MODE=1 ;;
        --orin-profile) (( ORIN_MODE == 0 )) || die 'Select only one Orin mode.'; ORIN_MODE=2 ;;
        --orin-validate) ORIN_VALIDATE=1 ;;
        --project)
            (( $# >= 2 )) || die '--project requires a directory.'
            PROJECT_DIR=$2
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) break ;;
    esac
    shift
done

if (( ORIN_VALIDATE && ! ORIN_MODE )); then die '--orin-validate requires --orin or --orin-profile.'; fi
if (( ORIN_VALIDATE && $# )); then die '--orin-validate does not accept Pi arguments.'; fi
if (( ORIN_MODE )); then
    [[ -z $PROJECT_DIR ]] || die 'Orin mode uses /mnt/ssd/llama-orin-test; omit --project.'
    [[ $(uname -m) == aarch64 ]] || die 'Orin mode requires aarch64.'
    for path in /mnt/ssd/llama-orin-test /mnt/ssd/llamacpp_models /usr/local/cuda-13.2 /opt/nvidia/nsight-compute; do
        [[ -d $path && ! -L $path ]] || die "Required Orin directory missing or symlink: $path"
    done
    [[ -f /mnt/ssd/llama-orin-test/CMakeLists.txt ]] || die 'llama.cpp development tree is missing CMakeLists.txt.'
    [[ -x /usr/local/cuda-13.2/bin/nvcc ]] || die 'CUDA 13.2 nvcc is missing.'
    [[ -x /usr/local/cuda-13.2/bin/ncu ]] || die 'CUDA 13.2 ncu is missing.'
    docker image inspect "$ORIN_IMAGE" >/dev/null 2>&1 || die "Orin image missing; run ./install-pi-docker.sh --install-orin"
    docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"' || die 'NVIDIA Container Runtime not available in Docker (or Docker inaccessible).'
    PROJECT_DIR=/mnt/ssd/llama-orin-test
    IMAGE=$ORIN_IMAGE
fi

workdir_src=$(pwd -P)
if [[ -n $PROJECT_DIR ]]; then
    [[ -d $PROJECT_DIR ]] || die "Project directory not found: $PROJECT_DIR"
    workdir_src=$(cd -- "$PROJECT_DIR" && pwd -P) || die "Cannot resolve project directory: $PROJECT_DIR"
fi

mkdir -p "$CONFIG_DIR" "$AGENT_DIR" "$SANDBOX_HOME"
chmod 700 "$CONFIG_DIR" "$DATA_DIR" "$AGENT_DIR" "$SANDBOX_HOME"
migrate_legacy_url_files

args=(run --rm --init --pids-limit=512
    --mount "type=bind,source=$workdir_src,target=/workspace"
    --mount "type=bind,source=$AGENT_DIR,target=/pi-agent"
    --mount "type=bind,source=$SANDBOX_HOME,target=/home/pi"
    --workdir /workspace
    --env HOME=/home/pi
    --env PI_CODING_AGENT_DIR=/pi-agent
    --env PI_SKIP_VERSION_CHECK=1
    --env "PI_DOCKER_UID=$(id -u)"
    --env "PI_DOCKER_GID=$(id -g)"
    --env "TERM=${TERM:-xterm-256color}"
)

if (( ORIN_MODE )); then
    args+=(--runtime=nvidia
        --env NVIDIA_VISIBLE_DEVICES=all
        --env NVIDIA_DRIVER_CAPABILITIES=compute,utility
        --mount 'type=bind,source=/usr/local/cuda-13.2,target=/usr/local/cuda-13.2,readonly'
        --mount 'type=bind,source=/opt/nvidia/nsight-compute,target=/opt/nvidia/nsight-compute,readonly'
        --mount 'type=bind,source=/mnt/ssd/llamacpp_models,target=/models,readonly')
    gpu_gids=()
    for device in /dev/nvhost-ctrl-gpu /dev/nvidia0 /dev/dri/renderD128; do
        if [[ -e $device ]]; then
            gid=$(stat -c %g "$device")
            if [[ $gid != 0 && ! " ${gpu_gids[*]} " == *" $gid "* ]]; then gpu_gids+=("$gid"); fi
        fi
    done
    args+=(--env "PI_DOCKER_GPU_GIDS=${gpu_gids[*]}")
    (( ORIN_MODE != 2 )) || args+=(--cap-add=SYS_ADMIN)
    (( ! ORIN_VALIDATE )) || args+=(--env PI_DOCKER_ORIN_VALIDATE=1)
fi

if ((TAILNET)); then
    # This shares the host network namespace, including the host's local services.
    args+=(--network=host --dns=100.100.100.100)
fi

searxng_url=${SEARXNG_URL:-}
if [[ -z $searxng_url ]]; then searxng_url=$(env_get SEARXNG_URL); fi
[[ -z $searxng_url ]] || args+=(--env "SEARXNG_URL=$searxng_url")

llama_url=${LLAMA_BASE_URL:-}
if [[ -z $llama_url ]]; then llama_url=$(env_get LLAMA_BASE_URL); fi
[[ -z $llama_url ]] || args+=(--env "LLAMA_BASE_URL=$llama_url")

llama_key=${LLAMA_API_KEY:-}
if [[ -z $llama_key ]]; then llama_key=$(env_get LLAMA_API_KEY); fi
[[ -z $llama_key ]] || args+=(--env "LLAMA_API_KEY=$llama_key")

[[ -t 0 ]] && args+=(--interactive)
[[ -t 0 && -t 1 ]] && args+=(--tty)

# Pass only explicitly selected provider keys; do not forward the whole host environment.
for key in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY \
    GOOGLE_GENERATIVE_AI_API_KEY GROQ_API_KEY; do
    value=''
    if [[ -v $key ]]; then value=${!key}; fi
    if [[ -z $value ]]; then value=$(env_get "$key"); fi
    if [[ -n $value ]]; then args+=(--env "$key=$value"); fi
done

memory=${PI_DOCKER_MEMORY:-}
if [[ -z $memory ]]; then memory=$(env_get PI_DOCKER_MEMORY); fi
[[ -z $memory ]] || args+=(--memory "$memory")

cpus=${PI_DOCKER_CPUS:-}
if [[ -z $cpus ]]; then cpus=$(env_get PI_DOCKER_CPUS); fi
[[ -z $cpus ]] || args+=(--cpus "$cpus")

exec docker "${args[@]}" "$IMAGE" "$@"
LAUNCHER_CONTENT

check_file() {
    local destination=$1 candidate=$2
    if [[ -e $destination || -L $destination ]]; then
        if [[ -L $destination ]]; then
            die "$destination is a symlink; replace it yourself before running the installer."
        fi
        if ! cmp -s "$destination" "$candidate" && [[ $FORCE -ne 1 ]]; then
            # Exact v1 launcher can be upgraded while preserving customized copies.
            if [[ $destination == "$LAUNCHER" ]] && \
                [[ $(sha256sum "$destination" | cut -d' ' -f1) == 08ba0128ccd739be06daaa881a410bd43fa9c94219bad5386ad051552f4ec589 ]]; then
                return
            fi
            # Exact v2 launcher can be upgraded while preserving customized copies.
            if [[ $destination == "$LAUNCHER" ]] && \
                [[ $(sha256sum "$destination" | cut -d' ' -f1) == 6f53b50b526db4d3a081802589bf79552bf3790cd94a5eeed57a82395bc95044 ]]; then
                return
            fi
            # Exact v2.1 launcher can be upgraded while preserving customized copies.
            if [[ $destination == "$LAUNCHER" ]] && \
                [[ $(sha256sum "$destination" | cut -d' ' -f1) == a9e7d2070b44e7726229f87f2ca6de7a0286a4189196327f1b1c2cf758d73e57 ]]; then
                return
            fi
            # Upgrade the exact v3 launcher automatically, without replacing user edits.
            if [[ $destination == "$LAUNCHER" ]] && \
                [[ $(sha256sum "$destination" | cut -d' ' -f1) == 2d5091b3c014a0419851cba9b70536e2895cdde0c32dccfe9c0c816f67084cd3 ]]; then
                return
            fi
            # Upgrade the exact Dockerfile shipped in image v1 automatically.
            if [[ $destination == "$DOCKERFILE" ]] && \
                [[ $(sha256sum "$destination" | cut -d' ' -f1) == 553a25e729d82e38f7883f345d8b1b0672f15aa1aa70397a49d4b691967de8a0 ]]; then
                return
            fi
            die "$destination differs from this installer; use --force to replace it."
        fi
    fi
}

check_file "$DOCKERFILE" "$work_dir/Dockerfile"
check_file "$CONFIG_DIR/entrypoint.sh" "$work_dir/entrypoint.sh"
check_file "$LAUNCHER" "$work_dir/pi-docker"

existing_label=''
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    existing_label=$(docker image inspect --format '{{ index .Config.Labels "io.pi-docker.installer" }}' "$IMAGE")
    if [[ $existing_label != "$IMAGE_VERSION" && $existing_label != 1 && $FORCE -ne 1 ]]; then
        die "Docker image $IMAGE is not managed by this installer; use --force to replace it."
    fi
fi

mkdir -p "$CONFIG_DIR" "$DATA_DIR/agent" "$DATA_DIR/home" "$BIN_DIR"
chmod 700 "$CONFIG_DIR" "$DATA_DIR" "$DATA_DIR/agent" "$DATA_DIR/home"
migrate_legacy_url_files

# URL flags override; otherwise derive from the pi_configs/ files next to this script.
if ((SET_SEARXNG)); then
    env_file_set SEARXNG_URL "$SEARXNG_URL_ARG"
    printf 'Saved SEARXNG_URL to %s\n' "$ENV_FILE"
elif [[ -f $CONFIGS_DIR/web-search.json ]]; then
    require_jq
    derived=$(jq -r '.searxngBaseUrl // empty' "$CONFIGS_DIR/web-search.json" 2>/dev/null) || {
        printf 'Warning: could not read %s; no SearXNG URL derived.\n' "$CONFIGS_DIR/web-search.json" >&2
        derived=''
    }
    if is_real_url "$derived"; then
        env_file_set SEARXNG_URL "$derived"
        printf 'SearXNG URL from pi_configs/web-search.json: %s\n' "$derived"
    elif [[ -n $(env_file_get SEARXNG_URL) ]]; then
        printf 'Keeping previously saved SearXNG URL.\n'
    else
        printf 'No SearXNG URL found; set searxngBaseUrl in pi_configs/web-search.json or pass --searxng-url URL.\n' >&2
    fi
fi
if ((SET_LLAMA)); then
    env_file_set LLAMA_BASE_URL "$LLAMA_URL_ARG"
    printf 'Saved LLAMA_BASE_URL to %s\n' "$ENV_FILE"
elif [[ -f $CONFIGS_DIR/models.json ]]; then
    require_jq
    provider=$(jq -r '.defaultProvider // empty' "$CONFIGS_DIR/settings.json" 2>/dev/null) || provider=''
    derived=$(jq -rn --arg p "$provider" --slurpfile m "$CONFIGS_DIR/models.json" \
        '($m[0].providers // {}) as $prov | ((($prov[$p] // ($prov | to_entries | .[0]?.value)) | .baseUrl) // empty)' 2>/dev/null) || {
        printf 'Warning: could not read %s; no llama URL derived.\n' "$CONFIGS_DIR/models.json" >&2
        derived=''
    }
    # LLAMA_BASE_URL is the router root, not the /v1 endpoint.
    derived=${derived%/}
    derived=${derived%/v1}
    if is_real_url "$derived"; then
        env_file_set LLAMA_BASE_URL "$derived"
        printf 'Llama URL from pi_configs/models.json: %s\n' "$derived"
    elif [[ -n $(env_file_get LLAMA_BASE_URL) ]]; then
        printf 'Keeping previously saved llama URL.\n'
    else
        printf 'No llama URL found; set a provider baseUrl in pi_configs/models.json or pass --llama-url URL.\n' >&2
    fi
fi
for spec in "Dockerfile:$DOCKERFILE:644" "entrypoint.sh:$CONFIG_DIR/entrypoint.sh:644"; do
    IFS=: read -r name destination mode <<<"$spec"
    if ! cmp -s "$work_dir/$name" "$destination"; then
        install -m "$mode" "$work_dir/$name" "$destination"
    fi
done

if [[ -z $existing_label || $existing_label != "$IMAGE_VERSION" || $REBUILD -eq 1 ]]; then
    build_args=(build --tag "$IMAGE")
    # Reuse the local base image during an automatic dependency-only upgrade.
    # A fresh install or deliberate --rebuild checks for a newer base image.
    [[ -n $existing_label && $REBUILD -eq 0 ]] || build_args+=(--pull)
    [[ $REBUILD -eq 0 ]] || build_args+=(--no-cache)
    docker "${build_args[@]}" "$CONFIG_DIR"
    docker run --rm --entrypoint sh "$IMAGE" -c 'command -v bwrap && command -v socat && command -v rg' \
        || die 'Image was built but a sandbox dependency is missing.'
else
    printf 'Managed Docker image already installed: %s\n' "$IMAGE"
fi

if (( INSTALL_ORIN )); then
    [[ $(uname -m) == aarch64 ]] || die '--install-orin requires an aarch64 host.'
    # Separate tag: never replace the default managed image.
    docker build --file "$SCRIPT_DIR/Dockerfile.orin" --tag "$ORIN_IMAGE" "$SCRIPT_DIR" \
        || die 'Could not build the Orin image.'
fi

if ! cmp -s "$work_dir/pi-docker" "$LAUNCHER"; then
    install -m 755 "$work_dir/pi-docker" "$LAUNCHER"
else
    chmod 755 "$LAUNCHER"
fi

"$LAUNCHER" --version || die 'Pi did not start; check the Docker build and runtime output above.'

# Pi packages live under the separately mounted /pi-agent, not in the image.
# Skipping an installed package avoids network downloads on ordinary reruns.
for package in pi-permission-modes pi-ext-int-search; do
    if [[ -d $DATA_DIR/agent/npm/node_modules/$package ]]; then
        printf 'Pi package already installed: %s\n' "$package"
    else
        printf 'Installing Pi package: %s\n' "$package"
        ( cd "$CONFIG_DIR" && "$LAUNCHER" install "npm:$package" ) || die "Could not install $package. Rerun the installer to retry."
        if [[ ! -d $DATA_DIR/agent/npm/node_modules/$package ]]; then
            ( cd "$CONFIG_DIR" && "$LAUNCHER" update "npm:$package" ) || die "Could not reconcile $package. Rerun the installer to retry."
        fi
        [[ -d $DATA_DIR/agent/npm/node_modules/$package ]] || die "$package was not installed under the isolated Pi agent directory. Check with pi-docker list and retry."
    fi
done

if [[ -f $DATA_DIR/agent/settings.json ]] && grep -Fq 'npm:@oresk/pi-searxng' "$DATA_DIR/agent/settings.json"; then
    printf 'Note: @oresk/pi-searxng also declares web_search; consider removing it if both tools conflict.\n' >&2
fi

printf '\nReady: %s\nRun `pi-docker` from a project directory (pi-docker --help lists options).\nCheck health anytime with: pi-docker doctor\n' "$LAUNCHER"
if [[ :$PATH: != *":$BIN_DIR:"* ]]; then
    printf 'Add %s to your PATH to use `pi-docker` by name.\n' "$BIN_DIR"
fi
