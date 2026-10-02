#!/usr/bin/env bash
# Called only by install-pi-docker.sh --install-orin. No daemon defaults changed.
set -Eeuo pipefail
config_dir=${1:?pass the pi-docker config directory}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $(uname -m) == aarch64 ]] || { echo 'Orin policies require aarch64' >&2; exit 1; }
[[ $(docker version --format '{{.Server.Version}}') == 29.8.0 ]] || {
    echo 'Orin seccomp/AppArmor profiles were derived from Docker Engine 29.8.0; review them for this engine before installation.' >&2
    exit 1
}
[[ -d $config_dir && ! -L $config_dir ]] || { echo 'Invalid pi-docker config directory' >&2; exit 1; }
policy="$config_dir/orin-seccomp-docker29-arm64.json"
[[ ! -L $policy ]] || { echo 'Refusing to replace a symlinked seccomp policy' >&2; exit 1; }
install -m 600 "$script_dir/security/seccomp-docker29-arm64.json" "$policy"
# AppArmor is system-wide infrastructure, but this named profile is NOT
# docker-default: only explicit --security-opt apparmor=pi-docker-orin uses it.
sudo install -m 644 "$script_dir/security/apparmor.profile" /etc/apparmor.d/pi-docker-orin
sudo apparmor_parser -r /etc/apparmor.d/pi-docker-orin
printf 'Installed dedicated Orin seccomp and AppArmor profiles (Docker defaults unchanged).\n'
