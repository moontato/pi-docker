#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$repo" <<'PY'
import json, pathlib, sys
repo=pathlib.Path(sys.argv[1]);p=json.loads((repo/'orin/security/seccomp-docker29-arm64.json').read_text())
rules={r.get('comment'):r for r in p['syscalls'] if r.get('comment') and ('bubblewrap' in r['comment'] or 'bwrap' in r['comment'] or 'apply-seccomp helper' in r['comment'])}
assert p['defaultAction']=='SCMP_ACT_ERRNO'
assert len(rules)==6, rules.keys()
for r in rules.values():assert r['action']=='SCMP_ACT_ALLOW'
assert any(r['names']==['clone'] and r['args'][0]['value']==0x7e020000 and r['args'][0]['valueTwo']==0x70020000 for r in rules.values())
assert {r['args'][0]['value'] for r in rules.values() if r['names']==['unshare']}=={0x10000000,0x20020000}
assert {'mount','umount2','pivot_root'}=={r['names'][0] for r in rules.values() if r['names'][0] in ('mount','umount2','pivot_root')}
apparmor=(repo/'orin/security/apparmor.profile').read_text()
assert 'profile "pi-docker-orin"' in apparmor
assert '  userns,' in apparmor and '  mount,' in apparmor and '  pivot_root,' in apparmor
assert 'unconfined' not in apparmor.split('profile "pi-docker-orin"',1)[0]
wrapper=(repo/'orin/bwrap-gpu.sh').read_text()
assert '--dev-bind "$node" "$node"' in wrapper and 'for node in /dev/nvidia0' in wrapper
assert '--dev-bind /dev /dev' not in wrapper
print('Orin policy shape checks passed')
PY
