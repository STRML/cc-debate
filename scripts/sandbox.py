#!/usr/bin/env python3
"""Platform-adaptive sandbox wrapper for acpx reviewer seats (debate v3, #31).

Chooses the lightest OS-level sandbox available per host, so `repo-aware` seats and
acpx reviewers get real isolation instead of a permission flag:
  Linux   -> bwrap (bubblewrap): user-namespace + seccomp, no root, no VM.
  macOS   -> sandbox-exec (Seatbelt): native, no VM.
  fallback-> docker run (only if a docker runtime exists).

Usage (a command prefix):
  sandbox.py [--repo-sandbox] [--repo ROOT] [--no-net] [--image IMAGE] -- CMD ARGS...

  --repo-sandbox  the repo is mounted read-only (repo-aware seat); HOME is
                  redirected to a throwaway dir; the only writable places are
                  the OS temp dir and <cwd>/.tmp (the runner's scratch).
  (default)       HOME isolated + writes confined to temp + <cwd>/.tmp.
  --no-net        deny network (defense for untrusted diffs; acpx seats need
                  network, so this is opt-in).
  --image IMAGE   docker fallback image (default debian:bookworm-slim).

Honest scope: this is WRITE isolation + HOME redirection, not read isolation.
On every backend the host filesystem stays readable (bwrap --ro-bind / /, Seatbelt
(allow default), docker ro-mounts) — the same residual risk the old codex-exec
README section documented. An absolute path read still works; a write outside
temp/<cwd>/.tmp and a HOME that resolves somewhere useful do not.
"""
import argparse, os, shutil, sys, platform, tempfile

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

def _bwrap_supports(feature):
    """True if this bwrap build accepts the given long option (older builds vary)."""
    try:
        import subprocess
        out = subprocess.run(["bwrap", "--help"], capture_output=True, text=True, timeout=5)
        return feature in (out.stdout + out.stderr)
    except Exception:
        return False  # can't tell; be conservative and drop non-essential flags

def scratch_dir(cwd):
    """The runner's writable scratch: <cwd>/.tmp (created)."""
    d = os.path.realpath(os.path.join(cwd, ".tmp"))
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass  # bwrap --tmpfs will hide whatever is there anyway
    return d

def resolved_tmp():
    """macOS /tmp -> /private/tmp, and Seatbelt matches resolved paths."""
    return os.path.realpath(tempfile.gettempdir())

def bwrap_cmd(repo, repo_sandbox, no_net, bind_pwd):
    home_tmp = os.path.join("/tmp", "debate-home-%s" % os.getpid())
    cmd = ["bwrap"]
    if _bwrap_supports("die-with-parent"):
        cmd.append("--die-with-parent")
    cmd += ["--unshare-pid", "--new-session"]
    if no_net:
        cmd += ["--unshare-net"]
    # Host ro, HOME + /tmp fresh tmpfs, runner scratch tmpfs at <cwd>/.tmp.
    cmd += ["--ro-bind", "/", "/", "--tmpfs", "/tmp", "--setenv", "TMPDIR", "/tmp"]
    cmd += ["--tmpfs", home_tmp, "--setenv", "HOME", home_tmp]
    if repo_sandbox and repo:
        cmd += ["--ro-bind", os.path.realpath(repo), os.path.realpath(repo)]
    cmd += ["--tmpfs", scratch_dir(bind_pwd)]
    return cmd

def seatbelt_cmd(repo, repo_sandbox, no_net, bind_pwd):
    # Seatbelt matches RESOLVED paths: /tmp is a symlink to /private/tmp on macOS,
    # so a (subpath "/tmp") rule never fires. Use realpath everywhere.
    tmp = resolved_tmp()
    scratch = scratch_dir(bind_pwd)
    home_tmp = os.path.join(tmp, "debate-home-%s" % os.getpid())
    os.makedirs(home_tmp, exist_ok=True)

    rules = ["(deny file-write*)",
             '(allow file-write* (subpath "%s"))' % tmp,
             '(allow file-write* (subpath "%s"))' % scratch]
    if no_net:
        rules.append("(deny network*)")
    profile = "(version 1)\n(allow default)\n" + "\n".join(rules) + "\n"

    # 0600 + random name in the user tmpdir: predictable /tmp/se-<pid>.sb with
    # default perms was both a leak and a collision. It is left behind (the
    # exec'd process can't clean it up) but is unreadable by other accounts.
    fd, prof_path = tempfile.mkstemp(prefix="se-", suffix=".sb", dir=tmp)
    os.write(fd, profile.encode())
    os.close(fd)
    os.chmod(prof_path, 0o600)

    # HOME redirection must happen inside the sandbox: prefix env before the cmd.
    return ["sandbox-exec", "-f", prof_path, "env",
            "HOME=%s" % home_tmp, "TMPDIR=%s" % tmp]

def docker_cmd(repo, repo_sandbox, no_net, bind_pwd, image):
    vol = ["--volume", "%s:%s:ro" % (os.path.realpath(repo), os.path.realpath(repo))] if repo_sandbox and repo else []
    net = ["--network", "none"] if no_net else []
    return ["docker", "run", "--rm", *net, *vol, image]

def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--repo-sandbox", action="store_true")
    ap.add_argument("--repo", default=None)
    ap.add_argument("--no-net", action="store_true")
    ap.add_argument("--image", default="debian:bookworm-slim")
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
        prefix = docker_cmd(a.repo, a.repo_sandbox, a.no_net, bind_pwd=os.getcwd(), image=a.image)

    rest = a.args
    if rest and rest[0] == "--":
        rest = rest[1:]
    if not rest:
        print("sandbox.py: no command to run", file=sys.stderr); sys.exit(2)
    # execvp's FIRST argument names the program; prefix must come first, then the
    # wrapped command as its arguments. (Regression: rest[0] was passed as the
    # program, so the sandbox binary never launched and its flags went to the
    # wrapped command.)
    argv = prefix + rest
    os.execvp(argv[0], argv)

if __name__ == "__main__":
    main()
