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

Session-mode seats don't work in here: auth_env() routes acpx/codex at their real
~/.acpx and ~/.codex, which every backend keeps read-only, so `acpx <agent> sessions
ensure` (session persistence) is denied and the seat fails with exit 4. Sandboxed
seats must be one-shot (`"mode": "exec"`), which skips session persistence entirely.
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
    """The runner's writable scratch: <git-top>/.tmp (or <cwd>/.tmp outside a repo).

    run-parallel-acpx.sh resolves its WORK_DIR from `git rev-parse --show-toplevel`,
    deliberately independent of the invocation directory. The sandbox's writable scope
    must track the same root, or a review launched from a repo subdirectory writes its
    outputs (and the seats' exit files) outside the grant and fails before a single
    seat starts — the runner's `mkdir -p "$WORK_DIR"` is denied.
    """
    try:
        import subprocess
        top = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=5)
        if top.returncode == 0:
            cwd = top.stdout.strip()
    except Exception:
        pass
    d = os.path.realpath(os.path.join(cwd, ".tmp"))
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass
    return d

def auth_env(home_tmp):
    """Keep the agents' credentials reachable from an isolated HOME.

    acpx reads ~/.acpx and codex reads ~/.codex, both resolved from $HOME. Redirect
    HOME without saying where those went and every seat fails to authenticate — the
    isolation works and the reviews do not. Both tools honour an explicit *_HOME, so
    point them at the real directories; the host stays readable on every backend
    anyway (see 'Honest scope' above), so this grants no read that was not already
    there. Only set them when the real directory exists, so an unconfigured host does
    not get a variable pointing at nothing.
    """
    env = []
    real_home = os.path.expanduser("~")
    for var, sub in (("ACPX_HOME", ".acpx"), ("CODEX_HOME", ".codex")):
        if os.environ.get(var):
            env.append("%s=%s" % (var, os.environ[var]))
        else:
            p = os.path.join(real_home, sub)
            if os.path.isdir(p):
                env.append("%s=%s" % (var, p))
    return env

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
    # Host ro, HOME + /tmp fresh tmpfs.
    cmd += ["--ro-bind", "/", "/", "--tmpfs", "/tmp", "--setenv", "TMPDIR", "/tmp"]
    cmd += ["--tmpfs", home_tmp, "--setenv", "HOME", home_tmp]
    if repo_sandbox and repo:
        cmd += ["--ro-bind", os.path.realpath(repo), os.path.realpath(repo)]
    # The runner's scratch is BOUND, not a tmpfs. Every reviewer output, transcript and
    # exit file is written here, and a tmpfs discards the lot when the sandbox exits —
    # the seats would run, cost money, and leave the synthesis stage an empty directory
    # to read. The ro-bind of / above is what makes this line necessary: it must come
    # after, so the writable bind wins for this one path.
    scratch = scratch_dir(bind_pwd)
    cmd += ["--bind", scratch, scratch]
    for kv in auth_env(home_tmp):
        k, _, v = kv.partition("=")
        cmd += ["--setenv", k, v]
    return cmd

def seatbelt_cmd(repo, repo_sandbox, no_net, bind_pwd):
    # Seatbelt matches RESOLVED paths: /tmp is a symlink to /private/tmp on macOS,
    # so a (subpath "/tmp") rule never fires. Use realpath everywhere.
    tmp = resolved_tmp()
    scratch = scratch_dir(bind_pwd)
    home_tmp = os.path.join(tmp, "debate-home-%s" % os.getpid())
    os.makedirs(home_tmp, exist_ok=True)

    # Writes go to this run's own HOME and the runner's scratch — not to the whole
    # temp directory. When TMPDIR is unset, gettempdir() resolves to /private/tmp,
    # which is shared and 1777, so granting it wholesale let a sandboxed seat modify
    # files belonging to other processes on the host. bwrap gives /tmp a fresh tmpfs;
    # this is the Seatbelt equivalent of that scope.
    rules = ["(deny file-write*)",
             '(allow file-write* (subpath "%s"))' % home_tmp,
             '(allow file-write* (subpath "%s"))' % scratch]
    if no_net:
        rules.append("(deny network*)")
    profile = "(version 1)\n(allow default)\n" + "\n".join(rules) + "\n"

    # 0600 + random name in the runner's scratch, not the system temp. A predictable
    # /tmp/se-<pid>.sb with default perms was both a leak and a collision, and the
    # exec'd process can't clean up after itself, so a file in /private/tmp would
    # linger in the shared OS temp until reboot. The scratch is the review's own
    # gitignored dir, so the profile stays out of the host's temp.
    fd, prof_path = tempfile.mkstemp(prefix="se-", suffix=".sb", dir=scratch)
    os.write(fd, profile.encode())
    os.close(fd)
    os.chmod(prof_path, 0o600)

    # HOME redirection must happen inside the sandbox: prefix env before the cmd.
    # TMPDIR points at this run's own HOME, which is the only temp path still
    # writable now that the profile no longer grants the whole shared tmp.
    return ["sandbox-exec", "-f", prof_path, "env",
            "HOME=%s" % home_tmp, "TMPDIR=%s" % home_tmp, *auth_env(home_tmp)]

def docker_cmd(repo, repo_sandbox, no_net, bind_pwd, image):
    """Last-resort backend. Mounts what the wrapped command actually needs.

    The command handed to us is a host path — the runner script — writing to a host
    scratch directory. Mounting only the repo left every one of those unreachable, so
    the container died on `No such file or directory` before any seat started. Bind
    the working directory and the scratch, set the workdir to match, and carry the
    agents' config in read-only so authentication still resolves.

    Note the image still has to contain the toolchain (acpx, node, python). A bare
    debian:bookworm-slim satisfies none of that, so this backend only works with an
    image built for it — which is why it sits behind bwrap and Seatbelt rather than
    being reached on a normal host.
    """
    cwd = os.path.realpath(bind_pwd)
    scratch = scratch_dir(bind_pwd)
    # The working directory (the repo, when invoked from it) mounts READ-ONLY: a seat
    # must not edit the repo it reviews. The scratch mounts rw and, being inside cwd,
    # shadows the ro parent for that one path — so review outputs still land. cwd used
    # to mount rw, which on this fallback backend let a seat modify the repo the sandbox
    # exists to keep read-only (bwrap ro-binds / and Seatbelt denies file-writes; docker
    # was the one backend that did not enforce the isolation).
    vol = ["--volume", "%s:%s:ro" % (cwd, cwd)]
    vol += ["--volume", "%s:%s" % (scratch, scratch)]
    if repo_sandbox and repo:
        r = os.path.realpath(repo)
        if r != cwd:
            vol += ["--volume", "%s:%s:ro" % (r, r)]
    env = []
    for kv in auth_env(None):
        _, _, path = kv.partition("=")
        if os.path.isdir(path):
            vol += ["--volume", "%s:%s:ro" % (path, path)]
        env += ["--env", kv]
    net = ["--network", "none"] if no_net else []
    return ["docker", "run", "--rm", *net, *vol, *env, "--workdir", cwd, image]

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
