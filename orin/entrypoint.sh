#!/bin/sh
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
# NVIDIA Jetson devices can be owned by video/render rather than world-readable.
# Transfer only the host groups that own GPU devices, not every host group.
for gid in ${PI_DOCKER_GPU_GIDS:-}; do
    case "$gid" in *[!0-9]*|'') echo 'Invalid GPU group ID' >&2; exit 1 ;; esac
    if ! getent group "$gid" >/dev/null; then
        groupadd --gid "$gid" "gpu-$gid"
    fi
    group_name=$(getent group "$gid" | cut -d: -f1)
    usermod -aG "$group_name" "$(getent passwd "$PI_DOCKER_UID" | cut -d: -f1)"
done
if [ "${PI_DOCKER_ORIN_VALIDATE:-}" = 1 ]; then
    exec gosu "$PI_DOCKER_UID" /usr/local/bin/pi-docker-orin-validate
fi
exec gosu "$PI_DOCKER_UID" pi "$@"
