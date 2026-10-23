#!/bin/bash
# overlord installer. Jay runs it from the repo: sudo ./install.sh
# Idempotent: rerun after any change to collect/, probes/, run/, web/, systemd/
# or sudoers/.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
[ "$EUID" -eq 0 ] || { echo "run with sudo: sudo ./install.sh" >&2; exit 1; }

U=sysai
H=/home/$U
LIB=/usr/local/lib/overlord
G=overlord-alerts                          # probes spool alerts; sysai reads them
PROBES="intrusion ftp"                     # each runs as overlord-probe-<name>
SPOOL=/var/lib/overlord/alerts
PLOGS=/var/log/overlord/probes
say() { echo "== $*"; }

# --- account: create if missing, then enforce "can change nothing" ---------
if ! id "$U" >/dev/null 2>&1; then
    say "creating $U"
    useradd -m -s /bin/bash "$U"
fi
getent group "$G" >/dev/null || { say "creating group $G"; groupadd --system "$G"; }
say "enforcing $U account state"
# the only group besides its own: $G (read probe logs and alerts)
extra=$(id -nG "$U" | tr ' ' '\n' | grep -vx -e "$U" -e "$G" || true)
if [ -n "$extra" ] || ! id -nG "$U" | tr ' ' '\n' | grep -qx "$G"; then
    [ -n "$extra" ] && echo "   removing $U from: $(echo $extra)"
    usermod -G "$G" "$U"
fi
passwd -l "$U" >/dev/null                     # no password login
bad=$(grep -rlw "$U" /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -vx /etc/sudoers.d/overlord || true)
if [ -n "$bad" ]; then
    echo "STOP: other sudoers files mention $U; remove those rules first:" >&2
    echo "$bad" >&2
    exit 1
fi
if crontab -l -u "$U" >/dev/null 2>&1; then echo "   WARNING: $U has a crontab (crontab -l -u $U)"; fi
if [ -e "/var/lib/systemd/linger/$U" ]; then echo "   WARNING: $U has lingering user services (loginctl disable-linger $U)"; fi
echo "   $H contains:"; ls -la "$H" | sed 's/^/     /'

install -d -o "$U" -g "$U" -m 700 "$H/.config" "$H/.config/overlord" "$H/runs"

# --- probe accounts: one per probe, nothing attached ----------------------
# no home, no shell, no password, no groups but its own and $G (README: why)
for p in $PROBES; do
    a=overlord-probe-$p
    if ! id "$a" >/dev/null 2>&1; then
        say "creating $a"
        useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin --groups "$G" "$a"
    fi
    extra=$(id -nG "$a" | tr ' ' '\n' | grep -vx -e "$a" -e "$G" || true)
    if [ -n "$extra" ] || ! id -nG "$a" | tr ' ' '\n' | grep -qx "$G"; then
        [ -n "$extra" ] && echo "   removing $a from: $(echo $extra)"
        usermod -G "$G" "$a"
    fi
    usermod -s /usr/sbin/nologin "$a"
    passwd -l "$a" >/dev/null
    if grep -rlw "$a" /etc/sudoers /etc/sudoers.d >/dev/null 2>&1; then
        echo "STOP: a sudoers file mentions $a; probes get no sudo" >&2
        exit 1
    fi
done
say "probe accounts: $(for p in $PROBES; do echo -n "overlord-probe-$p($(id -nG overlord-probe-$p | tr ' ' ,)) "; done)"

# shared dirs, setgid + sticky: files land in group $G (sysai reads them),
# and no probe can rename or delete another's files
install -d -o root -g root -m 755 /var/lib/overlord /var/log/overlord /var/lib/overlord-probes
install -d -o "$U" -g "$G" -m 3770 "$SPOOL"
install -d -o root -g "$G" -m 3770 "$PLOGS"

# --- packages ---------------------------------------------------------------
need=()
for p in msmtp:msmtp smartctl:smartmontools jq:jq curl:curl; do
    command -v "${p%%:*}" >/dev/null || need+=("${p#*:}")
