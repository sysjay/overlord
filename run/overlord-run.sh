#!/bin/bash
# overlord runner, run as sysai by overlord.service.
# collect facts (sudo, the one allowed command) -> claude, no tools -> ledger,
# Cookie-Cam POST, email, status site. Any failure becomes status "error";
# the email still goes out.
# Installed as /usr/local/lib/overlord/overlord-run.sh.
set -u
umask 077
export LC_ALL=C.UTF-8

LIB=${OVERLORD_LIB:-/usr/local/lib/overlord}
CONF=${OVERLORD_CONF:-$HOME/.config/overlord}
RUNS=${OVERLORD_RUNS:-$HOME/runs}
COLLECT=${OVERLORD_COLLECT:-sudo -n /usr/local/sbin/overlord-collect-uba5}
REDACT=${OVERLORD_REDACT:-/usr/local/sbin/overlord-redact}
CLAUDE=${OVERLORD_CLAUDE:-/usr/local/bin/claude}
MSMTP=${OVERLORD_MSMTP:-msmtp}
POST_URL=${OVERLORD_POST_URL:-http://127.0.0.1:5000/api/overlord/report}
BUDGET=0.50
CLAUDE_TIMEOUT=600
KEEP_DAYS=90
HOSTS='["uba5","cookiepi"]'

mkdir -p "$RUNS"
exec 9>"$RUNS/.lock"
flock -n 9 || { echo "overlord: another run is in progress" >&2; exit 1; }

started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run_id=$(date -u +%Y%m%dT%H%M%SZ)
dir=$RUNS/$run_id
mkdir -p "$dir"
log() { echo "overlord $run_id: $*" >&2; }

status=error summary="" report_md="" cost=0 model="" duration_s=0 tools=null
notes=()
fail() { [ -z "$summary" ] && summary=$1; log "$1"; }

run_claude() {
    # flags settled in ticket 01 Stage 0: bare, zero tools, no MCP,
    # system prompt from file, schema-checked JSON, hard budget.
    # --verbose makes the JSON an array that includes the init message's tools list.
    cd "$dir" || return 1
    timeout "$CLAUDE_TIMEOUT" "$CLAUDE" --bare -p \
        --tools "" --strict-mcp-config --disallowedTools "mcp__*" \
        --system-prompt-file "$LIB/prompt.md" \
        --output-format json --verbose \
        --json-schema "$(cat "$LIB/report.schema.json")" \
        --max-budget-usd "$BUDGET" \
        --no-session-persistence --permission-prompts none \
        ${OVERLORD_MODEL:+--model "$OVERLORD_MODEL"} \
        "Write this morning's overlord report from the facts below." \
        <"$dir/facts.txt" >"$dir/result.json" 2>"$dir/claude.stderr"
}

# result object of the JSON, whether claude printed one object or an array
RESULT_JQ='if type=="array" then (map(select(.type=="result")) | last) else . end'

main() {
    # 1. config and redaction selftest
    if [ -r "$CONF/env" ]; then set -a; . "$CONF/env"; set +a
    else fail "config $CONF/env is missing"; return; fi
    export DISABLE_AUTOUPDATER=1
    "$REDACT" --selftest >"$dir/redact-selftest.txt" 2>&1 \
        || { fail "redaction selftest failed; facts not collected"; return; }

    # 2. facts
    $COLLECT >"$dir/facts.txt" 2>"$dir/collect.stderr"
    [ -s "$dir/facts.txt" ] || { fail "collector produced no output (sudo rule or collector broken?)"; return; }

    # 3. claude
    local rc=0 t0 t1
    t0=$(date +%s)
    run_claude || rc=$?
    t1=$(date +%s)
    duration_s=$((t1 - t0))

    # 4. read the answer
    local res
    res=$(jq -c "$RESULT_JQ" "$dir/result.json" 2>/dev/null) || res=""
    if [ -n "$res" ] && [ "$res" != "null" ]; then
        cost=$(jq -r '.total_cost_usd // 0' <<<"$res")
        model=$(jq -r '.model // ((.modelUsage // {}) | keys | first) // ""' <<<"$res")
        local ms; ms=$(jq -r '.duration_ms // empty' <<<"$res")
        [ -n "$ms" ] && duration_s=$(( (ms + 500) / 1000 ))
    fi
    # the init message's tools list (null if absent), kept in report.json as proof
    tools=$(jq -c 'if type=="array" then (map(select(.type=="system" and .subtype=="init")) | first | .tools) else null end' \
        "$dir/result.json" 2>/dev/null) || tools=null
    [ -n "$tools" ] || tools=null

    if [ $rc -eq 124 ]; then fail "claude timed out after ${CLAUDE_TIMEOUT}s"; return; fi
    if [ -z "$res" ] || [ "$res" = "null" ]; then
        fail "claude exit $rc, no readable JSON ($(head -c 200 "$dir/claude.stderr" | tr '\n' ' '))"; return
    fi
    # --json-schema adds Claude Code's internal StructuredOutput tool (it only
    # returns the answer); anything else means the no-tools rule broke.
    if ! jq -e 'type=="array" and all(.[]; . == "StructuredOutput")' <<<"$tools" >/dev/null; then
        fail "claude ran with unexpected tools: $tools"; return
    fi
    local subtype; subtype=$(jq -r '.subtype // ""' <<<"$res")
    if [ "$subtype" = "error_max_budget_usd" ]; then fail "budget cap \$$BUDGET hit"; return; fi
    if [ $rc -ne 0 ] || [ "$(jq -r '.is_error // false' <<<"$res")" = "true" ]; then
        fail "claude failed: exit $rc, ${subtype:-no subtype}"; return
    fi
    local s; s=$(jq -r '.structured_output.status // ""' <<<"$res")
    case "$s" in ok|warn|problem) ;; *) fail "answer has no valid status (got '${s:0:20}')"; return ;; esac
    status=$s
    summary=$(jq -r '.structured_output.summary // ""' <<<"$res" | head -c 300)
    report_md=$(jq -r '.structured_output.report_md // ""' <<<"$res" | head -c 65536)
}

