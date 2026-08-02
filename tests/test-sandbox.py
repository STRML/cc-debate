#!/usr/bin/env python3
"""Unit tests for scripts/sandbox.py (debate v3, #31).

Covers the command-builders AND main()'s exec path — the execvp ordering bug
(report: real-host verification, macOS) sailed through the builder-only suite,
so main() itself is tested here with os.execvp captured.
"""
import importlib.util, json, os, sys, tempfile
_here = os.path.dirname(os.path.abspath(__file__))
_src = os.path.join(_here, "..", "scripts", "sandbox.py")
_spec = importlib.util.spec_from_file_location("sandbox_mod", _src)
sb = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(sb)

fails = 0
def check(name, cond, detail=""):
    global fails
    if cond: print("  ok:", name)
    else: fails += 1; print("  FAIL:", name, detail)

# --- builders ----------------------------------------------------------------

c = sb.bwrap_cmd("/repo", True, False, "/work")
check("bwrap mounts repo read-only", "--ro-bind" in c and "/repo" in c)
check("bwrap isolates HOME", "--setenv" in c and "HOME" in c)
check("bwrap keeps net by default", "--unshare-net" not in c)
c2 = sb.bwrap_cmd("/repo", True, True, "/work")
check("bwrap --no-net adds unshare-net", "--unshare-net" in c2)
check("bwrap: NO writable bind of cwd (auditor finding)", "--bind" not in c2)
check("bwrap: runner scratch is a tmpfs", c2.count("--tmpfs") >= 2, str(c2))

# Seatbelt: RESOLVED temp path (macOS /tmp -> /private/tmp), 0600 profile, no_net rule
_tmpdir = os.path.realpath(tempfile.gettempdir())          # per-host resolved
_work = tempfile.mkdtemp(prefix="sb-work-")                 # real cwd for scratch
c3 = sb.seatbelt_cmd("/repo", True, True, _work)
prof = open(c3[c3.index("-f")+1]).read()
mode = os.stat(c3[c3.index("-f")+1]).st_mode & 0o777
check("seatbelt uses RESOLVED tmp path (macOS: /private/tmp)", ('subpath "%s"' % _tmpdir) in prof, prof)
check("seatbelt denies writes outside tmp+scratch", "(deny file-write*)" in prof and ('allow file-write* (subpath "%s")' % _tmpdir) in prof)
check("seatbelt denies network when --no-net", "(deny network*)" in prof)
check("seatbelt profile is 0600", mode == 0o600, oct(mode))
check("seatbelt redirects HOME via env prefix", "env" in c3 and c3[c3.index("env")+1].startswith("HOME="), str(c3))

d = sb.docker_cmd("/repo", True, True, "/work", "debian:bookworm-slim")
check("docker has an image after flags (no-image bug)", d[-1] == "debian:bookworm-slim" and "docker" == d[0], str(d))
check("docker mounts repo ro + no net", "--network" in d and "none" in d)

# scratch dir created for the runner
scratch = sb.scratch_dir("/tmp")
check("scratch_dir exists", os.path.isdir(scratch), scratch)

# --- main(): the exec path ---------------------------------------------------

def run_main(backend, extra_args, cmd):
    captured = {}
    def fake_execvp(prog, argv):
        captured["prog"] = prog; captured["argv"] = list(argv)
        raise SystemExit(0)
    old_exec, old_detect, old_argv = sb.os.execvp, sb.detect_sandbox, sys.argv
    sb.os.execvp = fake_execvp
    sb.detect_sandbox = lambda: backend
    sys.argv = ["sandbox.py"] + extra_args + ["--"] + cmd
    try:
        sb.main()
    except SystemExit:
        pass
    sb.os.execvp, sb.detect_sandbox, sys.argv = old_exec, old_detect, old_argv
    return captured

# The regression: execvp's program must be the SANDBOX binary (prefix first),
# with the wrapped command as its arguments — not the other way round.
cap = run_main("sandbox-exec", [], ["bash", "-c", "true"])
check("exec: program is the sandbox binary (not the wrapped cmd)", cap.get("prog") == "sandbox-exec", cap.get("prog"))
check("exec: prefix precedes wrapped command", cap.get("argv", [])[-3:] == ["bash", "-c", "true"], cap.get("argv"))
check("exec: sandbox binary is argv[0]", cap.get("argv", [None])[0] == "sandbox-exec", cap.get("argv"))

cap = run_main("bwrap", ["--repo-sandbox", "--repo", "/r"], ["sh", "-c", "true"])
check("exec(bwrap): program is bwrap", cap.get("prog") == "bwrap", cap.get("prog"))
check("exec(bwrap): cmd after prefix", cap.get("argv", [])[-3:] == ["sh", "-c", "true"])

cap = run_main("docker", ["--no-net"], ["true"])
check("exec(docker): program is docker", cap.get("prog") == "docker", cap.get("prog"))
check("exec(docker): image precedes cmd", cap.get("argv", [])[-2:] == ["debian:bookworm-slim", "true"], cap.get("argv"))

cap = run_main(None, [], ["echo", "hi"])   # no sandbox -> run unsandboxed
check("exec(no sandbox): argv is just the cmd", cap.get("argv") == ["echo", "hi"], cap.get("argv"))

print()
print("PASS" if fails == 0 else f"FAIL ({fails})")
sys.exit(0 if fails == 0 else 1)
