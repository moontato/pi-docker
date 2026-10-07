#!/usr/bin/env bash
# Managed by install-pi-docker.sh (v7)
set -Eeuo pipefail
umask 077

IMAGE=local/pi-docker:latest
IMAGE_VERSION=4
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pi-docker"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pi-docker"
NPM_DIR="$DATA_DIR/npm"
PI_DIR="$HOME/.pi"
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/pi-docker"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIGS_DIR="$SCRIPT_DIR/pi_configs"
DOCKERFILE="$CONFIG_DIR/Dockerfile"
ENV_FILE="$CONFIG_DIR/env"
REBUILD=0
FORCE=0
SEARXNG_URL_ARG=''
SET_SEARXNG=0
LLAMA_URL_ARG=''
SET_LLAMA=0

usage() {
    cat <<'USAGE'
Usage: ./install-pi-docker.sh [--rebuild] [--force] [--searxng-url URL] [--llama-url URL]
  --rebuild  Pull the base image and rebuild the managed Pi image (updates Pi).
  --force    Replace conflicting files or image tag deliberately.
  --searxng-url URL  Override the SearXNG URL; default is searxngBaseUrl in pi_configs/web-search.json.
  --llama-url URL    Override the llama.cpp router URL; default is the defaultProvider's baseUrl in pi_configs/models.json.

URLs, keys, and resource limits are stored in ~/.config/pi-docker/env
(manage them with: pi-docker config; see pi-docker --help).

Requires a working Docker daemon (Docker Desktop on macOS); does not install Docker.
jq is required to derive the URLs from pi_configs/ when the flags are omitted.
On Linux, pi-docker uses the host network and resolver (including Tailscale DNS)
by default; pass --no-tailnet to use Docker's normal network.
On macOS, pi-docker uses Docker Desktop's normal network by default; pass
--tailnet to use Docker Desktop host networking (Docker Desktop 4.34+).
pi-docker shares your ~/.pi profile with host Pi by default (logins, settings,
sessions, packages); pass --isolated to pi-docker for the old separate profile.
Installs pi-permission-modes and pi-ext-int-search into the shared Pi profile.
The image includes fd, ripgrep, bubblewrap, and socat; no startup tool downloads are needed.
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
    # -p keeps macOS mktemp (which ignores $TMPDIR without a template) and
    # GNU mktemp in the same, predictable temp directory.
    tmp=$(mktemp -p "${TMPDIR:-/tmp}")
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

HOST_OS=$(uname -s)
case $HOST_OS in
    Linux|Darwin) ;;
    *) die "Unsupported host OS: $HOST_OS (Linux or macOS is required)." ;;
esac
command -v docker >/dev/null || die 'Docker is not installed or is not on PATH.'
docker info >/dev/null 2>&1 || die 'Cannot access the Docker daemon as this user.'
[[ -d $HOME ]] || die 'HOME must be a real directory.'

work_dir=$(mktemp -d -p "${TMPDIR:-/tmp}")
trap 'rm -rf "$work_dir"' EXIT

cat >"$work_dir/Dockerfile" <<'DOCKERFILE_CONTENT'
# Managed by install-pi-docker.sh (v4)
FROM node:24-bookworm-slim

LABEL io.pi-docker.installer="4"

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
    && apt-get install -y --no-install-recommends bubblewrap socat fd-find \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/pi-docker-entrypoint
RUN chmod 0755 /usr/local/bin/pi-docker-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/pi-docker-entrypoint"]
DOCKERFILE_CONTENT

cat >"$work_dir/entrypoint.sh" <<'ENTRYPOINT_CONTENT'
#!/bin/sh
# Managed by install-pi-docker.sh (v3)
set -eu

case "${PI_DOCKER_UID:-}" in ''|*[!0-9]*) echo 'Invalid PI_DOCKER_UID' >&2; exit 1 ;; esac
case "${PI_DOCKER_GID:-}" in ''|*[!0-9]*) echo 'Invalid PI_DOCKER_GID' >&2; exit 1 ;; esac

if ! getent group "$PI_DOCKER_GID" >/dev/null; then
    groupadd --gid "$PI_DOCKER_GID" pi-docker
