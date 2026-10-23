# overlord

A daily health check of everything Jay runs at home, starting with **uba5** and
**cookiepi**. Every morning at 06:30 Eastern:

1. A root-owned, read-only **collector** gathers facts on uba5: host, systemd
   (including services that must always run), journal errors, apt updates, Docker
   containers, the OTA chain (hdhr-ac4 and the HDHomeRun tuner), signs of
   intrusion, Cookie-Cam, go2rtc, cookiepi, and overlord's own recent runs.
   Everything passes through a secret-redaction filter.
2. **Claude** (headless Claude Code, no tools) reads the facts on stdin and
   answers with a short report: `status` ok / warn / problem, a `summary` and
   `report_md`.
3. The **runner** emails it to Jay (every run), updates the **status site**
   (http://10.0.0.33:8090/, login required), and posts it to Cookie-Cam's
   `/ui/system` card (cookie-cam Ticket 89).

Fixes never happen here. A problem in a report becomes a ticket in the right repo.

## What it watches on uba5

Settings at the top of `collect/uba5.sh`:

- **Expected services** (`EXPECTED_UNITS`): docker, containerd (docker-ce since
  cookie-cam Ticket 94), ssh, nginx, php8.1-fpm, overlord-web, cron, ufw, vsftpd.
  A service that is stopped or not enabled is
  a problem, not just a failed one.
- **OTA chain:** hdhr-ac4 (muxes AC-4 audio so channel 6 plays) must answer on
  8080 and 5004, and its `HDHR_IP` must match `TUNER_IPS`. The tuner has no DHCP
  reservation yet; if it moves, the report shows where (SiliconDust MACs in ARP).
- **FTP uploads:** the Back Yard camera uploads clips by FTPS to vsftpd and
  never retries, so vsftpd downtime loses clips. The `ftp` section checks that
  vsftpd listens on `FTP_LISTEN` and keeps its boot guard (waits for the
  network, restarts on failure), counts the last 24 h of vsftpd's log, and
  reports the newest stored clip per camera in `FTP_CAMERAS` (warn after
  `FTP_STALE_HOURS`), uploads stuck waiting for Cookie-Cam's ingest, and
  rejected clips. More FTP cameras: extend `FTP_CAMERAS`.
- **Intrusion signs**, added after Plex was compromised on 2026-10-17 and retired
  on 2026-10-22: the top CPU processes, outside connections made by any user not
  in `OUTBOUND_OK_USERS` (root, sysjay, sysai), executables owned by system
  accounts in `/tmp`, `/var/tmp` and `/dev/shm`, and Plex coming back.
  If a legitimate service needs to connect out, add its user to
  `OUTBOUND_OK_USERS` and rerun `install.sh`.

## Safety model

- Everything runs as its own account, **sysai**, which can change nothing. It is
  not in `docker` (that is root on uba5) or `go2rtc`, has no password, and has
  no sudo except running the one collector with no arguments
  (`sudoers/overlord`). `install.sh` enforces this every time it runs.
- Claude runs with `--bare --tools ""` and no MCP servers. The only tool it has
  is Claude Code's internal `StructuredOutput`, which returns the answer. The
  runner fails a run if any other tool shows up.
- The collector's facts are never published. Only the report goes out.
- The go2rtc section keeps only stream names and counts, because its sources
  hold the Front Door login.

## Setup (once)

```bash
# 1. secrets: Jay, with an editor, never pasted into a chat
sudo -u sysai mkdir -p -m 700 /home/sysai/.config/overlord /home/sysai/runs
sudo cp config/env.example     /home/sysai/.config/overlord/env
sudo cp config/msmtprc.example /home/sysai/.config/overlord/msmtprc
sudo chown sysai:sysai /home/sysai/.config/overlord/{env,msmtprc}
sudo chmod 600 /home/sysai/.config/overlord/{env,msmtprc}
sudoedit /home/sysai/.config/overlord/env        # API key, site login
sudoedit /home/sysai/.config/overlord/msmtprc    # Gmail app password

# 2. install (idempotent; rerun after any change)
sudo ./install.sh
```

- **API key:** in the Claude Console, create a key named `overlord`, ideally in
  its own workspace with a monthly spend limit (e.g. $5).
- **Gmail app password:** Google account → Security → App passwords (needs
  2-Step Verification).
- **Claude Code:** `install.sh` copies your own installed version to
  `/usr/local/bin/claude` (root-owned, so sysai can run it but not change it).
  Rerun `install.sh` after updating Claude Code to update overlord's copy.

`install.sh` also installs any missing packages (`msmtp`, `smartmontools`,
`jq`, `curl`), the collector and redaction filter in `/usr/local/sbin/`, the
runner, prompt, schema, site renderer and web server in
`/usr/local/lib/overlord/`, the sudoers rule (checked with `visudo -cf`), and the
systemd units. It enables the timer and starts the web server.

## Running

| What | How |
|---|---|
| Run now | `sudo systemctl start overlord.service` |
| Its log | `journalctl -u overlord -n 50` |
| Next run | `systemctl list-timers overlord.timer` |
| Site server | `systemctl status overlord-web` |
| One run's files | `/home/sysai/runs/<run_id>/`: `facts.txt`, `result.json`, `report.json`, `email.txt` |
| Ledger | `/home/sysai/runs/ledger.csv`: run_id, status, cost_usd, model, duration_s |

Extra runs are fine whenever something feels off (e.g. the LAN is slow): each
`sudo systemctl start overlord.service` costs one run.

Run folders older than 90 days are deleted after each run. The site shows only
runs whose folders still exist.

## Reading a report

The subject says `[overlord] OK|WARN|PROBLEM|ERROR - <summary>`.

- **PROBLEM:** something is broken or about to break. Look at "Needs action".
- **WARN:** trends to watch, such as pending security updates, a required
  reboot or repeated errors.
- **OK:** nothing needs you.
- **ERROR:** overlord itself failed (collector, Claude, budget cap, bad answer).
  The summary says which step. The run folder has the details.

The status site shows the latest badge and report, costs, and a history table
of the last 90 runs. It shows a red "No run since …" banner when the newest run
is over 26 h old (checked again in the browser, so an old page still warns).

## Costs

Each run records Claude Code's `total_cost_usd` in the ledger and has a hard
`--max-budget-usd 0.50` cap. The cap is checked against Claude Code's own
estimate, so a run can slightly exceed it. The API key's workspace spend limit
in the Claude Console is the real backstop. Every email ends with
"Cost this run $X · this month $Y (N runs)", and the site shows this run, this
month and the last 30 days.

## Repo layout

See `CLAUDE.md` (conventions and the install map) and `TICKETS.md` (open tickets).
