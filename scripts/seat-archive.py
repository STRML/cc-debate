#!/usr/bin/env python3
"""seat-report.sh --archive: validate, sanitize and save a panel report. Usage is in seat-report.sh."""

import errno
import json
import math
import os
import re
import stat
import sys
import tempfile
import time
import unicodedata

HEX_DIR = re.compile(r"^ai-review-([0-9a-f]{8})$")
ROUND = re.compile(r"^[1-9][0-9]{0,2}$")
SEAT = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
SEVERITIES = ("critical", "major", "minor", "nit")
MAX_ARRAY = 200
MAX_TEXT = 2000
DROPPED = {"Cc", "Cf", "Cs", "Zl", "Zp"}
MAX_INPUT = 1024 * 1024
KEEP = 300
ARCHIVE = re.compile(r"^[0-9a-f]{8}-r[1-9][0-9]{0,2}\.json$")


def die(message):
    sys.exit("seat-report --archive: " + message)


def refuse_constant(name):
    raise ValueError("%s is not valid JSON" % name)


def parse(data):
    return json.loads(data.decode("utf-8"), parse_constant=refuse_constant)


def read_json(path, limit=MAX_INPUT):
    return parse(read_regular(path, limit))


def reject(message):
    die("rejected: " + message)


def seat_lists(report):
    return {key: list(report.get(key) or []) for key in ("seatsRun", "seatsFailed", "seatsNotConfigured", "seatsNotTranscribed")}


def validate(report):
    """Reject (writing nothing) a report that is malformed, oversized or inconsistent; return its seat lists."""
    if not isinstance(report, dict):
        reject("the report is not a JSON object")

    for key in ("seatsRun", "seatsFailed", "seatsNotConfigured", "seatsNotTranscribed"):
        if not isinstance(report.get(key) or [], list):
            reject("%s is not a list" % key)
    skipped = report.get("seatsSkipped") or []
    if not isinstance(skipped, list) or not all(isinstance(entry, dict) for entry in skipped):
        reject("seatsSkipped must be a list of objects")

    lists = seat_lists(report)
    names = [name for group in lists.values() for name in group] + [entry.get("seat") for entry in skipped]
    for name in names:
        if not isinstance(name, str) or not SEAT.match(name) or ".." in name:
            reject("seat name %r is not allowed" % (name,))

    sections = {}
    for key in ("findings", "refuted", "unverified"):
        value = report.get(key)
        if not isinstance(value, list):
            reject("%s is not a list" % key)
        if len(value) > MAX_ARRAY:
            reject("%s has more than %d entries" % (key, MAX_ARRAY))
        sections[key] = value

    counts = report.get("counts")
    if not isinstance(counts, dict):
        reject("counts is missing")
    for count_key, key in (("survived", "findings"), ("refuted", "refuted"), ("unverified", "unverified")):
        if type(counts.get(count_key)) is not int or counts[count_key] != len(sections[key]):
            reject("counts.%s is %r but %s has %d entries" % (count_key, counts.get(count_key), key, len(sections[key])))

    ran = set(lists["seatsRun"])
    for key, entries in sections.items():
        for entry in entries:
            if not isinstance(entry, dict):
                reject("a %s entry is not an object" % key)
            if entry.get("severity") not in SEVERITIES:
                reject("a %s entry has an unknown severity %r" % (key, entry.get("severity")))
            if type(entry.get("line", 0)) is not int or entry.get("line", 0) < 0:
                reject("a %s entry has a line that is not a whole number >= 0" % key)
            for field in ("file", "claim", "failure"):
                if not isinstance(entry.get(field), str):
                    reject("a %s entry has no %s text" % (key, field))
            found = entry.get("foundBy")
            if not isinstance(found, list) or not found:
                reject("a %s entry has no foundBy list" % key)
            for name in found:
                if not isinstance(name, str) or name not in ran:
                    reject("foundBy name %r is not in seatsRun" % (name,))
    return lists


def clean(value, cap=MAX_TEXT):
    """Reviewer text without control, format, surrogate or line-separator characters (newline and tab stay), capped."""
    text = value if isinstance(value, str) else ""
    kept = "".join(ch for ch in text if ch in "\n\t" or unicodedata.category(ch) not in DROPPED)
    return kept[:cap]