fi
if ! getent passwd "$PI_DOCKER_UID" >/dev/null; then
    # Debian's useradd prints a harmless range warning for host UIDs outside
    # /etc/login.defs - always the case on macOS, where the first user is 501.
    # Capture output and status, drop only that warning, keep everything else
    # (real errors, exit code) intact.
    ua_rc=0
    ua_out=$(useradd --no-create-home --uid "$PI_DOCKER_UID" --gid "$PI_DOCKER_GID" \
        --home-dir /home/pi --shell /bin/bash pi-docker 2>&1) || ua_rc=$?
    ua_out=$(printf '%s\n' "$ua_out" | grep -v '^useradd warning: .*outside of the [UG]ID_MIN .* range\.$' || true)
    if [ "$ua_rc" -ne 0 ]; then
        if [ -n "$ua_out" ]; then printf '%s\n' "$ua_out" >&2; fi
        exit "$ua_rc"
    fi
    if [ -n "$ua_out" ]; then printf '%s\n' "$ua_out" >&2; fi
fi

# gosu replaces HOME with the passwd entry's home. UID 1000 already belongs to
# the base image's node user (/home/node), not /home/pi. Restore our private
# HOME after dropping privileges so Pi and extensions see the mounted profile.
exec gosu "$PI_DOCKER_UID:$PI_DOCKER_GID" env HOME=/home/pi pi "$@"
ENTRYPOINT_CONTENT

cat >"$work_dir/pi-docker" <<'LAUNCHER_CONTENT'
#!/usr/bin/env bash
# Managed by install-pi-docker.sh (v7)
set -Eeuo pipefail

IMAGE=local/pi-docker:latest
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pi-docker"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pi-docker"
PI_DIR="$HOME/.pi"
ISOLATED_AGENT_DIR="$DATA_DIR/agent"
SANDBOX_HOME="$DATA_DIR/home"
NPM_DIR="$DATA_DIR/npm"
# Tailnet/host networking is the Linux default; macOS defaults to Docker
# Desktop's normal networking (override with --tailnet / --no-tailnet).
TAILNET=0
ISOLATED=0
DOCTOR=0
PROJECT_DIR=''
ENV_FILE="$CONFIG_DIR/env"

HOST_OS=$(uname -s)

config_keys="SEARXNG_URL LLAMA_BASE_URL LLAMA_API_KEY PI_DOCKER_MEMORY PI_DOCKER_CPUS PI_DOCKER_DNS ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY GROQ_API_KEY"

die() { printf 'pi-docker: %s\n' "$*" >&2; exit 1; }

case $HOST_OS in
    Linux) TAILNET=1 ;;
    Darwin) ;;
    *) die "Unsupported host OS: $HOST_OS (Linux or macOS is required)." ;;
esac

