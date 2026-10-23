#!/bin/bash
# overlord alerter, run as sysai by overlord-alert.service whenever a probe
# spools an alert in /var/lib/overlord/alerts (overlord-alert.path).
# Per alert, by its probe's route in the registry:
#   summarize (default): an alert run (overlord-run.sh --alert), at most
#     ALERT_CAP a day; if the cap is reached or the run fails, a direct email
#   direct: a direct email at once
# Each alert is recorded in ~/runs/alerts.jsonl, then removed from the spool,
# so an alert is never lost and never handled twice.
# Installed as /usr/local/lib/overlord/overlord-alert.sh.
set -u
umask 077
export LC_ALL=C.UTF-8

LIB=${OVERLORD_LIB:-/usr/local/lib/overlord}
CONF=${OVERLORD_CONF:-$HOME/.config/overlord}
RUNS=${OVERLORD_RUNS:-$HOME/runs}
SPOOL=${OVERLORD_SPOOL:-/var/lib/overlord/alerts}
REGISTRY=${OVERLORD_REGISTRY:-$LIB/probes/registry.json}
RUNNER=${OVERLORD_RUNNER:-$LIB/overlord-run.sh}
REDACT=${OVERLORD_REDACT:-/usr/local/sbin/overlord-redact}
MSMTP=${OVERLORD_MSMTP:-msmtp}
ALERT_CAP=4          # alert runs a day (each costs one run, ~$0.12)
RUN_TIMEOUT=900      # seconds for a whole alert run
ALERTS=$RUNS/alerts.jsonl

mkdir -p "$RUNS"
exec 8>"$RUNS/.alert-lock"
flock -n 8 || exit 0   # another alerter is at work; the path unit starts us again
log() { echo "overlord-alert: $*" >&2; }

if [ -r "$CONF/env" ]; then set -a; . "$CONF/env"; set +a; fi
mail_to=${OVERLORD_MAIL_TO:-jaytcornell@gmail.com}

# alert runs started today (local date), whether they worked or not
runs_today() {
    [ -r "$ALERTS" ] || { echo 0; return; }
    jq -s --argjson start "$(date -d 'today 00:00' +%s)" \
        '[.[] | select(.run_tried and (.ts | fromdateiso8601? // 0) >= $start)] | length' \
        "$ALERTS" 2>/dev/null || echo 0
}

# $1: alert JSON, $2: how it is routed. The probe's findings, as they are.
direct_email() {
    local a=$1 how=$2 subject at body
    # redact the text, never the headers (the encoded subject looks like a key)
    subject="[overlord] ALERT $(jq -r '"\(.severity | ascii_upcase) \(.probe): \(.findings[0].detail // "")"' <<<"$a" \
        | "$REDACT" | head -c 100 | tr '\n' ' ')"
    at=$(date -d "$(jq -r .ts <<<"$a")" '+%a %b %-d %-I:%M %p %Z' 2>/dev/null || jq -r .ts <<<"$a")
    body=$({
        jq -r --arg at "$at" '"Probe \(.probe) raised a \(.severity) alert at \($at).",
               "", "Findings:", (.findings[] | "- \(.check) (\(.severity)): \(.detail)")' <<<"$a"
        echo
        echo "Sent directly ($how)."
        echo "overlord will cover this in the morning report."
        [ -n "${OVERLORD_SITE_URL:-}" ] && echo "$OVERLORD_SITE_URL"
    } | "$REDACT")
    {
        echo "From: overlord <$mail_to>"
        echo "To: $mail_to"
        echo "Subject: =?UTF-8?B?$(printf '%s' "$subject" | base64 -w0)?="
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo
        printf '%s\n' "$body"
    } | "$MSMTP" -C "$CONF/msmtprc" -t
}

for f in "$SPOOL"/*.json; do
    [ -e "$f" ] || continue
    a=$(jq -c 'select(.probe and (.findings | type) == "array")' "$f" 2>/dev/null)
    if [ -z "$a" ]; then
        log "not an alert, removed: $f"
        rm -f "$f"
        continue
    fi
    probe=$(jq -r .probe <<<"$a")
    route=$(jq -r --arg p "$probe" '.[] | select(.name == $p) | .route' "$REGISTRY" 2>/dev/null)
    how=direct tried=false run_id=""
    if [ "${route:-summarize}" = summarize ]; then
        if [ "$(runs_today)" -ge "$ALERT_CAP" ]; then
            how="direct: daily cap of $ALERT_CAP alert runs reached"
        else
            tried=true
            out=$(timeout "$RUN_TIMEOUT" "$RUNNER" --alert "$f" 2>&1); rc=$?
            run_id=$(sed -n 's/^overlord \([0-9TZ]*\): status=.*/\1/p' <<<"$out" | tail -1)
            if [ $rc -eq 0 ]; then how=summarized
            elif [ $rc -eq 124 ]; then how="direct: alert run timed out"
            else how="direct: alert run failed (exit $rc)"; fi
        fi
    fi
    sent=true
    if [ "$how" != summarized ]; then
        direct_email "$a" "$how" || { sent=false; log "direct email failed for $f"; }
    fi
    jq -c --arg ts "$(date -u +%FT%TZ)" --arg how "$how" --arg run_id "$run_id" \
        --argjson tried "$tried" --argjson sent "$sent" \
        '{ts: $ts, alert_ts: .ts, probe, severity, checks: ([.findings[].check] | unique),
          how: $how, run_id: $run_id, run_tried: $tried, sent: $sent}' <<<"$a" >>"$ALERTS"
    log "$probe $(jq -r .severity <<<"$a"): $how${run_id:+ ($run_id)}, sent=$sent"
    rm -f "$f" || log "could not remove $f"
done

# keep the alert record small
if [ "$(wc -l <"$ALERTS" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 1000 "$ALERTS" >"$ALERTS.tmp" && mv "$ALERTS.tmp" "$ALERTS"
fi
exit 0
