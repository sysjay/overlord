#!/usr/bin/env python3
"""Jay's view of overlord's recommendations: list, show, accept, reject, done.

    sudo -u sysai /usr/local/lib/overlord/overlord-rec.py list
    sudo -u sysai /usr/local/lib/overlord/overlord-rec.py show R-2
    sudo -u sysai /usr/local/lib/overlord/overlord-rec.py accept R-2 ["note"]
    sudo -u sysai /usr/local/lib/overlord/overlord-rec.py reject R-2 "note"
    sudo -u sysai /usr/local/lib/overlord/overlord-rec.py done R-2 ["note"]

Reads and writes $OVERLORD_RUNS/recommendations.json (default ~/runs), then
rebuilds the status site. It writes no tickets: accept prints a title to plan
the ticket with. Standard library only.
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

RUNS = Path(os.environ.get("OVERLORD_RUNS", Path.home() / "runs"))
RECS = RUNS / "recommendations.json"
RENDER = Path(__file__).resolve().parent / "render_site.py"
STATES = ("proposed", "accepted", "rejected", "done")


def load():
    try:
        recs = json.loads(RECS.read_text())
        return recs if isinstance(recs, list) else []
    except (OSError, ValueError):
        return []


def save(recs):
    tmp = RECS.with_name(RECS.name + ".tmp")
    tmp.write_text(json.dumps(recs, indent=1) + "\n")
    os.replace(tmp, RECS)
    try:
        subprocess.run([sys.executable, str(RENDER)], check=False, stdout=subprocess.DEVNULL)
    except OSError:
        pass


def find(recs, rid):
    for r in recs:
        if r.get("id", "").lower() == rid.lower():
            return r
    sys.exit("no recommendation %s (try: list)" % rid)


def line(r):
    return "%-5s %-9s %-6s %-10s %s" % (r.get("id"), r.get("state"), r.get("kind"),
                                         r.get("target_repo"), r.get("title"))


def show(r):
    print(line(r))
    for k in ("frequency", "why", "check", "first_seen", "last_seen", "times_seen", "note", "decided"):
        if r.get(k) not in (None, ""):
            print("  %-10s %s" % (k + ":", r[k]))


def main(argv):
    if not argv or argv[0] not in ("list", "show", "accept", "reject", "done"):
        sys.exit(__doc__.strip())
    cmd, recs = argv[0], load()
    if cmd == "list":
        if not recs:
            print("no recommendations yet")
        for state in STATES:
            for r in recs:
                if r.get("state") == state:
                    print(line(r))
        return 0
    if len(argv) < 2:
        sys.exit("usage: %s %s R-n%s" % (Path(sys.argv[0]).name, cmd, ' "note"' if cmd == "reject" else ""))
    r = find(recs, argv[1])
    if cmd == "show":
        show(r)
        return 0
    note = " ".join(argv[2:]).strip()
    if cmd == "reject" and not note:
        sys.exit('reject needs a note, so overlord knows why: reject %s "why"' % r["id"])
    r["state"] = {"accept": "accepted", "reject": "rejected", "done": "done"}[cmd]
    r["decided"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if note:
        r["note"] = note
    save(recs)
    show(r)
    if cmd == "accept":
        print()
        print("Next ticket (repo %s): %s" % (r.get("target_repo"), r.get("title")))
        print("Plan it in claude.ai with the why/check above; mark it done when it ships:")
        print("  sudo -u sysai %s done %s" % (Path(sys.argv[0]).resolve(), r["id"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
