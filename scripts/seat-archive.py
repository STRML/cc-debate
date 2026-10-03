#!/usr/bin/env python3
"""seat-report.sh --archive: validate, sanitize and save a panel report. Usage is in seat-report.sh."""

import json
import os
import re
import sys
import time

HEX_DIR = re.compile(r"^ai-review-([0-9a-f]{8})$")
ROUND = re.compile(r"^[1-9][0-9]{0,2}$")
SEAT = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
SEVERITIES = ("critical", "major", "minor", "nit")
MAX_ARRAY = 200


def die(message):
    sys.exit("seat-report --archive: " + message)


def refuse_constant(name):
    raise ValueError("%s is not valid JSON" % name)


def read_json(path):
    with open(path, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"), parse_constant=refuse_constant)


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


def has_review(work, seat):
    try:
        return os.path.getsize(os.path.join(work, seat + "-output.md")) > 0
    except OSError:
        return False


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
                    "model": entry.get("model_id"),
                    "effort": entry.get("effective_effort"),
                    "est_cost": entry.get("effective_cost"),
                }
    return meta


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
        report = read_json(report_path)
    except OSError as error:
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
        "report": report,
    }

    dest = os.path.join(os.path.expanduser("~"), ".acpx", "debate-reports")
    os.makedirs(dest, exist_ok=True)
    final = os.path.join(dest, "%s-r%d.json" % (review_id, int(argv[2])))
    with open(final, "w") as fh:
        json.dump(archive, fh)
    print("seat-report --archive: saved %s" % final)


main(sys.argv[1:])
