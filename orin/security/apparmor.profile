# Dedicated to pi-docker --orin / --orin-profile; do NOT replace docker-default.
# Derived from Moby Engine 29.8.0 (3ce5872), vendor/github.com/moby/profiles/apparmor/template.go.
# Relative to Docker's template: allow userns, mount and pivot_root. Mount is
# a BROAD AppArmor permission (all mount types and targets inside this profile),
# still subject to Linux capabilities, Docker's seccomp policy, and namespaces.
abi <abi/3.0>,
#include <tunables/global>

profile "pi-docker-orin" flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  network,
  deny network alg,
  deny network vsock,
  capability,
  file,
  umount,
  signal (receive) peer=unconfined,
  signal (receive) peer=runc,
  signal (receive) peer=crun,
  signal (receive) peer="unconfined",
  signal (send,receive) peer="pi-docker-orin",

  deny @{PROC}/* w,
  deny @{PROC}/{[^1-9/],[^1-9/][^0-9/],[^1-9s/][^0-9y/][^0-9s/],[^1-9/][^0-9/][^0-9/]*}/** w,
  deny @{PROC}/sys/[^k]** w,
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  userns,
  mount,
  pivot_root,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,
  ptrace (trace,tracedby,read,readby) peer="pi-docker-orin",
}
