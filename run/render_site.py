#!/usr/bin/env python3
"""Build overlord's static status site from the run folders and the ledger.

Reads  $OVERLORD_RUNS (default ~/runs): <run_id>/report.json, ledger.csv
Writes $OVERLORD_SITE (default ~/site): a symlink swapped atomically to a fresh
       build in ~/site-builds/. Standard library only; all text HTML-escaped;
       no external requests. The collector's facts are never published.
"""
import csv
import html
import json
import os
import re
import shutil
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
    LOCAL = ZoneInfo("America/New_York")
except Exception:  # no tz database: show UTC
    LOCAL = timezone.utc

HOME = Path.home()
RUNS = Path(os.environ.get("OVERLORD_RUNS", HOME / "runs"))
SITE = Path(os.environ.get("OVERLORD_SITE", HOME / "site"))
BUILDS = SITE.parent / "site-builds"
HISTORY = 90
STALE_HOURS = 26
RUN_ID = re.compile(r"^\d{8}T\d{6}Z$")

e = html.escape

CSS = """
:root{--bg:#f6f7f9;--fg:#1c1f24;--muted:#5d6672;--card:#fff;--line:#dde1e6;
--ok:#1f7a3a;--warn:#9a6100;--problem:#b3261e;--error:#6b3fa0;--link:#1a5fb4}
@media (prefers-color-scheme:dark){:root{--bg:#121417;--fg:#e6e8eb;--muted:#9aa3ad;
--card:#1b1e23;--line:#2c3138;--ok:#4cc26e;--warn:#e0a63a;--problem:#ff6b60;
--error:#b48cf0;--link:#7fb0ff}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:860px;margin:0 auto;padding:16px}
a{color:var(--link)}
h1{font-size:1.2rem;margin:0 0 12px}
h2{font-size:1.05rem;margin:24px 0 8px}
h3{font-size:1rem;margin:16px 0 4px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin:12px 0}
.badge{display:inline-block;padding:6px 14px;border-radius:8px;color:#fff;font-weight:700;letter-spacing:.04em}
.big{font-size:1.6rem}
.ok{background:var(--ok)}.warn{background:var(--warn)}.problem{background:var(--problem)}.error{background:var(--error)}
.muted{color:var(--muted);font-size:.9rem}
.stale{background:var(--problem);color:#fff;border-radius:8px;padding:10px 14px;margin:12px 0;font-weight:600}
.costs{display:flex;flex-wrap:wrap;gap:8px 24px}
.costs div b{display:block;font-size:1.2rem}
.report p{margin:6px 0}.report ul{margin:6px 0;padding-left:22px}
.report code{background:var(--bg);padding:1px 4px;border-radius:4px}
table{width:100%;border-collapse:collapse;font-size:.92rem}
th,td{text-align:left;padding:6px 6px;border-bottom:1px solid var(--line);vertical-align:top}
td.num,th.num{text-align:right;white-space:nowrap}
td .badge{padding:1px 7px;font-size:.75rem}
.scroll{overflow-x:auto}
nav{display:flex;justify-content:space-between;gap:12px;margin:12px 0}
@media (max-width:560px){.hide-sm{display:none}}
"""

STALE_JS = """<script>
(function(){var t=document.body.getAttribute('data-newest');if(!t)return;
var age=(Date.now()-Date.parse(t))/3600000;var el=document.getElementById('stale');
if(age>%d&&el){el.hidden=false;el.textContent='No run since '+new Date(t).toLocaleString()+
' ('+Math.floor(age)+' h ago).';}})();
</script>""" % STALE_HOURS


def parse_time(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def local(dt, fmt="%a %b %-d %Y, %-I:%M %p"):
    return dt.astimezone(LOCAL).strftime(fmt) if dt else "?"


def money(x, places=2):
    try:
        return "$%.*f" % (places, float(x))
    except (TypeError, ValueError):
        return "?"


def inline(text):
    """Escaped text with **bold** and `code`."""
    t = e(text)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)


def markdown(md):
    """A small, safe Markdown subset: headings, bullets, paragraphs."""
    out, in_list = [], False
    for line in (md or "").splitlines():
        s = line.strip()
        bullet = re.match(r"^[-*]\s+(.*)", s) or re.match(r"^\d+[.)]\s+(.*)", s)
        if bullet:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>%s</li>" % inline(bullet.group(1)))
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        heading = re.match(r"^#{1,6}\s+(.*)", s)
        if heading:
            out.append("<h3>%s</h3>" % inline(heading.group(1)))
        elif s:
            out.append("<p>%s</p>" % inline(s))
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def badge(status, big=False):
    st = status if status in ("ok", "warn", "problem", "error") else "error"
    return '<span class="badge %s%s">%s</span>' % (st, " big" if big else "", e(st.upper()))


def page(title, body, newest=None):
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            "<meta name=\"color-scheme\" content=\"light dark\">"
            "<title>%s</title><style>%s</style></head><body data-newest=\"%s\"><main>%s</main>%s"
            "</body></html>\n") % (e(title), CSS, e(newest or ""), body, STALE_JS)


def load_runs():
    runs = []
    if not RUNS.is_dir():
        return runs
    for d in RUNS.iterdir():
        if not (d.is_dir() and RUN_ID.match(d.name)):
            continue
        try:
            r = json.loads((d / "report.json").read_text())
        except (OSError, ValueError):
            continue
        r["run_id"] = d.name  # the folder name is the trusted id
        r["_finished"] = parse_time(r.get("finished_at")) or parse_time(r.get("started_at"))
        runs.append(r)
    runs.sort(key=lambda r: r["run_id"], reverse=True)
    return runs


