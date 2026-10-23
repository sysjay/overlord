#!/bin/bash
# overlord collector for uba5. Runs as root via sudo, takes no arguments,
# writes plain-text sections to stdout. Read only: it never restarts, edits,
# deletes or writes anything. Always exits 0; a broken section prints
# "SECTION FAILED: <why>". Everything passes through overlord-redact.
# Installed as /usr/local/sbin/overlord-collect-uba5.
set -u
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin  # docker is docker-ce (/usr/bin) since cookie-cam Ticket 94

TOTAL_CAP=200000     # bytes, whole output
SECTION_CAP=30000    # bytes, per section
SECTION_TIMEOUT=60   # seconds, per section
LEDGER=/home/sysai/runs/ledger.csv
COOKIEPI=http://10.0.0.133/status
# units that must always be running (Jay, 2026-10-22); Plex is retired, not expected
# (Jay, 2026-10-23: Docker is docker-ce since cookie-cam Ticket 94; vsftpd receives
# the Back Yard uploads)
EXPECTED_UNITS="docker containerd ssh nginx php8.1-fpm overlord-web cron ufw vsftpd"
# HDHomeRun tuner(s). TODO: no DHCP reservation yet, so the address can move
# (it did: .239 -> .244); the ota section lists SiliconDust MACs seen in ARP.
TUNER_IPS="10.0.0.244"
HDHR_AC4=hdhr-ac4    # container that muxes AC-4 audio so channel 6 plays
# users allowed to hold connections to outside (non-LAN) addresses
OUTBOUND_OK_USERS="root sysjay sysai"
# FTP cameras (cookie-cam Ticket 91): vsftpd receives their uploads in
# FTP_ROOT/<camera>/YYYY/MM/DD/; cookie-cam's ftp_ingest stores the clips in
# VIDEO_DIR as <camera>_<UTC>_ftp.mp4 (keeping the upload's mtime) and moves
# anything else (the camera's JPG snapshots) to FTP_ROOT/<camera>/_rejected/.
FTP_ROOT=/home/ftp/reolink
FTP_CAMERAS="backyard"
FTP_LISTEN=10.0.0.33:21
FTP_LOG=/var/log/vsftpd.log    # vsftpd's own format; times are UTC (use_localtime unset)
VIDEO_DIR=/home/sysjay/projects/cookie-cam/data/videos
FTP_STALE_HOURS=24   # the camera only uploads on motion
FTP_BACKLOG_MIN=30   # ingest normally takes an upload within a minute
# probes (Ticket 03): registry, and the alerter's record of alerts sent
PROBE_REGISTRY=/usr/local/lib/overlord/probes/registry.json
ALERTS_LOG=/home/sysai/runs/alerts.jsonl

here=$(dirname "$(readlink -f "$0")")
if [ -x "$here/overlord-redact" ]; then REDACT="$here/overlord-redact"
else REDACT="$here/redact.sh"; fi

# shared with the probes: tmp_executables
if [ -r /usr/local/lib/overlord/probes/lib.sh ]; then . /usr/local/lib/overlord/probes/lib.sh
else . "$here/../probes/lib.sh"; fi

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
    tmp_executables | sed 's/^/UNEXPECTED EXECUTABLE: /' | grep . || echo "none"
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

