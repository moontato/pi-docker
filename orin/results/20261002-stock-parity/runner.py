#!/usr/bin/env python3
"""Fixed stock benchmark: normal Pi bubblewrap only; no profiling/elevation."""
import datetime, json, os, pathlib, shlex, subprocess, sys
base=pathlib.Path('/workspace/.worktrees/container-baseline')
status=pathlib.Path('/proc/self/status').read_text()
if os.geteuid()==0 or 'NoNewPrivs:\t1' not in status:
    sys.exit('Refusing benchmark: require non-root tool with no_new_privs')
mem=pathlib.Path('/proc/meminfo').read_text()
available=int(next(line.split()[1] for line in mem.splitlines() if line.startswith('MemAvailable:')))
if available < 25*1024*1024:
    sys.exit(f'Refusing benchmark: available physical memory {available/1024/1024:.2f} GiB is below 25 GiB')
if os.environ.get('PI_DOCKER_ORIN_PROFILE','0')=='1':
    sys.exit('Refusing benchmark: profile mode selected')
for k,v in os.environ.items():
    if k.startswith('GGML_CUDA_FORCE') and v not in ('','0'):
        sys.exit(f'Refusing benchmark: nonstock {k} is set')
out=base/'build-container'/'parity-results'/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
out.mkdir(parents=True, exist_ok=False)
cmd=[str(base/'build-container/bin/llama-bench'),'-m','/models/Qwen3.8-27B-UD-Q4_K_XL.gguf','-p','4096','-n','0','-b','2048','-ub','512','-ngl','999','-fa','on','-ctk','f16','-ctv','f16','-r','7','-o','json','-oe','md']
(out/'command.txt').write_text(shlex.join(cmd)+'\n')
(out/'tool-status.txt').write_text('\n'.join(line for line in status.splitlines() if line.startswith(('Uid:','Gid:','NSpid:','Cap','NoNewPrivs:','Seccomp:')))+'\n')
(out/'meminfo-before.txt').write_text(mem)
(out/'environment.json').write_text(json.dumps({k:v for k,v in os.environ.items() if k.startswith(('GGML_','CUDA_','CUDAToolkit_','PI_DOCKER_ORIN')) or k in ('LD_LIBRARY_PATH','OMP_NUM_THREADS')},indent=2)+'\n')
print('RESULT DIRECTORY:',out,flush=True)
print('COMMAND:',shlex.join(cmd),flush=True)
print('AVAILABLE MEMORY GiB:',round(available/1024/1024,2),flush=True)
print((out/'tool-status.txt').read_text(),flush=True)
with (out/'benchmark.json').open('w') as stdout, (out/'benchmark.stderr').open('w') as stderr:
    r=subprocess.run(cmd,cwd=base,stdout=stdout,stderr=stderr)
(out/'exit-code.txt').write_text(str(r.returncode)+'\n')
(out/'meminfo-after.txt').write_text(pathlib.Path('/proc/meminfo').read_text())
print('BENCHMARK EXIT CODE:',r.returncode,flush=True)
print('BENCHMARK STDOUT:',(out/'benchmark.json').read_text(),flush=True)
print('BENCHMARK STDERR:',(out/'benchmark.stderr').read_text(),flush=True)
sys.exit(r.returncode)
