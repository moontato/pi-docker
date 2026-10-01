#!/usr/bin/env bash
# Sync the canonical files beside this script to host Pi, pi-docker, or both.
set -Eeuo pipefail

VERSION=2.1.0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_AGENT="${XDG_DATA_HOME:-$HOME/.local/share}/pi-docker/agent"
TARGET=host
YES=0
INSTALL_PACKAGES=0
CHECK=0
RESTORE=0

usage() {
    cat <<'USAGE'
Usage: ./setup-pi-config.sh [--target host|docker|both] [--yes] [--install-packages]

  --target host      Sync ~/.pi (the original behavior; default).
  --target docker    Sync the separate pi-docker agent directory.
  --target both      Sync both profiles.
  --check            Report drift without changing anything (exit 1 if drift).
  --restore          Restore target files from their .bak backups.
  --yes              Apply the previewed changes and make .bak backups without prompting.
  --install-packages Install missing Pi packages in the docker profile after syncing.

Run from the extracted pi_configs directory. Files already in place are untouched.
USAGE
}

die() { printf 'Pi config sync: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case "$1" in
        --target) (($# >= 2)) || die '--target needs host, docker, or both.'; TARGET=$2; shift ;;
        --yes) YES=1 ;;
        --install-packages) INSTALL_PACKAGES=1 ;;
        --check) CHECK=1 ;;
        --restore) RESTORE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

case "$TARGET" in host|docker|both) ;; *) die "Invalid target: $TARGET" ;; esac
if ((CHECK)) && ((RESTORE)); then
    die '--check and --restore are mutually exclusive.'
fi
if ((INSTALL_PACKAGES)) && [[ $TARGET == host ]]; then
    die '--install-packages requires --target docker or --target both.'
fi

declare -a SOURCES=() DESTINATIONS=() STATUSES=()
add_mapping() { SOURCES+=("$SCRIPT_DIR/$1"); DESTINATIONS+=("$2"); }

if [[ $TARGET == host || $TARGET == both ]]; then
    add_mapping models.json "$HOME/.pi/agent/models.json"
    add_mapping settings.json "$HOME/.pi/agent/settings.json"
    add_mapping permission-mode.json "$HOME/.pi/agent/permission-mode/permission-mode.json"
    add_mapping friendly-model-footer.ts "$HOME/.pi/agent/extensions/friendly-model-footer.ts"
    add_mapping web-search.json "$HOME/.pi/web-search.json"
fi

if [[ $TARGET == docker || $TARGET == both ]]; then
    add_mapping models.json "$DOCKER_AGENT/models.json"
    add_mapping settings.json "$DOCKER_AGENT/settings.json"
    add_mapping permission-mode.json "$DOCKER_AGENT/permission-mode/permission-mode.json"
    add_mapping friendly-model-footer.ts "$DOCKER_AGENT/extensions/friendly-model-footer.ts"
    # pi-ext-int-search resolves this path via PI_CODING_AGENT_DIR=/pi-agent.
    add_mapping web-search.json "$DOCKER_AGENT/web-search.json"
fi

printf '\nPi Config Deployer v%s — target: %s\n\n' "$VERSION" "$TARGET"
for ((i=0; i<${#SOURCES[@]}; i++)); do
    src=${SOURCES[$i]}
    dst=${DESTINATIONS[$i]}
    [[ -f $src ]] || die "Missing archive file: $src"
    [[ ! -L $dst ]] || die "Destination is a symlink; resolve it manually: $dst"
    if [[ ! -e $dst ]]; then
        STATUSES+=(NEW)
        printf '[COPY] %s\n' "$dst"
    elif cmp -s "$src" "$dst"; then
        STATUSES+=(OK)
        printf '[UP-TO-DATE] %s\n' "$dst"
    else
        STATUSES+=(DIFF)
        printf '[OVERWRITE] %s\n' "$dst"
        diff -u --label "existing: $dst" --label "archive: $(basename "$src")" "$dst" "$src" || [[ $? -eq 1 ]]
    fi
done

if ((CHECK)); then
    drift=0
    for status in "${STATUSES[@]}"; do
        if [[ $status != OK ]]; then drift=$((drift+1)); fi
    done
    if ((drift)); then
        printf '\nDrift detected: %d file(s) need syncing.\n' "$drift"
        exit 1
    fi
    printf '\nIn sync: nothing to do.\n'
    exit 0
fi

if ((RESTORE)); then
    restorable=()
    for ((i=0; i<${#SOURCES[@]}; i++)); do
        if [[ -f ${DESTINATIONS[$i]}.bak ]]; then
            restorable+=("${DESTINATIONS[$i]}")
        fi
    done
    if (( ${#restorable[@]} == 0 )); then
        printf 'Nothing to restore (no .bak backups for target %s).\n' "$TARGET"
        exit 0
    fi
    printf '\nRestoring from backups:\n'
    for dst in "${restorable[@]}"; do printf '  %s\n' "$dst"; done
    if (( ! YES )); then
        read -r -p 'Restore these files? [y/N] ' reply || reply=''
        case "$reply" in [Yy]|[Yy][Ee][S]) ;; *) printf 'Aborted.\n'; exit 0 ;; esac
    fi
    for dst in "${restorable[@]}"; do
        cp -- "$dst.bak" "$dst"
        rm -f "$dst.bak"
        printf '[RESTORED] %s\n' "$dst"
    done
    printf '\nRestore complete.\n'
    exit 0
fi

BACKUP=1
if (( ! YES )); then
    read -r -p 'Back up changed files as .bak? [Y/n] ' reply || reply=''
    case "$reply" in [Nn]|[Nn][Oo]) BACKUP=0 ;; esac
    read -r -p 'Apply these changes? [y/N] ' reply || reply=''
    case "$reply" in [Yy]|[Yy][Ee][Ss]) ;; *) printf 'Aborted.\n'; exit 0 ;; esac
fi

for ((i=0; i<${#SOURCES[@]}; i++)); do
    src=${SOURCES[$i]}
    dst=${DESTINATIONS[$i]}
    [[ ${STATUSES[$i]} != OK ]] || continue
    mkdir -p "$(dirname "$dst")"
    if [[ ${STATUSES[$i]} == DIFF && $BACKUP -eq 1 ]]; then
        cp -p -- "$dst" "$dst.bak"
    fi
    cp -- "$src" "$dst"
    printf '[SYNCED] %s\n' "$dst"
done

if ((INSTALL_PACKAGES)); then
    command -v pi-docker >/dev/null || die 'pi-docker is not on PATH; install it before syncing packages.'
    for package in pi-permission-modes pi-ext-int-search; do
        if [[ -d $DOCKER_AGENT/npm/node_modules/$package ]]; then
            printf '[INSTALLED] %s\n' "$package"
        else
            printf '[INSTALLING] %s\n' "$package"
            ( cd "$SCRIPT_DIR" && pi-docker install "npm:$package" ) || die "Failed to install $package. Rerun with --install-packages to retry."
            if [[ ! -d $DOCKER_AGENT/npm/node_modules/$package ]]; then
                ( cd "$SCRIPT_DIR" && pi-docker update "npm:$package" ) || die "Failed to reconcile $package. Rerun with --install-packages to retry."
            fi
            [[ -d $DOCKER_AGENT/npm/node_modules/$package ]] || die "$package was not installed under the pi-docker agent directory. Check with pi-docker list and retry."
        fi
    done
fi

printf '\nSync complete.\n'