# stdin: vsftpd log lines (own format, UTC times); $1: oldest epoch to count.
# Counts only; a file name is reduced to its camera folder.
ftp_log_summary() {
    TZ=UTC awk -v since="$1" '
        BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
                for (i in m) mon[m[i]] = i }
        function cam() { return match($0, /", "\/[^\/"]+\//) ? substr($0, RSTART + 5, RLENGTH - 6) : "(top level)" }
        {
            split($4, t, ":")
            ts = mktime($5 " " mon[$2] " " $3 " " t[1] " " t[2] " " t[3])
            if (ts < since) next
            client = match($0, /Client "[^"]*"/) ? substr($0, RSTART + 8, RLENGTH - 9) : "?"
            if (/ OK UPLOAD: /) {
                c = cam(); if (/\.mp4", /) { clips[c]++; if (ts > last) { last = ts; lastcam = c } } else other[c]++; cams[c] = 1
            }
            else if (/ FAIL UPLOAD: /) { c = cam(); fu[c]++; cams[c] = 1; nfu++ }
            else if (/ FAIL LOGIN: /) { fl[client]++; nfl++ }
            else if (/ OK LOGIN: /) { ok[client]++; nok++ }
            else if (/ CONNECT: /) nconn++
        }
        END {
            printf "last 24 h: CONNECT=%d OK LOGIN=%d FAIL LOGIN=%d FAIL UPLOAD=%d\n", nconn, nok, nfl, nfu
            for (c in cams) printf "  %s: OK UPLOAD clips=%d other=%d, FAIL UPLOAD=%d\n", c, clips[c], other[c], fu[c]
            if (last) print "  last OK UPLOAD of a clip: " strftime("%Y-%m-%d %H:%M UTC", last, 1) " (" lastcam ")"
            else print "  last OK UPLOAD of a clip: none in 24 h"
            for (a in ok) printf "  OK LOGIN from %s: %d\n", a, ok[a]
            for (a in fl) printf "  FAIL LOGIN from %s: %d%s\n", a, fl[a], (a in ok) ? "" : " (address never logged in OK)"
        }'
}

sec_ftp() {
    local dp after rs nr lines f now cam d newest n24 w oldest rj rjo
    if ss -Hltn 2>/dev/null | awk -v l="$FTP_LISTEN" '$4 == l { f = 1 } END { exit !f }'; then
        echo "vsftpd listening on $FTP_LISTEN: yes"
    else echo "VSFTPD NOT LISTENING on $FTP_LISTEN"; fi
    dp=$(systemctl show vsftpd -p DropInPaths --value 2>/dev/null)
    after=$(systemctl show vsftpd -p After --value 2>/dev/null)
    rs=$(systemctl show vsftpd -p Restart --value 2>/dev/null)
    nr=$(systemctl show vsftpd -p NRestarts --value 2>/dev/null)
    echo "boot guard: drop-ins=${dp:-none} restart=${rs:-?} restarts=${nr:-?}"
    case " $after " in *" network-online.target "*) ;; *) dp= ;; esac
    if [ -z "$dp" ] || [ "$rs" != on-failure ]; then
        echo "VSFTPD BOOT GUARD MISSING (needs After=network-online.target and Restart=on-failure)"
    fi
    lines=$(journalctl -b -u vsftpd -p warning -o cat --no-pager -q 2>/dev/null)
    echo "vsftpd journal, warning or worse this boot: $(grep -c . <<<"$lines")"
    if [ -n "$lines" ]; then tail -n 20 <<<"$lines" | dedupe | head -3; fi
    echo
    if [ -r "$FTP_LOG" ]; then
        echo "vsftpd log $FTP_LOG:"
        for f in "$FTP_LOG.1" "$FTP_LOG"; do [ -r "$f" ] && cat "$f"; done \
            | ftp_log_summary "$(( $(date +%s) - 86400 ))"
    else echo "vsftpd log $FTP_LOG: not found"; fi
    now=$(date +%s)
    for cam in $FTP_CAMERAS; do
        echo
        echo "camera $cam:"
        if [ -d "$VIDEO_DIR" ]; then
            newest=$(find "$VIDEO_DIR" -maxdepth 1 -name "${cam}_*_ftp.mp4" -printf '%T@\n' 2>/dev/null \
                | sort -n | tail -1); newest=${newest%.*}
            n24=$(find "$VIDEO_DIR" -maxdepth 1 -name "${cam}_*_ftp.mp4" -mmin -1440 2>/dev/null | wc -l)
            if [ -n "$newest" ]; then
                echo "  newest stored clip: $(date -d "@$newest" '+%Y-%m-%d %H:%M %Z'), age $(( (now - newest) / 3600 )) h; clips stored in last 24 h: $n24"
            else echo "  newest stored clip: none"; fi
            if [ -z "$newest" ] || [ $(( now - newest )) -gt $(( FTP_STALE_HOURS * 3600 )) ]; then
                echo "  NO ${cam^^} UPLOAD IN ${FTP_STALE_HOURS}H"
            fi
        else echo "  video dir $VIDEO_DIR: not found"; fi
        d=$FTP_ROOT/$cam
        if [ -d "$d" ]; then
            w=$(find "$d" -path "$d/_rejected" -prune -o -type f -printf '%T@\n' 2>/dev/null | sort -n)
            oldest=$(head -1 <<<"$w"); oldest=${oldest%.*}
            echo "  uploads waiting for ingest: $(grep -c . <<<"$w")"
            if [ -n "$oldest" ] && [ $(( now - oldest )) -gt $(( FTP_BACKLOG_MIN * 60 )) ]; then
                echo "  FTP INGEST BACKLOG: $(awk -v c=$(( now - FTP_BACKLOG_MIN * 60 )) '$1 < c' <<<"$w" | wc -l) waiting over ${FTP_BACKLOG_MIN} min, oldest $(( (now - oldest) / 60 )) min"
            fi
            rj=$(find "$d/_rejected" -type f -name '*.mp4' -mmin -1440 2>/dev/null | wc -l)
            rjo=$(find "$d/_rejected" -type f ! -name '*.mp4' -mmin -1440 2>/dev/null | wc -l)
            echo "  rejected in last 24 h: clips=$rj other=$rjo (other = the camera's snapshots, expected)"
            [ "$rj" -gt 0 ] && echo "  FTP REJECTED CLIPS: $rj"
        else echo "  upload dir $d: not found"; fi
    done
    return 0
}

# each probe in the registry: last run, stale or not, last 24 h by severity,
# its findings deduplicated (count, last seen), alerts sent. Summaries only.
sec_probes() {
    local reg=$PROBE_REGISTRY now name iv log
    [ -r "$reg" ] || reg=$here/../probes/registry.json
    [ -r "$reg" ] || { echo "no probes installed yet (no registry at $PROBE_REGISTRY)"; return 0; }
    now=$(date +%s)
    echo "probes that exist (registry):"
    jq -r '.[] | "  \(.name): every \(.interval_s) s, alerts \(.route): \(.purpose)"' "$reg"
    jq -r '.[] | "\(.name) \(.interval_s) \(.log)"' "$reg" | while read -r name iv log; do
        echo; echo "-- probe $name"
        if [ ! -r "$log" ]; then echo "  log $log: not found"; echo "  PROBE STALE: $name has no log"; continue; fi
        tail -n 3000 "$log" | jq -sr --argjson now "$now" --argjson iv "$iv" --arg name "$name" '
            map(. + {e: (.ts | fromdateiso8601? // 0)}) as $all
            | ($all | map(select(.metrics)) | last) as $l
            | [$all[] | select(.e >= $now - 86400)] as $d
            | [$d[] | select(.metrics)] as $runs
            | if $l == null then "  no runs logged", "  PROBE STALE: \($name) has no runs"
              else
                "  last run: \($l.ts) (\(($now - $l.e) / 60 | floor) min ago), severity \($l.severity), \($l.ms) ms, metrics \($l.metrics | tojson)",
                (if $now - $l.e > 3 * $iv then "  PROBE STALE: \($name) has not run for \(($now - $l.e) / 60 | floor) min" else empty end),
                "  last 24 h: runs=\($runs | length) ok=\([$runs[] | select(.severity == "ok")] | length) warn=\([$runs[] | select(.severity == "warn")] | length) critical=\([$runs[] | select(.severity == "critical")] | length)",
                ([$d[] | .e as $e | .findings[]? | {k: "\(.check) \(.severity): \(.detail)", e: $e}]
                 | group_by(.k) | map({k: .[0].k, n: length, last: (map(.e) | max)})
                 | sort_by(-.last) | .[:20][]
                 | "  \(.n)x, last \(.last | todate): \(.k)")
              end'
        if [ -r "$ALERTS_LOG" ]; then
            jq -sr --argjson now "$now" --arg name "$name" '
                [.[] | select(.probe == $name and ((.ts | fromdateiso8601? // 0) >= $now - 86400))]
                | "  alerts last 24 h: \(length)", (.[] | "    \(.ts) \(.severity) \(.checks | join(",")): \(.how)\(if .sent then "" else " (EMAIL FAILED)" end)")' \
                "$ALERTS_LOG" 2>/dev/null
        else echo "  alerts last 24 h: 0 (no alert log yet)"; fi
    done
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

export LEDGER COOKIEPI EXPECTED_UNITS TUNER_IPS HDHR_AC4 OUTBOUND_OK_USERS \
    FTP_ROOT FTP_CAMERAS FTP_LISTEN FTP_LOG VIDEO_DIR FTP_STALE_HOURS FTP_BACKLOG_MIN \
    PROBE_REGISTRY ALERTS_LOG here
export -f have dedupe sec_host sec_systemd sec_journal sec_updates sec_docker \
    sec_ota conn_class conn_by_user tmp_executables sec_security \
    sec_cookiecam ftp_log_summary sec_ftp sec_probes sec_go2rtc sec_cookiepi sec_overlord

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
    section probes sec_probes
    section cookie-cam sec_cookiecam
    section ftp sec_ftp
    section go2rtc sec_go2rtc
    section cookiepi sec_cookiepi
    section overlord sec_overlord
} 2>&1 | "$REDACT" | head -c "$TOTAL_CAP"
exit 0