usage() {
    cat <<'USAGE'
Usage: pi-docker [options] [pi args...]
       pi-docker config [list|get|set|unset] [KEY [VALUE]]
       pi-docker doctor [--isolated] [--no-tailnet]

Options:
  --tailnet          Linux: host networking and host DNS unless PI_DOCKER_DNS
                     is set. macOS: Docker Desktop host networking (Docker
                     Desktop 4.34+; not the macOS default).
  --no-tailnet       Use Docker's normal network instead (the macOS default).
  --project DIR      Bind DIR as /workspace instead of the current directory.
  --isolated         Use the separate profile at ~/.local/share/pi-docker/agent
                     instead of sharing ~/.pi with host Pi.
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
  PI_DOCKER_DNS (one IPv4 resolver, host-network mode only),
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
    # -p keeps macOS mktemp (which ignores $TMPDIR without a template) and
    # GNU mktemp in the same, predictable temp directory.
    tmp=$(mktemp -p "${TMPDIR:-/tmp}")
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
    tmp=$(mktemp -p "${TMPDIR:-/tmp}")
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

# A single numeric IPv4 address avoids shell interpretation and DNS bootstrap.
is_valid_dns() {
    local octet
    local -a octets
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$1"
    for octet in "${octets[@]}"; do
        [[ $octet == 0 || $octet != 0* ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

host_network_dns() {
    local dns=${PI_DOCKER_DNS:-}
    if [[ -z $dns ]]; then dns=$(env_get PI_DOCKER_DNS); fi
    if [[ -n $dns ]]; then
        is_valid_dns "$dns" || die 'PI_DOCKER_DNS must be one IPv4 address (e.g. 127.0.0.53).'
    fi
    printf '%s' "$dns"
}

config_set() {
    local key=$1 value=$2
    is_config_key "$key" || die "Unknown setting: $key"
    if [[ -z $value ]]; then
        die "Value for $key must not be empty."
    fi
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || die "Value for $key must be a single line."
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
        PI_DOCKER_DNS)
            is_valid_dns "$value" || die 'PI_DOCKER_DNS must be one IPv4 address (e.g. 127.0.0.53).'
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
    local url key line label have_docker have_image=0 doctor_agent_dir doctor_pkg_root
    local host_version container_version
    local -a doctor_dirs probe_urls
    printf 'pi-docker doctor (launcher %s, %s)\n\n' "$(launcher_version)" "$HOST_OS"

    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
        doc_ok 'Docker daemon reachable'
        have_docker=1
    else
        doc_bad 'Docker daemon not reachable (is Docker installed and running?)'
        have_docker=0
    fi

    if (( have_docker )); then
        if docker image inspect "$IMAGE" >/dev/null 2>&1; then
            have_image=1
            label=$(docker image inspect --format '{{ index .Config.Labels "io.pi-docker.installer" }}' "$IMAGE" 2>/dev/null || true)
            if [[ -n $label ]]; then
                doc_ok "Image $IMAGE present (managed, installer version $label)"
            else
                doc_bad "Image $IMAGE exists but is not managed by install-pi-docker.sh"
            fi
            if docker run --rm --entrypoint sh "$IMAGE" -c 'command -v bwrap && command -v socat && command -v rg && command -v fd' >/dev/null 2>&1; then
                doc_ok 'Image dependencies present (bwrap, socat, rg, fd)'
            else
                doc_bad 'Image dependencies missing (rerun: ./install-pi-docker.sh --rebuild)'
            fi
            container_version=$(docker run --rm --entrypoint pi "$IMAGE" --version 2>/dev/null || true)
            if [[ -n $container_version ]]; then
                doc_ok "Container Pi version: $container_version"
                if command -v pi >/dev/null; then
                    host_version=$(pi --version 2>/dev/null || true)
                    if [[ -n $host_version && $host_version != "$container_version" ]]; then
                        doc_note "Pi version mismatch: host $host_version, container $container_version; --rebuild updates container Pi, not the host"
                    fi
                fi
            else
                doc_bad 'Cannot determine container Pi version'
            fi
        else
            doc_bad "Image $IMAGE missing (run ./install-pi-docker.sh)"
        fi
    fi

    doc_ok "Launcher version: $(launcher_version)"

    if ((ISOLATED)); then
        doctor_agent_dir="$ISOLATED_AGENT_DIR"
        doctor_pkg_root="$ISOLATED_AGENT_DIR/npm"
    else
        doctor_agent_dir="$PI_DIR/agent"
        case $HOST_OS in
            Darwin) doctor_pkg_root="$NPM_DIR" ;;
            *) doctor_pkg_root="$PI_DIR/agent/npm" ;;
        esac
    fi
    for key in pi-permission-modes pi-ext-int-search; do
        if [[ -d $doctor_pkg_root/node_modules/$key ]]; then
            doc_ok "Package installed: $key"
        else
            doc_bad "Package missing: $key (rerun the installer, or: pi-docker install npm:$key)"
        fi
    done

    doc_note "Selected profile: $doctor_agent_dir"
    if [[ $HOST_OS == Darwin ]] && ((ISOLATED == 0)); then
        doc_note "Container npm store: $NPM_DIR (host ~/.pi/agent/npm stays host-only)"
    fi
    if [[ -s $doctor_agent_dir/auth.json ]]; then
        doc_ok 'Profile auth.json exists (credentials are not displayed)'
    else
        doc_note 'No stored credentials in this profile; use host Pi /login or configure an API key/model'
    fi

    doctor_dirs=("$CONFIG_DIR" "$DATA_DIR" "$SANDBOX_HOME" "$doctor_agent_dir")
    for line in "${doctor_dirs[@]}"; do
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
            # ${VAR:-} (not [[ -v $key ]]): macOS ships Bash 3.2, which has no -v.
            case $key in
                SEARXNG_URL) url=${SEARXNG_URL:-} ;;
                LLAMA_BASE_URL) url=${LLAMA_BASE_URL:-} ;;
            esac
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

    if ((TAILNET)); then
        if [[ $HOST_OS == Darwin ]]; then
            doc_note "Host-network (Docker Desktop) DNS: ${dns:-Docker default}"
        else
            doc_note "Host-network DNS: ${dns:-host /etc/resolv.conf}"
        fi
    else
        doc_note 'Bridge-network DNS: Docker default (PI_DOCKER_DNS ignored)'
    fi

    # Probe from the selected container network, not just the host. A TCP
    # connection to a DNS server does not prove name resolution or HTTPS works.
    if ((have_image)); then
        if docker "${args[@]}" --entrypoint sh "$IMAGE" -c '
            exec gosu "$PI_DOCKER_UID:$PI_DOCKER_GID" env HOME=/home/pi sh -c '\''
                agent_dir=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
                test -d "$agent_dir" && test -r "$agent_dir" && test -w "$agent_dir" &&
                { test ! -e "$agent_dir/auth.json" || test -r "$agent_dir/auth.json"; }
            '\''
        '; then
            doc_ok 'Container profile accessible as the host UID'
        else
            doc_bad 'Container profile inaccessible (check mounts and file ownership)'
        fi
        # Probe the configured service URLs from the selected container
        # network as well, not only the public endpoints.
        probe_urls=(https://github.com https://auth.openai.com)
        for key in SEARXNG_URL LLAMA_BASE_URL; do
            url=''
            case $key in
                SEARXNG_URL) url=${SEARXNG_URL:-} ;;
                LLAMA_BASE_URL) url=${LLAMA_BASE_URL:-} ;;
            esac
            if [[ -z $url ]]; then url=$(env_get "$key"); fi
            [[ -n $url ]] || continue
            probe_urls+=("$url")
        done
        for url in "${probe_urls[@]}"; do
            if docker "${args[@]}" --entrypoint curl "$IMAGE" \
                --silent --show-error --output /dev/null --connect-timeout 3 --max-time 10 "$url"; then
                doc_ok "Container DNS/HTTPS reachable: $url"
            else
                doc_bad "Container DNS/HTTPS failed: $url (check the resolver, or try --no-tailnet)"
            fi
        done
    else
        doc_note 'Skipping container profile/network checks: image unavailable'
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
    doctor) DOCTOR=1; shift ;;
