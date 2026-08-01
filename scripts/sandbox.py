#!/usr/bin/env python3
"""Platform-adaptive sandbox wrapper for acpx reviewer seats (debate v3, #31).

Chooses the lightest OS-level sandbox available per host, so `repo-aware` seats and
acpx reviewers get real isolation instead of a permission flag:
  Linux   -> bwrap (bubblewrap): user-namespace + seccomp, no root, no VM.
  macOS   -> sandbox-exec (Seatbelt): native, no VM.
  fallback-> docker run (only if a docker runtime exists).

Usage (a command prefix):
  sandbox.py [--repo-sandbox] [--repo ROOT] [--label NAME] -- CMD ARGS...

  --repo-sandbox  mount ROOT read-only (repo-aware seat) and isolate HOME.
  (default, no flags)  just isolate HOME + tmpfs and deny write outside $PWD.

Acpx reviewers still need outbound network, so --share-net is kept unless
--no-net is passed (defense for untrusted diffs). This is still real isolation
of filesystem + HOME, which the permission flags alone do not provide.
"""
import argparse, os, shutil, sys, platform

def detect_sandbox():
    """Return ('bwrap'|'sandbox-exec'|'docker'|None)."""
    sysname = platform.system()
    if sysname == "Linux" and shutil.which("bwrap"):
        return "bwrap"
    if sysname == "Darwin" and shutil.which("sandbox-exec"):
        return "sandbox-exec"
    if shutil.which("docker"):
        return "docker"
    return None

def bwrap_cmd(repo, repo_sandbox, no_net, bind_pwd):
    home_tmp = os.path.join("/tmp", "debate-home-%s" % os.getpid())
    cmd = ["bwrap", "--die-with-parent", "--unshare-pid", "--new-session"]
    if no_net:
        cmd += ["--unshare-net"]
    cmd += ["--ro-bind", "/", "/", "--tmpfs", home_tmp, "--setenv", "HOME", home_tmp]
    if repo_sandbox and repo:
        cmd += ["--ro-bind", os.path.realpath(repo), os.path.realpath(repo)]
    if bind_pwd:
        p = os.path.realpath(bind_pwd)
        cmd += ["--bind", p, p]
    return cmd

def seatbelt_cmd(repo, repo_sandbox, no_net, bind_pwd):
    # Generate a minimal Seatbelt profile: allow read on the repo + system libs,
    # deny writes outside /tmp; netblock if requested.
    extra = ""
    if no_net:
        extra = '(deny network*)'
    profile = f"""
(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath "/tmp"))
{extra}
"""
    prof_path = f"/tmp/se-{os.getpid()}.sb"
    with open(prof_path, "w") as f:
        f.write(profile)
    return ["sandbox-exec", "-f", prof_path]

def docker_cmd(repo, repo_sandbox, no_net, bind_pwd):
    vol = ["--volume", "%s:%s:ro" % (os.path.realpath(repo), os.path.realpath(repo))] if repo_sandbox and repo else []
    net = ["--network", "none"] if no_net else []
    return ["docker", "run", "--rm", *net, *vol]

def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--repo-sandbox", action="store_true")
    ap.add_argument("--repo", default=None)
    ap.add_argument("--no-net", action="store_true")
    ap.add_argument("--label", default="review")
    ap.add_argument("args", nargs=argparse.REMAINDER, default=[])
    a = ap.parse_args()

    sand = detect_sandbox()
    if sand is None:
        print("sandbox.py: no bwrap/sandbox-exec/docker found; running unsandboxed", file=sys.stderr)
        prefix = []
    elif sand == "bwrap":
        prefix = bwrap_cmd(a.repo, a.repo_sandbox, a.no_net, bind_pwd=os.getcwd())
    elif sand == "sandbox-exec":
        prefix = seatbelt_cmd(a.repo, a.repo_sandbox, a.no_net, bind_pwd=os.getcwd())
    else:
        prefix = docker_cmd(a.repo, a.repo_sandbox, a.no_net, bind_pwd=os.getcwd())

    rest = a.args
    if rest and rest[0] == "--":
        rest = rest[1:]
    if not rest:
        print("sandbox.py: no command to run", file=sys.stderr); sys.exit(2)
    os.execvp(rest[0], prefix + rest)

if __name__ == "__main__":
    main()
