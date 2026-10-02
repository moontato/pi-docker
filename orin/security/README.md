# Dedicated Orin Docker policies (Docker Engine 29.8.0 on this Jetson)

Only `pi-docker --orin` and `--orin-profile` select these profiles. Ordinary Pi Docker launches still use Docker's defaults. The installer copies `seccomp-docker29-arm64.json` to `~/.config/pi-docker/orin-seccomp-docker29-arm64.json` (mode 600) and loads `apparmor.profile` as the host **named** `pi-docker-orin` profile. It never edits Docker's daemon settings or `docker-default`. Installation requires sudo for the AppArmor profile. The launcher fails closed if the pinned Docker Engine version or installed seccomp policy is missing; review/rederive these policies after an Engine upgrade.

## Provenance and changes

Docker Engine 29.8.0, server git commit `3ce5872` on this Orin. The seccomp file is the vendored default `vendor/github.com/moby/profiles/seccomp/default.json` at that commit (SHA256 `536529b665dd0972c37bfb569f5d4ac8a53592e7b00752bc39ff063ca9864c74`) plus six explicit syscall rules. The AppArmor profile follows the Engine's vendored `vendor/github.com/moby/profiles/apparmor/template.go` at the same commit. It retains the default proc/sysfs and network denies.

For processes **without** `CAP_SYS_ADMIN` (normal Orin mode), the seccomp delta allows:
- `clone` only with namespace bits exactly `CLONE_NEWUSER|CLONE_NEWNS|CLONE_NEWPID|CLONE_NEWNET` (not other namespace bits; aarch64 `clone` argument 0). This is the observed bubblewrap invocation.
- `unshare` only with `CLONE_NEWUSER` (bubblewrap) or `CLONE_NEWNS|CLONE_NEWPID` (sandbox-runtime's apply-seccomp helper).
- `mount` (any arguments), `umount2` (any arguments), and `pivot_root` (any arguments). Linux still requires `CAP_SYS_ADMIN` in an owning user namespace for these operations. `clone3` remains denied as in Docker's default.

The AppArmor delta adds `userns`, `mount` (all targets/types/options) and `pivot_root` (all targets). **These mount/pivot permissions are broad within these Orin containers**, not limited to bubblewrap; normal mode has no host `SYS_ADMIN` but processes can use them after creating an unprivileged user namespace. Profile mode already has `SYS_ADMIN` for profiling, so its mount permission is broader. Docker's other isolation and the Pi permission extension stay enabled. This is not `seccomp=unconfined`, `apparmor=unconfined`, `--privileged`, or a change to host user-namespace sysctls.

The Orin image's `/usr/local/bin/bwrap` delegates to `/usr/bin/bwrap`, inserting binds for the enumerated GPU devices *after* sandbox-runtime's `--dev /dev` (which otherwise masks GPU devices). It does not expose the entire outer `/dev` or add devices to the outer container. The list includes the GPU's `/dev/nvgpu/igpu0/{as,channel,ctrl,nvsched,power,sched,tsg}`, `/dev/dri/renderD128`, the listed NVIDIA legacy nodes and `/dev/nvmap`. Nsight's profiling/debug device nodes are **not** passed through in normal mode.

## Install and rollback

From this repository: `./install-pi-docker.sh --install-orin` (use `--force` only to replace a previously modified installed launcher deliberately). To revert *these policies*: stop Orin sessions, rerun the prior installer commit to restore the previous launcher/image or remove the Orin image and installed launcher intentionally; then:

```bash
sudo apparmor_parser -R /etc/apparmor.d/pi-docker-orin
sudo rm /etc/apparmor.d/pi-docker-orin
rm ~/.config/pi-docker/orin-seccomp-docker29-arm64.json
```

Do not remove the profile while Orin containers are running. Removing it does not change Docker's default security profile or the existing containerd migration to `/mnt/ssd/containerd`. The launcher requires the named profile and seccomp file, so Orin launches fail if either is removed.

## Profiling boundary (not yet accepted)

Nsight Compute 2026.1.1 `--mode launch` (non-root CUDA target) + `--mode attach` (root collector) **attaches but cannot collect** `sm__cycles_active.avg`: the driver rejects performance-counter access for the **non-root target** even when the collector is root. This also fails without bubblewrap. `sudo ncu` inside bubblewrap cannot elevate because the sandbox sets `no_new_privs`. No privileged helper has been installed. A future solution requires separate approval to relax host-wide counter restrictions or elevate the CUDA target, both outside the currently approved boundary.
