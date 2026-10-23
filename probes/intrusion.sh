#!/bin/bash
# overlord probe: intrusion. Runs every 2 min as overlord-probe-intrusion
# (overlord-probe-intrusion.timer); read only, no AI. Looks for what the Plex
# compromise (2026-10-22) did: programs run from temp dirs, miners,
# executables dropped in /tmp, unexpected outbound connections, Plex coming
# back, CPU hogs and new listening ports.
#   intrusion.sh             run the checks (one JSON line, maybe an alert)
#   intrusion.sh --baseline  (re)take the listening-port baseline
# Installed as /usr/local/lib/overlord/probes/intrusion.sh.
set -u
export LC_ALL=C
here=$(dirname "$(readlink -f "$0")")
. "$here/lib.sh"
. "${INTRUSION_CONF:-$here/intrusion.conf}"
PROC=${PROC:-/proc}
TMP_DIRS=${TMP_DIRS:-/tmp /var/tmp /dev/shm}

probe_init intrusion

# one line per listening socket: "tcp <addr:port>", "udp <port>"; UDP is by
# port only and skips ephemeral ports (>= 32768), which change on their own
listeners() {
    ss -Hltnu 2>/dev/null | awk '$1 == "tcp" { print "tcp", $5 }
        $1 == "udp" { p = $5; sub(/.*:/, "", p); if (p + 0 < 32768) print "udp", p }' | sort -u
}

if [ "${1:-}" = --baseline ]; then
    listeners >"$PROBE_STATE/listeners.baseline"
    echo "baseline: $(wc -l <"$PROBE_STATE/listeners.baseline") listeners in $PROBE_STATE/listeners.baseline"
    exit 0
fi

user_of_uid() {
    local u
    u=$(getent passwd "$1" | cut -d: -f1)
    echo "${u:-uid$1}"
}
user_of_pid() {
    local k v _
    while read -r k v _; do
        if [ "$k" = Uid: ]; then user_of_uid "$v"; return; fi
    done <"$PROC/$1/status" 2>/dev/null
    echo "?"
}

# 1. exe_in_tmp: programs running from a temp dir, memfd or a deleted file
declare -A exe_n=()
while IFS=$'\t' read -r dir exe; do
    case $exe in
        /tmp/* | /var/tmp/* | /dev/shm/* | memfd:* | *" (deleted)") ;;
        *) continue ;;
    esac
    k="$(user_of_pid "${dir##*/}")"$'\t'"$exe"
    exe_n[$k]=$(( ${exe_n[$k]:-0} + 1 ))
done < <(find "$PROC"/[0-9]*/exe -maxdepth 0 -printf '%h\t%l\n' 2>/dev/null)
for k in "${!exe_n[@]}"; do
    exe=${k#*$'\t'}
    case $exe in
        /tmp/* | /var/tmp/* | /dev/shm/* | memfd:*) sev=critical ;;
        *) sev=$DELETED_EXE_SEVERITY ;;
    esac
    finding exe_in_tmp "$sev" "${exe_n[$k]} process(es) of user ${k%%$'\t'*} run $exe"
done

# 2. miner_proxy: known miner / proxy command lines
while read -r f; do
    pid=${f#"$PROC"/}; pid=${pid%/cmdline}
    cmd=$(tr '\0' ' ' <"$f" 2>/dev/null | head -c 200)
    finding miner_proxy critical "user $(user_of_pid "$pid") pid $pid: $cmd"
done < <(grep -ailF -f <(printf '%s\n' "$MINER_PATTERNS") "$PROC"/[0-9]*/cmdline 2>/dev/null)

# 3. tmp_executable: executables dropped in temp dirs by system accounts
# shellcheck disable=SC2086
while read -r line; do
    finding tmp_executable critical "$line"
done < <(tmp_executables $TMP_DIRS)

# 4. unexpected_outbound: outside connections by users not in
# OUTBOUND_OK_USERS, and any connection to a pool port. Counts and ports only.
pfx=$(ip -6 -o addr show scope global 2>/dev/null \
    | awk '{split($4, a, "/"); split(a[1], h, ":"); print tolower(h[1] ":" h[2] ":" h[3] ":" h[4] ":")}' \
    | sort -u | tr '\n' ' ')
lports=$(ss -Htln 2>/dev/null | awk '{p = $4; sub(/.*:/, "", p); print p}' | sort -u | tr '\n' ' ')
declare -A out_n=()
while read -r kind uid port; do
    u=$(user_of_uid "$uid")
    if [ "$kind" = pool ]; then
        finding unexpected_outbound critical "user $u: connection to pool port $port"
    else
        out_n[$u]=$(( ${out_n[$u]:-0} + 1 ))
    fi