def clean_file(value, root):
    """A path a reviewer wrote, as a repo-relative path, or a label that says why it is not one."""
    text = clean(value)
    if text == "":
        return "(unknown file)"
    path = os.path.normpath(text)
    if os.path.isabs(path):
        if os.path.commonpath([root, path]) != root:
            return "(outside repo)"
        path = os.path.relpath(path, root)
        return "(unknown file)" if path == "." else path
    return "(unsafe path)" if ".." in path.split(os.sep) else path


def clean_entry(entry, root, with_why):
    out = {
        "file": clean_file(entry["file"], root),
        "line": entry.get("line", 0),
        "severity": entry["severity"],
        "claim": clean(entry["claim"]),
        "failure": clean(entry["failure"]),
        "foundBy": list(entry["foundBy"]),
    }
    if isinstance(entry.get("fix"), str):
        out["fix"] = clean(entry["fix"])
    if with_why:
        out["why"] = clean(entry.get("why"))
    return out


def clean_diff(value):
    """The classify stage's diff shape, one level deep: numbers, booleans, null and short text."""
    if not isinstance(value, dict):
        return None
    out = {}
    for key, item in list(value.items())[:20]:
        if item is None or isinstance(item, bool):
            out[clean(key, 64)] = item
        elif isinstance(item, (int, float)) and math.isfinite(item):
            out[clean(key, 64)] = item
        elif isinstance(item, str):
            out[clean(key, 64)] = clean(item)
    return out


def short(value, cap):
    return clean(value, cap) or None if isinstance(value, str) else None