def load_ledger():
    rows = []
    try:
        with open(RUNS / "ledger.csv", newline="") as f:
            for row in csv.DictReader(f):
                try:
                    row["_cost"] = float(row.get("cost_usd") or 0)
                    row["_at"] = datetime.strptime(row["run_id"], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
                except (KeyError, ValueError):
                    continue
                rows.append(row)
    except OSError:
        pass
    return rows


def run_page(r, newer, older):
    nav = "<nav><span>%s</span><a href=\"../index.html\">Latest</a><span>%s</span></nav>" % (
        '<a href="%s.html">&larr; Newer</a>' % e(newer["run_id"]) if newer else "",
        '<a href="%s.html">Older &rarr;</a>' % e(older["run_id"]) if older else "")
    hosts = ", ".join(str(h) for h in r.get("hosts") or [])
    notes = "".join("<li>%s</li>" % e(str(n)) for n in r.get("notes") or [])
    body = (nav +
            '<div class="card">%s <span class="muted">%s</span><p>%s</p>'
            '<p class="muted">Model %s · cost %s · %s s · hosts %s</p>%s</div>'
            '<div class="card report">%s</div>' + nav) % (
        badge(r.get("status"), True), e(local(r["_finished"])), e(r.get("summary") or ""),
        e(r.get("model") or "?"), money(r.get("cost_usd"), 3), e(str(r.get("duration_s", "?"))),
        e(hosts or "?"), "<ul>%s</ul>" % notes if notes else "", markdown(r.get("report_md")))
    return page("overlord %s" % r["run_id"], "<h1>overlord run</h1>" + body)


def index_page(runs, ledger, now):
    newest = runs[0] if runs else None
    month_start = now.astimezone(LOCAL).replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    month = [x for x in ledger if x["_at"] >= month_start]
    last30 = [x for x in ledger if x["_at"] >= now - timedelta(days=30)]
    newest_at = newest["_finished"] if newest else None
    stale = newest_at is None or now - newest_at > timedelta(hours=STALE_HOURS)
    stale_text = ("No run since %s." % local(newest_at)) if newest_at else "No runs yet."
    parts = ['<h1>overlord · home status</h1>',
             '<div id="stale" class="stale"%s>%s</div>' % ("" if stale else " hidden", e(stale_text))]
    if newest:
        parts.append('<div class="card">%s <span class="muted">%s</span><p>%s</p>'
                     '<p class="muted"><a href="runs/%s.html">This run</a></p></div>' % (
                         badge(newest.get("status"), True), e(local(newest_at)),
                         e(newest.get("summary") or ""), e(newest["run_id"])))
    parts.append('<div class="card costs"><div>This run<b>%s</b></div>'
                 '<div>This month<b>%s</b><span class="muted">%d runs</span></div>'
                 '<div>Last 30 days<b>%s</b><span class="muted">%d runs</span></div></div>' % (
                     money(newest.get("cost_usd"), 3) if newest else "-",
                     money(sum(x["_cost"] for x in month)), len(month),
                     money(sum(x["_cost"] for x in last30)), len(last30)))
    if newest:
        parts.append('<h2>Report</h2><div class="card report">%s</div>' % markdown(newest.get("report_md")))
    rows = "".join(
        '<tr><td><a href="runs/%s.html">%s</a></td><td>%s</td><td>%s</td>'
        '<td class="num">%s</td><td class="num hide-sm">%s s</td></tr>' % (
            e(r["run_id"]), e(local(r["_finished"], "%b %-d %-I:%M %p")), badge(r.get("status")),
            e(r.get("summary") or ""), money(r.get("cost_usd"), 3), e(str(r.get("duration_s", "?"))))
        for r in runs[:HISTORY])
    parts.append('<h2>History</h2><div class="card scroll"><table><thead><tr><th>Date</th><th>Status</th>'
                 '<th>Summary</th><th class="num">Cost</th><th class="num hide-sm">Time</th></tr></thead>'
                 '<tbody>%s</tbody></table></div>' % (rows or '<tr><td colspan="5">No runs yet.</td></tr>'))
    parts.append('<p class="muted">Rendered %s.</p>' % e(local(now)))
    return page("overlord", "".join(parts),
                newest_at.strftime("%Y-%m-%dT%H:%M:%SZ") if newest_at else None)


def main():
    now = datetime.now(timezone.utc)
    runs = load_runs()
    ledger = load_ledger()

    BUILDS.mkdir(parents=True, exist_ok=True, mode=0o755)
    build = BUILDS / now.strftime("%Y%m%dT%H%M%S%fZ")
    (build / "runs").mkdir(parents=True)
    (build / "index.html").write_text(index_page(runs, ledger, now))
    for i, r in enumerate(runs[:HISTORY]):
        newer = runs[i - 1] if i > 0 else None
        older = runs[i + 1] if i + 1 < len(runs[:HISTORY]) else None
        (build / "runs" / ("%s.html" % r["run_id"])).write_text(run_page(r, newer, older))

    # swap atomically: a temp symlink renamed over SITE
    if SITE.exists() and not SITE.is_symlink():
        SITE.rename(BUILDS / ("old-" + now.strftime("%Y%m%dT%H%M%SZ")))
    tmp = SITE.with_name(SITE.name + ".new")
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    tmp.symlink_to(build)
    os.replace(tmp, SITE)

    # keep the current build and the one before it (a request may still be reading it)
    others = sorted((p for p in BUILDS.iterdir() if p != build), key=lambda p: p.stat().st_mtime, reverse=True)
    for old in others[1:]:
        shutil.rmtree(old, ignore_errors=True)
    print("site: %d runs -> %s" % (min(len(runs), HISTORY), build))


if __name__ == "__main__":
    sys.exit(main())