esac

while (($#)); do
    case $1 in
        --tailnet) TAILNET=1 ;;
        --no-tailnet) TAILNET=0 ;;
        --isolated) ISOLATED=1 ;;
        --project)
            (( $# >= 2 )) || die '--project requires a directory.'
            PROJECT_DIR=$2
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            ((DOCTOR == 0)) || die "Unknown doctor option: $1"
            break
            ;;
    esac
    shift
done

workdir_src=$(pwd -P)
if [[ -n $PROJECT_DIR ]]; then
    [[ -d $PROJECT_DIR ]] || die "Project directory not found: $PROJECT_DIR"
    workdir_src=$(cd -- "$PROJECT_DIR" && pwd -P) || die "Cannot resolve project directory: $PROJECT_DIR"
fi

# doctor is read-only: report missing directories instead of creating them.
if ((DOCTOR == 0)); then
    if ((ISOLATED)); then
        mkdir -p "$CONFIG_DIR" "$ISOLATED_AGENT_DIR" "$SANDBOX_HOME"
        chmod 700 "$CONFIG_DIR" "$DATA_DIR" "$ISOLATED_AGENT_DIR" "$SANDBOX_HOME"
    else
        mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$SANDBOX_HOME" "$PI_DIR/agent"
        chmod 700 "$CONFIG_DIR" "$DATA_DIR" "$SANDBOX_HOME" "$PI_DIR"
        if [[ $HOST_OS == Darwin ]]; then
            mkdir -p "$NPM_DIR"
            chmod 700 "$NPM_DIR"
        fi
    fi
    migrate_legacy_url_files
fi

args=(run --rm --init --pids-limit=512
    --mount "type=bind,source=$workdir_src,target=/workspace"
    --mount "type=bind,source=$SANDBOX_HOME,target=/home/pi"
    --workdir /workspace
    --env HOME=/home/pi
    --env PI_SKIP_VERSION_CHECK=1
    --env "PI_DOCKER_UID=$(id -u)"
    --env "PI_DOCKER_GID=$(id -g)"
    --env "TERM=${TERM:-xterm-256color}"
)

# Shared mode (default) mounts the host's ~/.pi into the container's home, so
# host Pi and pi-docker use the same profile: auth.json, settings, models,
# sessions, extensions, and npm packages all live in one place. /login on
# either side updates the same credentials.
# Isolated mode keeps the old separate profile at $DATA_DIR/agent.
if ((ISOLATED)); then
    args+=(--mount "type=bind,source=$ISOLATED_AGENT_DIR,target=/pi-agent"
           --env PI_CODING_AGENT_DIR=/pi-agent)
else
    # Child mount comes after the parent so /home/pi/.pi lands on top of /home/pi.
    # Leave PI_CODING_AGENT_DIR unset: pi-ext-int-search must also be able to
    # discover the legacy ~/.pi/web-search.json used by the host/deployer.
    args+=(--mount "type=bind,source=$PI_DIR,target=/home/pi/.pi")
    # On macOS the container gets a private npm store overlaid on the shared
    # profile, so package installs inside the Linux container never touch the
    # host's ~/.pi/agent/npm (managed by native macOS Pi).
    if [[ $HOST_OS == Darwin ]]; then
        args+=(--mount "type=bind,source=$NPM_DIR,target=/home/pi/.pi/agent/npm")
    fi
fi

dns=''
if ((TAILNET)); then
    # Loopback resolvers work in the shared host network namespace. Preserve
    # split DNS by default, but honor the existing explicit DNS override.
    dns=$(host_network_dns)
    args+=(--network=host)
    if [[ -n $dns ]]; then
        args+=("--dns=$dns")
    elif [[ $HOST_OS == Linux ]]; then
        # Only mount the host resolver where the container truly shares the
        # host network namespace (Linux). Docker Desktop host networking runs
        # in the Desktop VM with its own resolver; --dns is the override there.
        args+=(--mount "type=bind,source=/etc/resolv.conf,target=/etc/resolv.conf,readonly")
    fi
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

if ((DOCTOR == 0)); then
    [[ -t 0 ]] && args+=(--interactive)
    [[ -t 0 && -t 1 ]] && args+=(--tty)
fi

# Pass only explicitly selected provider keys; do not forward the whole host environment.
# ${VAR:-} (not [[ -v $key ]]): macOS ships Bash 3.2, which has no -v.
for key in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY \
    GOOGLE_GENERATIVE_AI_API_KEY GROQ_API_KEY; do
    value=''
    case $key in
        ANTHROPIC_API_KEY) value=${ANTHROPIC_API_KEY:-} ;;
        OPENAI_API_KEY) value=${OPENAI_API_KEY:-} ;;
        GEMINI_API_KEY) value=${GEMINI_API_KEY:-} ;;
        GOOGLE_GENERATIVE_AI_API_KEY) value=${GOOGLE_GENERATIVE_AI_API_KEY:-} ;;
        GROQ_API_KEY) value=${GROQ_API_KEY:-} ;;
    esac
    if [[ -z $value ]]; then value=$(env_get "$key"); fi
    if [[ -n $value ]]; then args+=(--env "$key=$value"); fi
