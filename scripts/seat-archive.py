#!/usr/bin/env python3
"""seat-report.sh --archive: validate, sanitize and save a panel report. Usage is in seat-report.sh."""

import json
import os
import re
import sys
import time

HEX_DIR = re.compile(r"^ai-review-([0-9a-f]{8})$")
ROUND = re.compile(r"^[1-9][0-9]{0,2}$")


def die(message):
    sys.exit("seat-report --archive: " + message)


def read_json(path):
    with open(path, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"))


def seat_lists(report):
    return {key: list(report.get(key) or []) for key in ("seatsRun", "seatsFailed", "seatsNotConfigured", "seatsNotTranscribed")}


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

    lists = seat_lists(report)
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
