#!/bin/bash
# overlord probe helpers. Sourced by every probe (probes/*.sh) and by the
# collector (tmp_executables); sourcing only defines functions.
# A probe calls: probe_init <name>; finding <check> <severity> <detail> (any
# number); probe_finish '<metrics json>'. probe_finish appends one JSON line to
# <log dir>/<name>.jsonl, spools an alert for new findings at or above
# PROBE_ALERT_MIN (each check at most once per PROBE_DEDUPE_S), and trims the
# log to PROBE_KEEP_DAYS once a day. Findings pass through overlord-redact.
# Installed as /usr/local/lib/overlord/probes/lib.sh.

# executables in the temp dirs (default /tmp /var/tmp /dev/shm) owned by a
# system account (uid 1..TMP_EXE_MAX_UID, or nobody), at most 30, one per line:
# "<user> <size> bytes <date> <time> <path>". Shared by the collector's
# security section and the intrusion probe (tmp_executable).
tmp_executables() {
    local max=${TMP_EXE_MAX_UID:-999} dirs=("$@")
    [ ${#dirs[@]} -gt 0 ] || dirs=(/tmp /var/tmp /dev/shm)
    find "${dirs[@]}" -xdev -maxdepth 4 -type f -perm /111 \
        \( \( -uid -$((max + 1)) ! -uid 0 \) -o -uid 65534 \) \
        -printf '%u %s bytes %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | head -30
}

# severity as a number: ok 0, warn 1, critical 2
sev_rank() { case $1 in critical) echo 2 ;; warn) echo 1 ;; *) echo 0 ;; esac; }

probe_init() {
    PROBE=$1
    PROBE_LOG_DIR=${PROBE_LOG_DIR:-/var/log/overlord/probes}
    PROBE_STATE=${PROBE_STATE:-/var/lib/overlord-probes/$PROBE}
    PROBE_SPOOL=${PROBE_SPOOL:-/var/lib/overlord/alerts}
    PROBE_ALERT_MIN=${PROBE_ALERT_MIN:-critical}
    PROBE_DEDUPE_S=${PROBE_DEDUPE_S:-3600}
    PROBE_KEEP_DAYS=${PROBE_KEEP_DAYS:-14}
    if [ -z "${PROBE_REDACT:-}" ]; then
        if [ -x /usr/local/sbin/overlord-redact ]; then PROBE_REDACT=/usr/local/sbin/overlord-redact
        else PROBE_REDACT=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../collect/redact.sh; fi
    fi
    PROBE_T0=$(date +%s%3N)
    PROBE_FINDINGS=()
}

# finding <check> <severity ok|warn|critical> <detail>; tabs and newlines in
# the detail become spaces, and it is cut at 300 characters
finding() {
    local d=${3//[$'\t\n']/ }
    PROBE_FINDINGS+=("$1"$'\t'"$2"$'\t'"${d:0:300}")
}

probe_finish() {
    local metrics=${1:-'{}'} now ms findings sev
    now=$(date +%s)
    ms=$(( $(date +%s%3N) - PROBE_T0 ))
    findings=$(printf '%s\n' "${PROBE_FINDINGS[@]}" | grep . | "$PROBE_REDACT" \
        | jq -Rnc '[inputs | split("\t") | {check: .[0], severity: .[1], detail: .[2]}]')
    sev=$(jq -r 'map(.severity) | if index("critical") then "critical"
                 elif index("warn") then "warn" else "ok" end' <<<"$findings")
    jq -nc --arg ts "$(date -u -d "@$now" +%FT%TZ)" --arg p "$PROBE" --arg s "$sev" \
        --argjson f "$findings" --argjson m "$metrics" --argjson ms "$ms" \
        '{ts: $ts, probe: $p, severity: $s, findings: $f, metrics: $m, ms: $ms}' \
        >>"$PROBE_LOG_DIR/$PROBE.jsonl"
    if [ "$ms" -gt 10000 ]; then
        jq -nc --arg ts "$(date -u +%FT%TZ)" --arg p "$PROBE" --arg d "run took $ms ms (limit 10000)" \
            '{ts: $ts, probe: $p, severity: "warn", findings: [{check: "slow_run", severity: "warn", detail: $d}]}' \
            >>"$PROBE_LOG_DIR/$PROBE.jsonl"
    fi
    probe_alert "$findings" "$now"
    probe_trim "$now"
}

# $1: findings JSON, $2: now (epoch). State file "alerted": "<check> <epoch>"
# per check, the last time it was alerted.
probe_alert() {
    local findings=$1 now=$2 st=$PROBE_STATE/alerted c t min send=() f
    local -A last=()
    if [ -r "$st" ]; then while read -r c t; do [ -n "$c" ] && last[$c]=$t; done <"$st"; fi
    min=$(sev_rank "$PROBE_ALERT_MIN")
    for c in $(jq -r --argjson min "$min" \
            '.[] | select((if .severity == "critical" then 2 elif .severity == "warn" then 1 else 0 end) >= $min) | .check' \
            <<<"$findings" | sort -u); do
        if [ $(( now - ${last[$c]:-0} )) -ge "$PROBE_DEDUPE_S" ]; then send+=("$c"); last[$c]=$now; fi
    done
    [ ${#send[@]} -gt 0 ] || return 0
    f=$now-$PROBE-$$
    if jq -c --arg ts "$(date -u -d "@$now" +%FT%TZ)" --arg p "$PROBE" \
            --argjson send "$(printf '%s\n' "${send[@]}" | jq -Rnc '[inputs]')" \
            '[.[] | select(.check as $c | $send | index($c))] as $f
             | {ts: $ts, probe: $p,
                severity: ($f | map(.severity) | if index("critical") then "critical" else "warn" end),
                findings: $f}' <<<"$findings" >"$PROBE_SPOOL/.$f.tmp" \
        && mv "$PROBE_SPOOL/.$f.tmp" "$PROBE_SPOOL/$f.json"; then
        for c in "${!last[@]}"; do echo "$c ${last[$c]}"; done >"$st"
    else
        echo "probe $PROBE: could not spool alert in $PROBE_SPOOL" >&2
        rm -f "$PROBE_SPOOL/.$f.tmp"
    fi
}

# once a day, drop log lines older than PROBE_KEEP_DAYS
probe_trim() {
    local now=$1 st=$PROBE_STATE/trimmed log=$PROBE_LOG_DIR/$PROBE.jsonl cutoff
    [ $(( now - $(cat "$st" 2>/dev/null || echo 0) )) -ge 86400 ] || return 0
    cutoff=$(date -u -d "@$(( now - PROBE_KEEP_DAYS * 86400 ))" +%FT%TZ)
    awk -v c="$cutoff" 'match($0, /"ts":"[^"]*"/) && substr($0, RSTART + 6, RLENGTH - 7) >= c' \
        "$log" >"$log.tmp" && mv "$log.tmp" "$log"
    echo "$now" >"$st"
}
