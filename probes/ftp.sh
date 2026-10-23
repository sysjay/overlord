#!/bin/bash
# overlord probe: ftp. Runs every 2 min as overlord-probe-ftp
# (overlord-probe-ftp.timer); read only, no AI. The Back Yard camera uploads
# its clips to vsftpd and never retries, so while vsftpd is down clips never
# reach Cookie-Cam (2026-10-23: down 4 h after a reboot, nobody noticed).
# Route: direct (registry.json).
# Installed as /usr/local/lib/overlord/probes/ftp.sh.
set -u
export LC_ALL=C
here=$(dirname "$(readlink -f "$0")")
. "$here/lib.sh"
FTP_LISTEN=${FTP_LISTEN:-10.0.0.33:21}

probe_init ftp

listening=false
if ss -Hltn 2>/dev/null | awk -v l="$FTP_LISTEN" '$4 == l { f = 1 } END { exit !f }'; then
    listening=true
fi
act=$(systemctl is-active vsftpd 2>/dev/null)
if [ "$listening" = false ]; then
    finding vsftpd_down critical "vsftpd not listening on $FTP_LISTEN (unit ${act:-unknown}); Back Yard clips are not being received"
fi

probe_finish "$(jq -nc --argjson l "$listening" --arg u "${act:-unknown}" '{listening: $l, unit: $u}')"