main

finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ "$status" = error ]; then
    report_md="**overlord run failed:** ${summary}

Run folder: $dir"
fi

# 5. ledger
ledger=$RUNS/ledger.csv
[ -s "$ledger" ] || echo "run_id,status,cost_usd,model,duration_s" >"$ledger"
echo "$run_id,$status,$cost,${model//,/ },$duration_s" >>"$ledger"

record() {
    jq -n --arg run_id "$run_id" --arg started_at "$started" --arg finished_at "$finished" \
        --arg status "$status" --arg summary "$summary" --arg report_md "$report_md" \
        --argjson cost_usd "$cost" --arg model "$model" --argjson hosts "$HOSTS" \
        "{run_id: \$run_id, started_at: \$started_at, finished_at: \$finished_at, status: \$status,
          summary: \$summary, report_md: \$report_md, cost_usd: \$cost_usd, model: \$model, hosts: \$hosts}$1"
}
record "" >"$dir/post.json"

# 6. Cookie-Cam (failure is noted, not fatal)
code=$(curl -s -m 10 -o "$dir/post.response" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data-binary @"$dir/post.json" "$POST_URL")
[ "$code" = 200 ] || { notes+=("Cookie-Cam POST failed (HTTP ${code:-none})."); log "${notes[-1]}"; }

notes_json=$(printf '%s\n' "${notes[@]+"${notes[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))')
record " + {duration_s: $duration_s, tools: $tools, notes: $notes_json}" >"$dir/report.json"

# 7. email, every run
month=${run_id:0:6}
read -r month_cost month_runs < <(awk -F, -v m="$month" 'NR>1 && substr($1,1,6)==m {s+=$3; n++} END {printf "%.2f %d\n", s, n}' "$ledger")
STATUS=$(tr a-z A-Z <<<"$status")
subject="[overlord] $STATUS - $(head -c 80 <<<"$summary" | tr '\n' ' ')"
mail_to=${OVERLORD_MAIL_TO:-jaytcornell@gmail.com}
{
    echo "From: overlord <$mail_to>"
    echo "To: $mail_to"
    echo "Subject: =?UTF-8?B?$(printf '%s' "$subject" | base64 -w0)?="
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    printf '%s\n\n' "$report_md"
    for n in "${notes[@]+"${notes[@]}"}"; do echo "Note: $n"; done
    printf 'Cost this run $%.3f · this month $%s (%s runs)\n' "$cost" "$month_cost" "$month_runs"
    [ -n "${OVERLORD_SITE_URL:-}" ] && echo "$OVERLORD_SITE_URL"
} >"$dir/email.txt"
"$MSMTP" -C "$CONF/msmtprc" -t <"$dir/email.txt" || log "email failed (msmtp exit $?)"

# 8. retention, then the status site (it shows only runs that still exist)
find "$RUNS" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' -mtime +"$KEEP_DAYS" -exec rm -rf {} +
OVERLORD_RUNS=$RUNS python3 "$LIB/render_site.py" || log "render_site.py failed"

log "status=$status cost=$cost duration=${duration_s}s"
[ "$status" != error ]
