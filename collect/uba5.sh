#!/bin/bash
# overlord collector for uba5. Runs as root via sudo, takes no arguments,
# writes plain-text sections to stdout. Read only: it never restarts, edits,
# deletes or writes anything. Always exits 0; a broken section prints
# "SECTION FAILED: <why>". Everything passes through overlord-redact.
# Installed as /usr/local/sbin/overlord-collect-uba5.
set -u
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin  # docker is a snap on uba5

TOTAL_CAP=200000     # bytes, whole output
SECTION_CAP=30000    # bytes, per section
SECTION_TIMEOUT=60   # seconds, per section
LEDGER=/home/sysai/runs/ledger.csv
COOKIEPI=http://10.0.0.133/status

here=$(dirname "$(readlink -f "$0")")
if [ -x "$here/overlord-redact" ]; then REDACT="$here/overlord-redact"
else REDACT="$here/redact.sh"; fi

have() { command -v "$1" >/dev/null 2>&1; }

# count identical lines, most frequent first: "  12x message"
dedupe() { sort | uniq -c | sort -rn | awk '{c=$1; $1=""; printf "%5dx%s\n", c, substr($0,1,300)}'; }

sec_host() {
    echo "hostname: $(hostname)"
    uptime
    echo "loadavg: $(cat /proc/loadavg)"
    free -h
    echo; df -h -x tmpfs -x devtmpfs -x squashfs -x overlay
    echo; df -i -x tmpfs -x devtmpfs -x squashfs -x overlay
    echo
    if have sensors; then sensors 2>/dev/null | grep -E '^[A-Za-z].*:|°C' | head -40
    else echo "sensors: not installed"; fi
    echo
    if have smartctl; then
        local d
        for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
            echo "/dev/$d: $(smartctl -H "/dev/$d" 2>&1 | grep -iE 'overall-health|SMART Health Status|result' | head -1)"
        done
    else echo "smartctl: not installed"; fi
}

sec_systemd() {
    echo "failed units:"
    systemctl --failed --no-legend --no-pager
    echo; echo "timers (all):"
    systemctl list-timers --all --no-pager
}

sec_journal() {
    local lines
    lines=$(journalctl -p err --since "24 hours ago" -o short --no-hostname --no-pager -q \
        | cut -d' ' -f4- | sed -E 's/^([^[:space:]]+)\[[0-9]+\]:/\1:/')
    echo "error-or-worse lines in last 24 h: $(grep -c . <<<"$lines")"
    if [ -n "$lines" ]; then dedupe <<<"$lines" | head -60; fi
}

sec_updates() {
    if [ -x /usr/lib/update-notifier/apt-check ]; then
        local r
        r=$(/usr/lib/update-notifier/apt-check 2>&1)
        echo "pending updates: ${r%%;*}; security updates: ${r##*;}"
    else
        echo "pending updates: $(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst')"
        echo "security updates: $(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep '^Inst' | grep -ci security)"
    fi
    if [ -f /var/run/reboot-required ]; then
        echo "reboot required: yes ($(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null | head -c 500))"
    else echo "reboot required: no"; fi
}

sec_docker() {
    have docker || { echo "SECTION FAILED: docker not installed"; return 0; }
    docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' || return 1
    echo
    docker ps -aq | xargs -r docker inspect --format \
        '{{.Name}} restarts={{.RestartCount}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} started={{.State.StartedAt}}'
    local c
    for c in $(docker ps --format '{{.Names}}'); do
        echo; echo "-- $c: warn/error log lines, last 24 h (deduplicated)"
        docker logs --since 24h "$c" 2>&1 \
            | grep -iE 'warn|error|exception|traceback|critical|fatal' \
            | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.,]+Z?[[:space:]]*//; s/^\[[^]]*\][[:space:]]*//' \
            | dedupe | head -25 | head -c 4000
    done
}

sec_cookiecam() {
    local h s
    h=$(curl -s -m 5 http://127.0.0.1:5000/health) || { echo "SECTION FAILED: /health unreachable"; return 0; }
    echo "/health:"; jq . <<<"$h" 2>/dev/null || head -c 2000 <<<"$h"
    s=$(curl -s -m 5 http://127.0.0.1:5000/api/status) || { echo "SECTION FAILED: /api/status unreachable"; return 0; }
    echo; echo "/api/status (cameras, stalls, recording, buffer):"
    jq '{engine: {uptime_seconds: .engine.uptime_seconds, buffer: .engine.buffer},
         cameras: [.cameras[]? | {id, name, recording: (.recording != null),
                                  trigger: .recording.trigger_source, stall}]}' <<<"$s" 2>/dev/null \
        || echo "SECTION FAILED: /api/status is not JSON"
}

sec_go2rtc() {
    local r
    r=$(curl -s -m 5 http://127.0.0.1:1984/api/streams) || { echo "SECTION FAILED: go2rtc API unreachable"; return 0; }
    # sources hold the Front Door login: keep ONLY names and counts, never raw output
    jq -r 'to_entries[] | "\(.key) producers=\((.value.producers // []) | length) consumers=\((.value.consumers // []) | length)"' \
        <<<"$r" 2>/dev/null || echo "SECTION FAILED: go2rtc answer is not the expected JSON"
}

sec_cookiepi() {
    local r rc
    r=$(curl -s -m 5 "$COOKIEPI"); rc=$?
    if [ $rc -ne 0 ]; then echo "cookiepi UNREACHABLE: curl exit $rc at $COOKIEPI"; return 0; fi
    jq '{version, uptime_s, camera_ok, cpu_temp_c, load, throttled, rssi, mqtt, pir, readers}' \
        <<<"$r" 2>/dev/null || echo "SECTION FAILED: cookiepi /status is not JSON"
}

sec_overlord() {
    if [ -r "$LEDGER" ]; then
        echo "last 7 runs (run_id,status,cost_usd,model,duration_s):"
        tail -n +2 "$LEDGER" | tail -n 7
    else echo "no ledger yet (first run)"; fi
}

section() {
    local name=$1 fn=$2 out rc
    echo "===== $name ====="
    out=$(timeout "$SECTION_TIMEOUT" bash -c "$fn" 2>&1)
    rc=$?
    printf '%s\n' "$out" | head -c "$SECTION_CAP"
    [ "${#out}" -gt "$SECTION_CAP" ] && echo "[section cut at $SECTION_CAP bytes]"
    if [ $rc -eq 124 ]; then echo "SECTION FAILED: timed out after ${SECTION_TIMEOUT}s"
    elif [ $rc -ne 0 ]; then echo "SECTION FAILED: exit code $rc"; fi
    echo
}

export LEDGER COOKIEPI
export -f have dedupe sec_host sec_systemd sec_journal sec_updates sec_docker \
    sec_cookiecam sec_go2rtc sec_cookiepi sec_overlord

{
    echo "overlord facts: uba5, collected $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    section host sec_host
    section systemd sec_systemd
    section journal sec_journal
    section updates sec_updates
    section docker sec_docker
    section cookie-cam sec_cookiecam
    section go2rtc sec_go2rtc
    section cookiepi sec_cookiepi
    section overlord sec_overlord
} 2>&1 | "$REDACT" | head -c "$TOTAL_CAP"
exit 0
