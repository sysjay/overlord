# Overlord: Claude Code Instructions

Overlord is a daily health check of everything Jay runs at home, starting with
uba5 and cookiepi. Every morning a root-owned collector gathers facts, headless
Claude Code (no tools) writes a short report, and the runner emails it, updates
overlord's status site and posts it to Cookie-Cam's `/ui/system` card.
Maintainer: Jay (single developer). Planning happens in claude.ai; Claude Code
executes tickets.

## Your role: ticket executor

- Implement the ticket you are given. Do not redesign architecture on your own.
- Only modify files the ticket lists. If another file must change, stop and say
  which file and why before editing it.
- If a ticket is ambiguous, conflicts with this file, or would need an
  architectural decision, stop and ask instead of guessing.
- Keep changes minimal and focused. No drive-by refactors or reformatting.
- When done, summarize: files changed, what changed, how Jay should verify it.
- Every ticket has a `FILES` section right after its title: each file it will
  change, by repo path. These are the files you may modify. If a ticket has no
  `FILES` section, or a file it needs is missing from it, ask Jay before editing.

## Ticket lifecycle

1. Ticket files are named `ticket-NN-short-name.txt`. The next number is one
   higher than the highest number in the repo root or `closed-tickets/`.
2. Every open ticket starts with a status header, then a blank line:
   `Priority:` (P1 / P2 / P3; Jay sets it, ask if a new ticket has none),
   `Status:` (In progress / Waiting / Blocked / Not started), `Next action:`,
   `Waiting on:` (`-` if nothing), `Updated:` (YYYY-MM-DD). Whenever you
   create, work on, or close a ticket, update its header and the ticket's row
   in `TICKETS.md` (kept by hand until a generator exists). Use `?` for
   anything you can't determine and tell Jay.
3. After a ticket's changes are verified, run the docs sync: `README.md` (if
   setup, features, costs or architecture changed) and `TICKETS.md`.
4. Close the ticket: rename to `ticket-NN-short-name-closed.txt`, move it into
   `closed-tickets/`, and remove its row from `TICKETS.md`.

## Overlord rules

- **Collectors are read only.** A collector never restarts, edits, deletes or
  writes anything outside its own output (stdout).
- **Every collector's output passes through `collect/redact.sh`.** Never print
  or send passwords, tokens, API keys, Wi-Fi keys or credentials in URLs. A new
  pattern in redact.sh gets a sample in its `--selftest`.
- **Claude runs with no tools** (`--tools ""`) unless a ticket says otherwise.
  The facts arrive on stdin; Claude only answers.
- **Fixes never happen here.** A problem in a report becomes a ticket in the
  right repo (e.g. cookie-cam).
- The go2rtc section keeps only stream names and producer/consumer counts; its
  sources hold the Front Door login. Never print raw `/api/streams` output.
- The collector's facts are for Claude only; they are never published on the
  status site or emailed.

## Layout

| Repo file | Installed as | Owner / mode |
|---|---|---|
| `collect/uba5.sh` | `/usr/local/sbin/overlord-collect-uba5` | root 755 |
| `collect/redact.sh` | `/usr/local/sbin/overlord-redact` | root 755 |
| `run/overlord-run.sh` | `/usr/local/lib/overlord/overlord-run.sh` | root 755 |
| `run/prompt.md`, `run/report.schema.json` | `/usr/local/lib/overlord/` | root 644 |
| `run/render_site.py`, `web/overlord_web.py` | `/usr/local/lib/overlord/` | root 755 |
| `systemd/*` | `/etc/systemd/system/` | root 644 |
| `sudoers/overlord` | `/etc/sudoers.d/overlord` | root 440 |
| `config/*.example` | `/home/sysai/.config/overlord/{env,msmtprc}` | sysai 600 |

Runtime data (sysai's): `/home/sysai/runs/<run_id>/` (facts.txt, result.json,
report.json), `/home/sysai/runs/ledger.csv`, `/home/sysai/site` (a symlink to
the current build in `/home/sysai/site-builds/`).

## The sysai account

- Not in `docker` (that is root on uba5), not in `go2rtc`, no password, and no
  sudo except running the one collector with no arguments. `install.sh`
  enforces this every time it runs.
- Its secrets live only in `/home/sysai/.config/overlord/env` and `msmtprc`
  (mode 600). Never read, print or commit them; refer to them by variable name.

## Commands you must not run

- `sudo` on uba5 is Jay's: print the commands, never run them. That includes
  `install.sh`, `systemctl start overlord.service` and anything as `sysai`.
- Never run the collector or the runner against the live system yourself;
  test pieces with sample data instead.

## Access to Jay's systems

Read-only checks on uba5 (curl to local health endpoints, `which`, versions)
are fine. When done, say which system you accessed, how, and what changed.

## Git

- Private `github.com/sysjay/overlord` is `origin`. Push at the end of each work
  session.
- Never commit `env`, `msmtprc` or `runs/` (see `.gitignore`).
