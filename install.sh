#!/bin/bash
# overlord installer. Jay runs it from the repo: sudo ./install.sh
# Idempotent: rerun after any change to collect/, run/, web/, systemd/ or sudoers/.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
[ "$EUID" -eq 0 ] || { echo "run with sudo: sudo ./install.sh" >&2; exit 1; }

U=sysai
H=/home/$U
LIB=/usr/local/lib/overlord
say() { echo "== $*"; }

# --- account: create if missing, then enforce "can change nothing" ---------
if ! id "$U" >/dev/null 2>&1; then
    say "creating $U"
    useradd -m -s /bin/bash "$U"
fi
say "enforcing $U account state"
extra=$(id -nG "$U" | tr ' ' '\n' | grep -vx "$U" || true)
if [ -n "$extra" ]; then
    echo "   removing $U from: $(echo $extra)"
    usermod -G "" "$U"
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
install -o root -g root -m 644 run/prompt.md run/report.schema.json "$LIB/"

say "installing sudoers rule"
visudo -cf sudoers/overlord
install -o root -g root -m 440 sudoers/overlord /etc/sudoers.d/overlord

say "installing systemd units"
install -o root -g root -m 644 systemd/overlord.service systemd/overlord.timer \
    systemd/overlord-web.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now overlord.timer

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