done
if [ ${#need[@]} -gt 0 ]; then
    say "installing ${need[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
fi

# --- Claude Code: a root-owned copy sysai can run but not change -----------
src=""
if [ -n "${SUDO_USER:-}" ]; then
    src=$(readlink -f "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.local/bin/claude" 2>/dev/null || true)
fi
if [ -n "$src" ] && [ -x "$src" ]; then
    if ! cmp -s "$src" /usr/local/bin/claude; then
        say "installing Claude Code $(basename "$src") to /usr/local/bin/claude"
        install -o root -g root -m 755 "$src" /usr/local/bin/claude
    fi
elif [ ! -x /usr/local/bin/claude ]; then
    echo "STOP: no Claude Code found in ${SUDO_USER:-your}'s ~/.local/bin to copy" >&2
    exit 1
fi
echo "   $(/usr/local/bin/claude --version 2>/dev/null || echo 'claude --version failed')"

# --- files ------------------------------------------------------------------
say "installing collector, runner, site"
install -o root -g root -m 755 collect/uba5.sh /usr/local/sbin/overlord-collect-uba5
install -o root -g root -m 755 collect/redact.sh /usr/local/sbin/overlord-redact
install -d -o root -g root -m 755 "$LIB"
install -o root -g root -m 755 run/overlord-run.sh run/render_site.py web/overlord_web.py "$LIB/"
install -o root -g root -m 755 run/overlord-alert.sh run/overlord-rec.py "$LIB/"
install -o root -g root -m 644 run/prompt.md run/report.schema.json "$LIB/"
# probes; the collector also sources lib.sh (tmp_executables)
install -d -o root -g root -m 755 "$LIB/probes"
install -o root -g root -m 644 probes/lib.sh probes/intrusion.conf probes/registry.json "$LIB/probes/"
install -o root -g root -m 755 probes/intrusion.sh probes/ftp.sh "$LIB/probes/"

# the intrusion probe's listener baseline, taken once; to re-take it after
# adding a service:
#   sudo runuser -u overlord-probe-intrusion -- /usr/local/lib/overlord/probes/intrusion.sh --baseline
for p in $PROBES; do
    install -d -o "overlord-probe-$p" -g "overlord-probe-$p" -m 755 "/var/lib/overlord-probes/$p"
done
if [ ! -s /var/lib/overlord-probes/intrusion/listeners.baseline ]; then
    say "taking the listener baseline"
    runuser -u overlord-probe-intrusion -- "$LIB/probes/intrusion.sh" --baseline | sed 's/^/   /'
fi

say "installing sudoers rule"
visudo -cf sudoers/overlord
install -o root -g root -m 440 sudoers/overlord /etc/sudoers.d/overlord

say "installing systemd units"
install -o root -g root -m 644 systemd/overlord.service systemd/overlord.timer \
    systemd/overlord-web.service systemd/overlord-alert.path systemd/overlord-alert.service \
    /etc/systemd/system/
for p in $PROBES; do
    install -o root -g root -m 644 "systemd/overlord-probe-$p.service" "systemd/overlord-probe-$p.timer" \
        /etc/systemd/system/
done
systemctl daemon-reload
systemctl enable --now overlord.timer overlord-alert.path
for p in $PROBES; do systemctl enable --now "overlord-probe-$p.timer"; done

# first site build so the web server has something to show
sudo -u "$U" -H python3 "$LIB/render_site.py" >/dev/null

env=$H/.config/overlord/env
if [ -f "$env" ] && grep -q '^OVERLORD_WEB_USER=.' "$env" && grep -q '^OVERLORD_WEB_PASS=.' "$env"; then
    systemctl enable overlord-web.service
    systemctl restart overlord-web.service
    say "overlord-web: $(systemctl is-active overlord-web.service)"
else
    echo "   overlord-web NOT started: put OVERLORD_WEB_USER/PASS in $env, then rerun"
fi
for f in env msmtprc; do
    [ -f "$H/.config/overlord/$f" ] || echo "   MISSING: $H/.config/overlord/$f (copy config/$f.example, edit, chown $U, chmod 600)"
done

/usr/local/sbin/overlord-redact --selftest
say "next run: $(systemctl list-timers overlord.timer --no-legend --no-pager | awk '{print $1, $2, $3, $4}')"
say "probes: $(for p in $PROBES; do echo -n "$p=$(systemctl is-active overlord-probe-$p.timer) "; done)alerter=$(systemctl is-active overlord-alert.path)"
