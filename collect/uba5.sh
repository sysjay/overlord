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
# units that must always be running (Jay, 2026-10-22); Plex is retired, not expected
EXPECTED_UNITS="snap.docker.dockerd ssh nginx php8.1-fpm overlord-web cron ufw"
# HDHomeRun tuner(s). TODO: no DHCP reservation yet, so the address can move
# (it did: .239 -> .244); the ota section lists SiliconDust MACs seen in ARP.
TUNER_IPS="10.0.0.244"
HDHR_AC4=hdhr-ac4    # container that muxes AC-4 audio so channel 6 plays
# users allowed to hold connections to outside (non-LAN) addresses
OUTBOUND_OK_USERS="root sysjay sysai"

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
    local u act en since nr
    echo "expected services:"
    for u in $EXPECTED_UNITS; do
        act=$(systemctl is-active "$u" 2>/dev/null)
        en=$(systemctl is-enabled "$u" 2>/dev/null)
        since=$(systemctl show "$u" -p ActiveEnterTimestamp --value 2>/dev/null)
        nr=$(systemctl show "$u" -p NRestarts --value 2>/dev/null)
        printf '%s active=%s enabled=%s since=%s restarts=%s' \
            "$u" "${act:-unknown}" "${en:-unknown}" "${since:-n/a}" "${nr:-n/a}"
        [ "$act" = active ] || printf '  EXPECTED BUT NOT ACTIVE'
        [ "$en" = enabled ] || printf '  EXPECTED BUT NOT ENABLED'
        echo
    done
    echo; echo "failed units:"
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

sec_ota() {
    local p code hdhr ip d s arp
    # hdhr-ac4 serves its UI on 8080/ and streams on 5004 (404 on / is normal there)
    for p in 8080/ 8080/discover.json 5004/; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p")
        echo "$HDHR_AC4 :$p http=$code"   # 000 = no answer
    done
    if have docker; then
        # only HDHR_IP from the container's env, nothing else
        hdhr=$(docker inspect "$HDHR_AC4" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | sed -n 's/^HDHR_IP=//p' | head -1)
        echo "$HDHR_AC4 HDHR_IP=${hdhr:-unknown}"
        if [ -n "$hdhr" ]; then
            case " $TUNER_IPS " in
                *" $hdhr "*) ;;
                *) echo "HDHR_IP MISMATCH: $HDHR_AC4 points at $hdhr, tuner list is $TUNER_IPS" ;;
            esac
        fi
    fi
    echo
    for ip in $TUNER_IPS; do
        d=$(curl -s -m 5 "http://$ip/discover.json")
        if [ -z "$d" ]; then echo "tuner $ip UNREACHABLE"; continue; fi
        jq -r --arg ip "$ip" '"tuner \($ip) model=\(.ModelNumber) firmware=\(.FirmwareVersion) tuners=\(.TunerCount)"' \
            <<<"$d" 2>/dev/null || echo "tuner $ip: discover.json is not JSON"
        s=$(curl -s -m 5 "http://$ip/status.json")
        jq -r --arg ip "$ip" '"tuner \($ip) in use: \([.[] | select(.VctNumber or .TargetIP)] | length) of \(length)"' \
            <<<"$s" 2>/dev/null || echo "tuner $ip: status.json unreadable"
    done
    arp=$(ip neigh 2>/dev/null | awk 'tolower($0) ~ /lladdr 00:18:dd/ {printf "%s(%s) ", $1, $NF}')
    echo "SiliconDust devices in ARP table: ${arp:-none}"
}