done

memory=${PI_DOCKER_MEMORY:-}
if [[ -z $memory ]]; then memory=$(env_get PI_DOCKER_MEMORY); fi
[[ -z $memory ]] || args+=(--memory "$memory")

cpus=${PI_DOCKER_CPUS:-}
if [[ -z $cpus ]]; then cpus=$(env_get PI_DOCKER_CPUS); fi
[[ -z $cpus ]] || args+=(--cpus "$cpus")

if ((DOCTOR)); then
    doctor || exit 1
    exit 0
fi
exec docker "${args[@]}" "$IMAGE" "$@"
LAUNCHER_CONTENT

# GNU sha256sum and BSD shasum both print the hex digest in field 1.
sha256_of() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | cut -d' ' -f1
    else
        shasum -a 256 "$file" | cut -d' ' -f1
    fi
}

check_file() {
    local destination=$1 candidate=$2 digest
    if [[ -e $destination || -L $destination ]]; then
        if [[ -L $destination ]]; then
            die "$destination is a symlink; replace it yourself before running the installer."
        fi
        if ! cmp -s "$destination" "$candidate" && [[ $FORCE -ne 1 ]]; then
            digest=$(sha256_of "$destination")
            # Exact v1 launcher can be upgraded while preserving customized copies.
            if [[ $destination == "$LAUNCHER" && $digest == 08ba0128ccd739be06daaa881a410bd43fa9c94219bad5386ad051552f4ec589 ]]; then
                return
            fi
            # Exact v2 launcher can be upgraded while preserving customized copies.
            if [[ $destination == "$LAUNCHER" && $digest == 6f53b50b526db4d3a081802589bf79552bf3790cd94a5eeed57a82395bc95044 ]]; then
                return
            fi
            # Exact v2.1 launcher can be upgraded while preserving customized copies.
            if [[ $destination == "$LAUNCHER" && $digest == a9e7d2070b44e7726229f87f2ca6de7a0286a4189196327f1b1c2cf758d73e57 ]]; then
                return
            fi
            # Exact v3 launcher can be upgraded while preserving customized copies.
            if [[ $destination == "$LAUNCHER" && $digest == 2d5091b3c014a0419851cba9b70536e2895cdde0c32dccfe9c0c816f67084cd3 ]]; then
                return
            fi
            # Exact v3.1 launcher from main can be upgraded without --force.
            if [[ $destination == "$LAUNCHER" && $digest == c142332f000547a9f4d2481a4ec99fd7a05cb14b164cb6e753fcc948f54aac69 ]]; then
                return
            fi
            # Exact v5 launcher from features can be upgraded without --force.
            if [[ $destination == "$LAUNCHER" && $digest == 29bd47c36a888ab461f29f9e0279c7e28f831eea89398bd0cc6f408ce2210f4a ]]; then
                return
            fi
            # Exact v4 launcher can be upgraded while preserving customized copies.
            if [[ $destination == "$LAUNCHER" && $digest == 3a1b1b4ab6087fad9e68e3cab6090e6d436f76be1cd62457bad3046c0c9de1dc ]]; then
                return
            fi
            # Exact v6 launcher (pre-macOS) can be upgraded without --force.
            if [[ $destination == "$LAUNCHER" && $digest == 27ad56bde8ce3b12c4b085ab0f054ba40ddf918d2836c7c5fd9f444220bc93a7 ]]; then
                return
            fi
            # Upgrade the exact Dockerfile shipped in image v3 automatically.
            if [[ $destination == "$DOCKERFILE" && $digest == a2b26fcc850ba65ec9605733153387dd4a40a644344638b7a0acc66080c1648c ]]; then
                return
            fi
            # Upgrade the exact v2 entrypoint (macOS useradd range warning fix).
            if [[ $destination == "$CONFIG_DIR/entrypoint.sh" && $digest == 402cd95012610958d510c08786707b1805b18eca4065d3c0b72a0560c42d54d6 ]]; then
                return
            fi
            # Upgrade the exact Dockerfile shipped in image v2 automatically.
            if [[ $destination == "$DOCKERFILE" && $digest == f7f6f0bda1d94a92441c04818d3775a24be01a6a9b80bec0a53a2c53642f02e0 ]]; then
                return
            fi
            # Upgrade the exact v1 entrypoint (fixes gosu resetting HOME).
            if [[ $destination == "$CONFIG_DIR/entrypoint.sh" && $digest == eaba06fe6c74a729b7c3a561582aee0ee9476ace1e4a80fb85d214e82f6c8f5c ]]; then
                return
            fi
            # Upgrade the exact Dockerfile shipped in image v1 automatically.
            if [[ $destination == "$DOCKERFILE" && $digest == 553a25e729d82e38f7883f345d8b1b0672f15aa1aa70397a49d4b691967de8a0 ]]; then
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
    if [[ $existing_label != "$IMAGE_VERSION" && $existing_label != 1 && $existing_label != 2 && $existing_label != 3 && $FORCE -ne 1 ]]; then
        die "Docker image $IMAGE is not managed by this installer; use --force to replace it."
    fi
fi

mkdir -p "$CONFIG_DIR" "$DATA_DIR/home" "$BIN_DIR" "$PI_DIR"
chmod 700 "$CONFIG_DIR" "$DATA_DIR" "$DATA_DIR/home" "$PI_DIR"
if [[ $HOST_OS == Darwin ]]; then
    mkdir -p "$NPM_DIR"
    chmod 700 "$NPM_DIR"
fi
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
    # Never upload saved URLs/API keys or unrelated files in CONFIG_DIR to
    # Docker/BuildKit. The scratch context contains only generated scripts.
    docker "${build_args[@]}" "$work_dir"
    docker run --rm --entrypoint sh "$IMAGE" -c 'command -v bwrap && command -v socat && command -v rg && command -v fd' \
        || die 'Image was built but a runtime dependency is missing.'
else
    printf 'Managed Docker image already installed: %s\n' "$IMAGE"
fi

if ! cmp -s "$work_dir/pi-docker" "$LAUNCHER"; then
    install -m 755 "$work_dir/pi-docker" "$LAUNCHER"
else
    chmod 755 "$LAUNCHER"
fi

"$LAUNCHER" --version || die 'Pi did not start; check the Docker build and runtime output above.'

# Pi packages live under the shared ~/.pi profile, not in the image.
# On macOS the shared profile's npm directory is overlaid by a container-local
# store ($NPM_DIR), so packages installed by native macOS Pi are never reused
# or clobbered by the Linux container.
# Skipping an installed package avoids network downloads on ordinary reruns.
if [[ $HOST_OS == Darwin ]]; then
    pkg_store="$NPM_DIR"
else
    pkg_store="$PI_DIR/agent/npm"
fi
for package in pi-permission-modes pi-ext-int-search; do
    if [[ -d $pkg_store/node_modules/$package ]]; then
        printf 'Pi package already installed: %s\n' "$package"
    else
        printf 'Installing Pi package: %s\n' "$package"
        ( cd "$CONFIG_DIR" && "$LAUNCHER" install "npm:$package" ) || die "Could not install $package. Rerun the installer to retry."
        if [[ ! -d $pkg_store/node_modules/$package ]]; then
            ( cd "$CONFIG_DIR" && "$LAUNCHER" update "npm:$package" ) || die "Could not reconcile $package. Rerun the installer to retry."
        fi
        [[ -d $pkg_store/node_modules/$package ]] || die "$package was not installed under the shared Pi profile. Check with pi-docker list and retry."
    fi
done

if [[ -f $PI_DIR/agent/settings.json ]] && grep -Fq 'npm:@oresk/pi-searxng' "$PI_DIR/agent/settings.json"; then
    printf 'Note: @oresk/pi-searxng also declares web_search; consider removing it if both tools conflict.\n' >&2
fi

printf '\nReady: %s\nRun `pi-docker` from a project directory (pi-docker --help lists options).\nCheck health anytime with: pi-docker doctor\n' "$LAUNCHER"
if [[ :$PATH: != *":$BIN_DIR:"* ]]; then
    printf 'Add %s to your PATH to use `pi-docker` by name.\n' "$BIN_DIR"
fi
