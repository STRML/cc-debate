#!/usr/bin/env python3
"""Platform-adaptive sandbox wrapper for acpx reviewer seats (debate v3, #31).

Chooses the lightest OS-level sandbox available per host, so `repo-aware` seats and
acpx reviewers get real isolation instead of a permission flag:
  Linux   -> bwrap (bubblewrap): user-namespace + seccomp, no root, no VM.
  macOS   -> sandbox-exec (Seatbelt): native, no VM.
  fallback-> docker run (only if a docker runtime exists; requires --image with
            the acpx/node/python toolchain).

The sandboxed process env is a WHITELIST, not the caller's environment: PATH, an
isolated HOME/TMPDIR, the *_HOME auth vars auth_env() sets, and any explicit
ACPX_*/CODEX_* overrides. Caller secrets (OPENAI_API_KEY, ANTHROPIC_API_KEY,
AWS_*, GITHUB_*, ...) never reach a seat on any backend.

Usage (a command prefix):
  sandbox.py [--repo-sandbox] [--repo ROOT] [--no-net] [--image IMAGE] -- CMD ARGS...

  --repo-sandbox  the repo is mounted read-only (repo-aware seat); HOME is
                  redirected to a throwaway dir; the only writable places are
                  the OS temp dir and <cwd>/.tmp (the runner's scratch).
  (default)       HOME isolated + writes confined to temp + <cwd>/.tmp.
  --no-net        deny network (defense for untrusted diffs; acpx seats need
                  network, so this is opt-in).
  --image IMAGE   docker fallback image — REQUIRED when the docker backend is
                  reached. Must contain the toolchain (acpx, node, python); a
                  bare debian:bookworm-slim has none of it, so main() refuses
                  to start docker without --image.

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
    # A repo-controlled `.tmp` symlink (e.g. `.tmp -> /tmp`) would redirect the
    # sandbox's WRITABLE grant outside the repo — the realpath lands on a shared,
    # other-process-owned directory the seat could then alter. Refuse rather than
    # grant it (pentester finding).
    root = os.path.realpath(cwd)
    if not (d == root or d.startswith(root.rstrip(os.sep) + os.sep)):
        raise SystemExit(
            "sandbox.py: %s/.tmp resolves to %s, outside %s — refusing a symlinked scratch"
            % (cwd, d, root))
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass
    return d

def auth_env():
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

def scrub_env(home, tmpdir, path=None):
    """Whitelist for a sandboxed process env: no caller secrets reach the seat.

    bwrap and Seatbelt inherit the caller's full environment by default, so without
    a scrub a sandboxed seat could `printenv OPENAI_API_KEY` (or AWS_*, GITHUB_*,
    ...) and exfiltrate it over the shared network. Build the env instead from what
    a seat actually needs: PATH (to find bash/node/jq/acpx), an isolated HOME and
    TMPDIR, the *_HOME auth vars auth_env() sets, and any explicit ACPX_*/CODEX_*
    overrides. Authentication still resolves because acpx/codex read their *_HOME
    dirs (mounted read-only on every backend), not env keys.
    """
    env = {}
    env["PATH"] = path if path is not None else os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    env["HOME"] = home
    env["TMPDIR"] = tmpdir
    for kv in auth_env():
        k, _, v = kv.partition("=")
        if v:
            env[k] = v
    for k, v in os.environ.items():
        if (k.startswith("ACPX_") or k.startswith("CODEX_")) and k not in env:
            env[k] = v
    # Runner controls the wrapped run-parallel-acpx.sh reads: DEBATE_FREEZE_DIFF /
    # DEBATE_DIFF_BASE pick the diff, POLL_MAX_WAIT bounds the wait,
    # DEBATE_TIMEOUT_BIN pins or disables the per-seat timeout binary. A scrub that
    # dropped these silently changed the review target inside the sandbox (#45).
    for k in ("DEBATE_FREEZE_DIFF", "DEBATE_DIFF_BASE", "POLL_MAX_WAIT",
              "DEBATE_TIMEOUT_BIN"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    # The antigravity direct-CLI seat authenticates via ANTIGRAVITY_API_KEY /
    # GEMINI_API_KEY when no OAuth is stored; a scrub that dropped these made every
    # sandboxed agy seat fail to authenticate (#45). They are already in the caller's
    # env, so passing them to the seat is not a new exposure.
    for k in ("ANTIGRAVITY_API_KEY", "GEMINI_API_KEY"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env

def bwrap_cmd(repo, repo_sandbox, no_net, bind_pwd):
    home_tmp = os.path.join("/tmp", "debate-home-%s" % os.getpid())
    cmd = ["bwrap"]
    if _bwrap_supports("die-with-parent"):
        cmd.append("--die-with-parent")
    cmd += ["--unshare-pid", "--new-session"]
    if no_net:
        cmd += ["--unshare-net"]
    # Host ro, HOME + /tmp fresh tmpfs.
    cmd += ["--ro-bind", "/", "/", "--tmpfs", "/tmp"]
    cmd += ["--tmpfs", home_tmp]
    if repo_sandbox and repo:
        cmd += ["--ro-bind", os.path.realpath(repo), os.path.realpath(repo)]
    # The runner's scratch is BOUND, not a tmpfs. Every reviewer output, transcript and
    # exit file is written here, and a tmpfs discards the lot when the sandbox exits —
    # the seats would run, cost money, and leave the synthesis stage an empty directory
    # to read. The ro-bind of / above is what makes this line necessary: it must come
    # after, so the writable bind wins for this one path.
    scratch = scratch_dir(bind_pwd)
    cmd += ["--bind", scratch, scratch]
    # Scrub the caller's env: bwrap inherits it by default, so a seat could printenv
    # the host's OPENAI_API_KEY etc. --clearenv drops the lot; the --setenv flags that
    # follow rebuild exactly the whitelist a seat needs. (--clearenv is standard in
    # every bwrap since 0.1.0, so it is not feature-gated like --die-with-parent.)
    cmd += ["--clearenv"]
    for k, v in scrub_env(home_tmp, "/tmp").items():
        cmd += ["--setenv", k, v]
    return cmd

def seatbelt_cmd(repo, repo_sandbox, no_net, bind_pwd):
    # Seatbelt matches RESOLVED paths: /tmp is a symlink to /private/tmp on macOS,
    # so a (subpath "/tmp") rule never fires. scratch_dir() already realpaths, and
    # HOME now lives INSIDE the scratch. The old /private/tmp/debate-home-<pid>
    # leaked: the exec'd process can never clean up, so every macOS review left a
    # directory in the shared OS temp until reboot. Under the scratch it is swept
    # with the review's own artifacts, like the se-*.sb profile already was.
    scratch = scratch_dir(bind_pwd)
    home_tmp = os.path.join(scratch, "debate-home-%s" % os.getpid())
    os.makedirs(home_tmp, exist_ok=True)
    os.chmod(home_tmp, 0o700)   # private: another local user must not read a seat's HOME

    # Writes go to this run's own HOME and the runner's scratch — not to the whole
    # temp directory. When TMPDIR is unset, gettempdir() resolves to /private/tmp,
    # which is shared and 1777, so granting it wholesale let a sandboxed seat modify
    # files belonging to other processes on the host. bwrap gives /tmp a fresh tmpfs;
    # this is the Seatbelt equivalent of that scope. home_tmp is a subpath of scratch,
    # so its grant is redundant but kept for the write-scope contract.
    # A path a local attacker can control (the checkout/working-directory name) is
    # interpolated into the SBPL profile; quotes/newlines there would inject a rule
    # (e.g. a write grant for /). Escape string literals (pentester finding).
    def sbpl(s):
        return (s or "").replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    rules = ["(deny file-write*)",
             # The runner's scripts redirect stdout/stderr to /dev/null throughout
             # (`git rev-parse ... 2>/dev/null`); with no /dev/null grant the seatbelt
             # sandbox can never run the pipeline, so keep the device sink writable.
             '(allow file-write* (literal "/dev/null"))',
             '(allow file-write* (subpath "%s"))' % sbpl(home_tmp),
             '(allow file-write* (subpath "%s"))' % sbpl(scratch)]
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
    # `env -i` (not a bare `env NAME=VAL`) clears the caller's env: Seatbelt
    # inherits it by default, and the old prefix only ADDED vars, leaking
    # OPENAI_API_KEY etc. to the seat. Note: no `--` terminator — macOS ships the
    # BSD env, which treats `--` as the utility name and fails with exit 127.
    env_parts = ["%s=%s" % (k, v) for k, v in scrub_env(home_tmp, home_tmp).items()]
    return ["sandbox-exec", "-f", prof_path, "env", "-i", *env_parts]

def docker_cmd(repo, repo_sandbox, no_net, bind_pwd, image):
    """Last-resort backend. REQUIRES --image with the acpx/node/python toolchain.

    The command handed to us is a host path — the runner script — writing to a host
    scratch directory. Mounting only the repo left every one of those unreachable, so
    the container died on `No such file or directory` before any seat started. Bind
    the working directory and the scratch, set the workdir to match, and carry the
    agents' config in read-only so authentication still resolves.

    The default image used to be debian:bookworm-slim, which ships no jq/git/node/
    python/acpx — so this backend advertised itself as working and died on the first
    `command not found`. main() now refuses to start it without --image, and the image
    must contain the toolchain (acpx, node, python). That is why it sits behind bwrap
    and Seatbelt rather than being reached on a normal host.
    """
    cwd = os.path.realpath(bind_pwd)
    scratch = scratch_dir(bind_pwd)
    # HOME/TMPDIR live inside the scratch, mirroring the Seatbelt backend: a seat's
    # HOME caching behaves like the other backends and lands in the review's own
    # swept artifacts, not a path on the container's (ephemeral, soon-read-only) layer.
    home_tmp = os.path.join(scratch, "debate-home-%s" % os.getpid())
    try:
        os.makedirs(home_tmp, exist_ok=True)
        os.chmod(home_tmp, 0o700)
    except OSError:
        pass  # the scratch may be unwritable when only building the command (tests)
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
    # Docker does not inherit the caller's env: the container starts from the image's
    # ENV defaults plus the --env flags below, so the env is already a whitelist.
    # Give the seat an isolated HOME/TMPDIR under the scratch and the *_HOME auth
    # vars; leave PATH to the image, whose dirs actually exist in the container (the
    # host's /opt/homebrew paths do not). The ACPX_*/CODEX_* pass-through is included
    # so explicit overrides survive.
    env_args = []
    for k, v in scrub_env(home_tmp, home_tmp).items():
        if k == "PATH":
            continue
        env_args += ["--env", "%s=%s" % (k, v)]
    for kv in auth_env():
        _, _, path = kv.partition("=")
        if os.path.isdir(path):
            vol += ["--volume", "%s:%s:ro" % (path, path)]
        env_args += ["--env", kv]
    # bwrap and Seatbelt inherit the parent environment, but docker only passes
    # what --env names. Carry the model-selection vars (F1) explicitly so a
    # sandboxed dispatch on the docker backend still reaches the per-seat model.
    for var in ("DEBATE_MODEL", "ACPX_SEAT_MODELS"):
        if os.environ.get(var):
            env_args += ["--env", "%s=%s" % (var, os.environ[var])]
    # The wrapped runner reads its reviewer config (~/.claude/debate-acpx.json); without
    # ~/.claude mounted, every sandboxed docker review fails "Config not found" before a
    # single seat starts.
    home_claude = os.path.join(os.path.expanduser("~"), ".claude")
    if os.path.isdir(home_claude):
        vol += ["--volume", "%s:%s:ro" % (home_claude, home_claude)]
    # The model map (ACPX_SEAT_MODELS) must be reachable inside the container: the
    # env var alone points at a host path docker does not mount, so the runner would
    # silently fall back to defaults. Mount the file read-only (debate finding).
    models_file = os.environ.get("ACPX_SEAT_MODELS")
    if models_file and os.path.isfile(models_file):
        models_file = os.path.realpath(models_file)
        vol += ["--volume", "%s:%s:ro" % (models_file, models_file)]
    # --read-only (in the return below) makes the container root filesystem
    # read-only: the scratch volume is the ONLY writable place, so a seat cannot
    # leave state in the container image layer.
    net = ["--network", "none"] if no_net else []
    return ["docker", "run", "--rm", "--read-only", *net, *vol, *env_args, "--workdir", cwd, image]

def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--repo-sandbox", action="store_true")
    ap.add_argument("--repo", default=None)
    ap.add_argument("--no-net", action="store_true")
    ap.add_argument("--image", default=None)
    ap.add_argument("args", nargs=argparse.REMAINDER, default=[])
    a = ap.parse_args()

    sand = detect_sandbox()
    if sand is None:
        # Fail closed. This wrapper exists only to isolate a review, so being asked to
        # sandbox and having no backend to do it with is a configuration error, not a
        # prompt to run unsandboxed — silently degrading an explicit isolation request
        # is the kind of surprise a security boundary must not contain.
        print("sandbox.py: no bwrap/sandbox-exec/docker found; refusing to run unsandboxed", file=sys.stderr)
        print("  Install one (apt install bubblewrap / macOS ships sandbox-exec / install docker),", file=sys.stderr)
        print("  or call the wrapped command directly if it does not need isolation.", file=sys.stderr)
        sys.exit(2)
    elif sand == "bwrap":
        prefix = bwrap_cmd(a.repo, a.repo_sandbox, a.no_net, bind_pwd=os.getcwd())
    elif sand == "sandbox-exec":
        prefix = seatbelt_cmd(a.repo, a.repo_sandbox, a.no_net, bind_pwd=os.getcwd())
    else:
        # Fail fast rather than pretend the last-resort backend works: the old default
        # image (debian:bookworm-slim) ships no jq/git/node/python/acpx, so an image
        # that actually carries the toolchain must be supplied explicitly.
        if not a.image:
            print("sandbox.py: the docker fallback needs an image with the acpx/node/python toolchain", file=sys.stderr)
            print("  pass --image <tag> (e.g. an image preloaded with acpx, node, python, jq, git).", file=sys.stderr)
            print("  A bare debian:bookworm-slim has none of it; refusing to start a broken backend.", file=sys.stderr)
            sys.exit(2)
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