# stdin: `ss -Htnp state established`; $1: own global IPv6 /64 prefixes ("a:b:c:d: ..."),
# $2: local listening ports. stdout: "<pid> lan|in|out" per connection that has a
# process: lan = LAN peer, in = outside peer that connected to us, out = we connected out.
conn_class() {
    awk -v pfx="$1" -v lports=" $2 " '
        BEGIN { n = split(pfx, P, " ") }
        {
            peer = $4
            if (peer ~ /^\[/) { sub(/^\[/, "", peer); sub(/\].*$/, "", peer) } else sub(/:[0-9]+$/, "", peer)
            sub(/^::ffff:/, "", peer); peer = tolower(peer)
            lan = (peer ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|169\.254\.)/ || peer == "::1" \
                   || peer ~ /^(fe80|fc|fd)/)
            if (!lan) { split(peer, h, ":"); p4 = h[1] ":" h[2] ":" h[3] ":" h[4] ":"
                        for (i = 1; i <= n; i++) if (p4 == P[i]) lan = 1 }
            lp = $3; sub(/.*:/, "", lp)
            cls = lan ? "lan" : (index(lports, " " lp " ") ? "in" : "out")
            if (match($0, /pid=[0-9]+/)) print substr($0, RSTART + 4, RLENGTH - 4), cls
        }'
}

# stdin: "<user> lan|in|out" per connection; $1: users allowed to connect out
conn_by_user() {
    awk -v ok=" $1 " '
        { u[$1] = 1; c[$1, $2]++ }
        END { for (x in u) {
                  printf "%s lan=%d outside_in=%d outside_out=%d", x, c[x, "lan"], c[x, "in"], c[x, "out"]
                  if (c[x, "out"] > 0 && index(ok, " " x " ") == 0) printf "  UNEXPECTED OUTBOUND"
                  print "" } }' | sort
}

sec_security() {
    local pfx lports pid cls u n st act
    echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg) (cpus: $(nproc))"
    echo "top 5 processes by CPU (%cpu is the average over each process's life):"
    ps -eo user:16,pid,pcpu,etime,comm --sort=-pcpu | head -6
    echo
    echo "established TCP connections by user (counts only; outside_in = visitors to our ports):"
    pfx=$(ip -6 -o addr show scope global 2>/dev/null \
        | awk '{split($4, a, "/"); split(a[1], h, ":"); print tolower(h[1] ":" h[2] ":" h[3] ":" h[4] ":")}' \
        | sort -u | tr '\n' ' ')
    lports=$(ss -Htln 2>/dev/null | awk '{p = $4; sub(/.*:/, "", p); print p}' | sort -u | tr '\n' ' ')
    ss -Htnp state established 2>/dev/null | conn_class "$pfx" "$lports" \
        | while read -r pid cls; do
              u=$(ps -o user:32= -p "$pid" 2>/dev/null | tr -d ' ')
              echo "${u:-?} $cls"
          done | conn_by_user "$OUTBOUND_OK_USERS"
    echo
    echo "executables in /tmp, /var/tmp, /dev/shm owned by system accounts:"
    find /tmp /var/tmp /dev/shm -xdev -maxdepth 4 -type f -perm /111 \
        \( \( -uid -1000 ! -uid 0 \) -o -uid 65534 \) \
        -printf 'UNEXPECTED EXECUTABLE: %u %s bytes %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null \
        | head -30 | grep . || echo "none"
    echo
    # Plex was retired after a compromise (2026-10-22); it must stay gone
    st=$(dpkg-query -W -f='${db:Status-Status}' plexmediaserver 2>/dev/null)
    act=$(systemctl is-active plexmediaserver 2>/dev/null)
    n=$(pgrep -c -u plex 2>/dev/null); n=${n:-0}
    echo "plex: package=${st:-not-installed} unit=${act:-unknown} processes=$n"
    if [ "$st" = installed ] || [ "$act" = active ] || [ "$n" -gt 0 ]; then echo "PLEX IS BACK"; fi
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

export LEDGER COOKIEPI EXPECTED_UNITS TUNER_IPS HDHR_AC4 OUTBOUND_OK_USERS
export -f have dedupe sec_host sec_systemd sec_journal sec_updates sec_docker \
    sec_ota conn_class conn_by_user sec_security \
    sec_cookiecam sec_go2rtc sec_cookiepi sec_overlord

{
    echo "overlord facts: uba5, collected $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    section host sec_host
    section systemd sec_systemd
    section journal sec_journal
    section updates sec_updates
    section docker sec_docker
    section ota sec_ota
    section security sec_security
    section cookie-cam sec_cookiecam
    section go2rtc sec_go2rtc
    section cookiepi sec_cookiepi
    section overlord sec_overlord
} 2>&1 | "$REDACT" | head -c "$TOTAL_CAP"
exit 0