done < <(ss -Htne state established 2>/dev/null | awk -v pfx="$pfx" -v lports=" $lports " -v pool=" $POOL_PORTS " '
    BEGIN { n = split(pfx, P, " ") }
    {
        peer = $4
        if (peer ~ /^\[/) { sub(/^\[/, "", peer); sub(/\].*$/, "", peer) } else sub(/:[0-9]+$/, "", peer)
        sub(/^::ffff:/, "", peer); peer = tolower(peer)
        lan = (peer ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|169\.254\.)/ || peer == "::1" \
               || peer ~ /^(fe80|fc|fd)/)
        if (!lan) { split(peer, h, ":"); p4 = h[1] ":" h[2] ":" h[3] ":" h[4] ":"
                    for (i = 1; i <= n; i++) if (p4 == P[i]) lan = 1 }
        lp = $3; sub(/.*:/, "", lp); rp = $4; sub(/.*:/, "", rp)
        if (index(lports, " " lp " ")) next          # someone connected to us
        uid = match($0, /uid:[0-9]+/) ? substr($0, RSTART + 4, RLENGTH - 4) : 0
        if (index(pool, " " rp " ")) print "pool", uid, rp
        if (!lan) print "out", uid, rp
    }')
outbound_json=$(for u in "${!out_n[@]}"; do echo "$u ${out_n[$u]}"; done \
    | jq -Rnc '[inputs | split(" ") | {(.[0]): (.[1] | tonumber)}] | add // {}')
for u in "${!out_n[@]}"; do
    case " $OUTBOUND_OK_USERS " in
        *" $u "*) ;;
        *) finding unexpected_outbound critical "user $u: ${out_n[$u]} connection(s) to outside addresses" ;;
    esac
done

# 5. plex_back: Plex was retired after the compromise; it must stay gone
st=$(dpkg-query -W -f='${db:Status-Status}' plexmediaserver 2>/dev/null)
act=$(systemctl is-active plexmediaserver 2>/dev/null)
n=$(pgrep -c -u plex 2>/dev/null); n=${n:-0}
if [ "$st" = installed ] || [ "$act" = active ] || [ "$n" -gt 0 ]; then
    finding plex_back critical "package=${st:-not-installed} unit=${act:-unknown} processes=$n"
fi

# 6. cpu_hog: over CPU_HOG_PCT of a core for CPU_HOG_RUNS runs in a row.
# State "cpu": first line "T <epoch>", then "<pid> <starttime> <ticks> <hot runs>".
hz=$(getconf CLK_TCK)
now=$(date +%s)
declare -A p_start=() p_ticks=() p_hot=()
prev_t=0
if [ -r "$PROBE_STATE/cpu" ]; then
    while read -r a b c d; do
        if [ "$a" = T ]; then prev_t=$b; else p_start[$a]=$b; p_ticks[$a]=$c; p_hot[$a]=$d; fi
    done <"$PROBE_STATE/cpu"
fi
el=$(( now - prev_t ))
procs=0
{
    echo "T $now"
    for d in "$PROC"/[0-9]*; do
        read -r stat <"$d/stat" 2>/dev/null || continue
        procs=$((procs + 1))
        pid=${d##*/}
        comm=${stat#*\(}; comm=${comm%\)*}
        read -ra f <<<"${stat##*) }"      # f[0] = state (field 3)
        ticks=$(( f[11] + f[12] )); start=${f[19]}
        hot=0
        if [ "${p_start[$pid]:-}" = "$start" ] && [ "$el" -gt 0 ] && [ "$el" -lt 3600 ]; then
            pct=$(( (ticks - p_ticks[$pid]) * 100 / (hz * el) ))
            if [ "$pct" -ge "$CPU_HOG_PCT" ]; then
                hot=$(( p_hot[$pid] + 1 ))
                case " $CPU_OK " in
                    *" $comm "*) ;;
                    *) [ "$hot" -ge "$CPU_HOG_RUNS" ] && finding cpu_hog warn \
                           "user $(user_of_pid "$pid") pid $pid $comm: ${pct}% CPU for $hot runs" ;;
                esac
            fi
        fi
        echo "$pid $start $ticks $hot"
    done
} >"$PROBE_STATE/cpu.new"
mv "$PROBE_STATE/cpu.new" "$PROBE_STATE/cpu"

# 7. new_listener: listening sockets not in the baseline
cur=$(listeners)
if [ -r "$PROBE_STATE/listeners.baseline" ]; then
    while read -r l; do
        [ -n "$l" ] && finding new_listener warn "listening socket not in baseline: $l"
    done < <(comm -13 "$PROBE_STATE/listeners.baseline" - <<<"$cur")
else
    printf '%s\n' "$cur" >"$PROBE_STATE/listeners.baseline"
    finding new_listener warn "no baseline yet; took one now ($(grep -c . <<<"$cur") listeners)"
fi

load1=$(cut -d' ' -f1 "$PROC/loadavg" 2>/dev/null)
probe_finish "$(jq -nc --argjson load1 "${load1:-null}" --argjson procs "$procs" \
    --argjson out "$outbound_json" --argjson l "$(grep -c . <<<"$cur")" \
    '{load1: $load1, procs: $procs, outbound_by_user: $out, listeners: $l}')"