def money(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        return None
    return round(float(value), 4)


def sanitized(report, lists, root):
    return {
        "diff": clean_diff(report.get("diff")),
        "seatsRun": lists["seatsRun"],
        "seatsFailed": lists["seatsFailed"],
        "seatsNotConfigured": lists["seatsNotConfigured"],
        "seatsNotTranscribed": lists["seatsNotTranscribed"],
        "seatsSkipped": [{"seat": entry["seat"], "why": clean(entry.get("why"))} for entry in report.get("seatsSkipped") or []],
        "counts": {key: value for key, value in report["counts"].items()
                   if key in ("raw", "locations", "distinct", "survived", "refuted", "unverified") and type(value) is int},
        "findings": [clean_entry(entry, root, False) for entry in report["findings"]],
        "refuted": [clean_entry(entry, root, True) for entry in report["refuted"]],
        "unverified": [clean_entry(entry, root, False) for entry in report["unverified"]],
    }


def read_regular(path, limit):
    """The bytes of a regular file of this user, opened without following a symlink; the checks run on the descriptor."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise OSError(errno.EPERM, "not a regular file of yours")
        if info.st_size > limit:
            raise OSError(errno.EFBIG, "larger than the limit")
        with os.fdopen(fd, "rb", closefd=False) as fh:
            data = fh.read(limit + 1)
    finally:
        os.close(fd)
    if len(data) > limit:
        raise OSError(errno.EFBIG, "larger than the limit")
    return data


def regular_size(path):
    """The size of a regular file, or None when it is missing, a symlink or not a regular file."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        return info.st_size if stat.S_ISREG(info.st_mode) else None
    finally:
        os.close(fd)


def has_review(work, seat):
    return (regular_size(os.path.join(work, seat + "-output.md")) or 0) > 0


def seat_states(lists, work):
    """reported, failed, not-configured or unreadable, per seat the panel named."""
    ran, failed = lists["seatsRun"], lists["seatsFailed"]
    unconfigured, untranscribed = lists["seatsNotConfigured"], lists["seatsNotTranscribed"]
    states = {}
    for seat in sorted(set(ran + failed + unconfigured + untranscribed)):
        if seat in untranscribed:
            states[seat] = "unreadable"
        elif seat in unconfigured:
            states[seat] = "not-configured"
        elif seat in failed or seat not in ran:
            states[seat] = "failed"
        elif not has_review(work, seat):
            states[seat] = "unreadable"
        else:
            states[seat] = "reported"
    return states


def seat_meta(work, names):
    """model, effort and estimated cost from the selector's manifest, for the seats it assigned."""
    meta = {name: {"model": None, "effort": None, "est_cost": None} for name in names}
    try:
        seats = read_json(os.path.join(work, "panel.json")).get("seats")
    except (OSError, ValueError, AttributeError):
        return meta
    if isinstance(seats, dict):
        for name in names:
            entry = seats.get(name)
            if isinstance(entry, dict):
                meta[name] = {
                    "model": short(entry.get("model_id"), 64),
                    "effort": short(entry.get("effective_effort"), 16),
                    "est_cost": money(entry.get("effective_cost")),
                }
    return meta


def write_failed(path, error):
    if error.errno in (errno.EPERM, errno.EACCES, errno.EROFS):
        die("cannot write %s (%s). The sandbox must allow writes to ~/.acpx: add Write(~/.acpx/**) as /debate:setup describes."
            % (path, error.strerror))
    die("cannot write %s (%s)" % (path, error))


def ensure_dir(path):
    """The archive folder: not a symlink, ours, mode 0700."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            die("%s is a symlink, not a folder, or not yours; refusing to write there" % path)
        os.chmod(path, 0o700)
    except OSError as error:
        write_failed(path, error)


def write_archive(dest, name, archive):
    """One file appears whole or not at all: a private temp file in the same folder, then a rename over the name."""
    ensure_dir(dest)
    try:
        fd, temp = tempfile.mkstemp(prefix=".saving-", suffix=".json", dir=dest)
    except OSError as error:
        write_failed(dest, error)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(json.dumps(archive, ensure_ascii=False, allow_nan=False).encode("utf-8"))
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(temp, os.path.join(dest, name))
    except (OSError, ValueError) as error:
        try:
            os.unlink(temp)
        except OSError:
            pass
        if isinstance(error, OSError):
            write_failed(dest, error)
        die("cannot save the archive (%s)" % error)


def prune(dest):
    """Keep the newest KEEP archives. Only regular, non-symlink files with an archive name are ever removed."""
    found = []
    for name in os.listdir(dest):
        if ARCHIVE.match(name):
            try:
                info = os.lstat(os.path.join(dest, name))
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode):
                found.append((info.st_mtime, name))
    found.sort(reverse=True)
    for _, name in found[KEEP:]:
        try:
            os.unlink(os.path.join(dest, name))
        except OSError:
            pass


def main(argv):
    if len(argv) != 3 or argv[1] != "--round":
        die("usage: seat-report.sh --archive <WORK_DIR>/report.json --round <N>")
    if not ROUND.match(argv[2]):
        die("--round must be a whole number from 1 to 999")

    report_path = os.path.abspath(argv[0])
    work = os.path.dirname(report_path)
    dot_tmp = os.path.dirname(work)
    match = HEX_DIR.match(os.path.basename(work))
    if os.path.basename(report_path) != "report.json" or match is None or os.path.basename(dot_tmp) != ".tmp":
        die("report.json must sit directly in a .tmp/ai-review-<8 hex> folder")
    review_id, root = match.group(1), os.path.dirname(dot_tmp)

    try:
        info = os.lstat(work)
    except OSError as error:
        die("cannot read the review folder (%s)" % error)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        die("the review folder is a symlink or not yours")

    try:
        report = read_json(report_path)
    except OSError as error:
        if error.errno == errno.ELOOP:
            die("report.json is a symlink; refusing to read it")
        if error.errno == errno.EFBIG:
            die("report.json is larger than 1 MB")
        die("cannot read report.json (%s)" % error)
    except ValueError as error:
        die("report.json is not valid JSON (%s)" % error)

    lists = validate(report)
    states = seat_states(lists, work)
    archive = {
        "v": 1,
        "meta": {"id": review_id, "round": int(argv[2]), "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "root": root},
        "seatState": states,
        "seatMeta": seat_meta(work, list(states)),
        "report": sanitized(report, lists, root),
    }

    dest = os.path.join(os.path.expanduser("~"), ".acpx", "debate-reports")
    write_archive(dest, "%s-r%d.json" % (review_id, int(argv[2])), archive)
    prune(dest)
    print("seat-report --archive: saved %s" % os.path.join(dest, "%s-r%d.json" % (review_id, int(argv[2]))))


main(sys.argv[1:])
