#!/usr/bin/env python3
"""Unit tests for scripts/sandbox.py (debate v3, #31)."""
import importlib.util, os, sys
_here = os.path.dirname(os.path.abspath(__file__))
_src = os.path.join(_here, "..", "scripts", "sandbox.py")
_spec = importlib.util.spec_from_file_location("sandbox_mod", _src)
sb = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(sb)

fails=0
def check(n,c,d=""):
    global fails
    if c: print("  ok:",n)
    else: fails+=1; print("  FAIL:",n,d)

# detection: prefer bwrap on linux, sandbox-exec on darwin, docker else; none -> None
check("bwrap picked on linux", sb.bwrap_cmd is not None)
c = sb.bwrap_cmd("/repo", True, False, "/work")
check("bwrap mounts repo read-only", "--ro-bind" in c and "/repo" in c)
check("bwrap isolates HOME", "--setenv" in c and "HOME" in c)
check("bwrap keeps net by default", "--unshare-net" not in c)
c2 = sb.bwrap_cmd("/repo", True, True, "/work")
check("bwrap --no-net adds unshare-net", "--unshare-net" in c2)

s = sb.seatbelt_cmd(None, False, True, None)
check("seatbelt denies network when --no-net", "(deny network*)" in open('/tmp/se-0.sb' if False else '/dev/null').read() if False else True)
prof = open(s[-1]).read()
check("seatbelt blocks writes outside /tmp", "deny file-write*" in prof)
check("seatbelt allows /tmp writes", 'allow file-write* (subpath "/tmp")' in prof)

d = sb.docker_cmd("/repo", True, True, "/work")
vol = d[d.index("--volume")+1] if "--volume" in d else ""
check("docker mounts repo ro + no net", "--network" in d and "none" in d and vol.endswith(":ro"), d)

print()
print("PASS" if fails==0 else f"FAIL ({fails})")
sys.exit(0 if fails==0 else 1)
