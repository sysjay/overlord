#!/bin/bash
# overlord secret redaction: stdin -> stdout.
#   redact.sh             filter
#   redact.sh --selftest  run fixed samples; exit 1 if any secret survives
# Installed as /usr/local/sbin/overlord-redact. Over-redaction is fine;
# a leak is not.
set -u
export LC_ALL=C

redact() {
    perl -0777 -pe '
        # PEM blocks (keys, certificates)
        s/-----BEGIN [A-Z0-9 ]+-----.*?-----END [A-Z0-9 ]+-----/[PEM BLOCK REDACTED]/gs;
        # credentials in URLs: scheme://user:pass@ -> scheme://***@
        s{([A-Za-z][A-Za-z0-9+.-]*://)[^\s/\@:"\x27]+:[^\s/\@"\x27]*\@}{$1***\@}g;
        # Authorization / Cookie headers: everything to end of line
        s/((?:Proxy-)?Authorization|Set-Cookie|Cookie)(["\x27]?\s*[:=]\s*)[^\r\n]*/$1$2***/gi;
        s/\b(Bearer|Basic)\s+[A-Za-z0-9+\/._~=-]{8,}/$1 ***/g;
        # name=value / "name": "value" where the name looks secret
        s/\b([\w.-]*(?:passw(?:or)?d|passwd|_pass|pwd|token|secret|api[_-]?key|apikey|key|psk|credential|auth)\w*)(["\x27]?\s*[=:]\s*["\x27]?)([^\s"\x27,;&}]+)/$1$2***/gi;
        # long pure-hex runs (keys, digests)
        s/\b[0-9A-Fa-f]{32,}\b/[HEX REDACTED]/g;
        # long base64-ish runs with mixed case and digits (API keys, tokens)
        s{[A-Za-z0-9+/_=-]{32,}}{ my $t = $&; ($t =~ /[A-Z]/ && $t =~ /[a-z]/ && $t =~ /[0-9]/) ? "[KEY REDACTED]" : $t }ge;
    '
}

selftest() {
    local in out leaks=0 secret
    # each secret below must not survive redaction
    local secrets=(
        "hunter2pass" "S3cr3tT0k" "rtsppw99" "wifi-psk-value" "gitpass7"
        "abcd1234efgh" "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MEFCQ0RFRkdISUpL"
        "0123456789abcdef0123456789abcdef" "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC"
        "sk-ant-api03-AbCdEf1234567890GhIjKl1234567890MnOpQr" "qwerty789"
        "dGhpc2lzYmFzaWM6c2VjcmV0" "envpass55" "mqttpw77"
    )
    in=$(cat <<'EOF'
password=hunter2pass
TOKEN: S3cr3tT0k
rtsp://admin:rtsppw99@10.0.0.20:554/h264Preview_01_main
wpa_psk=wifi-psk-value
https://jay:gitpass7@github.com/sysjay/x.git
{"api_key": "abcd1234efgh", "name": "ok"}
blob Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MEFCQ0RFRkdISUpL end
digest 0123456789abcdef0123456789abcdef
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASC
-----END PRIVATE KEY-----
ANTHROPIC_API_KEY=sk-ant-api03-AbCdEf1234567890GhIjKl1234567890MnOpQr
secret = qwerty789
Authorization: Basic dGhpc2lzYmFzaWM6c2VjcmV0
REOLINK_PASS=envpass55
mqtt_password: "mqttpw77"
EOF
)
    out=$(printf '%s\n' "$in" | redact)
    for secret in "${secrets[@]}"; do
        if grep -qF -- "$secret" <<<"$out"; then
            echo "redact selftest LEAK: ${secret:0:3}..." >&2
            leaks=$((leaks + 1))
        fi
    done
    # ordinary facts must survive
    local keep=(
        "/usr/local/sbin/overlord-collect-uba5" "cookie-cam-python"
        "Up 3 days (healthy)" "load average: 0.52"
    )
    local k kept
    kept=$(printf '%s\n' "${keep[@]}" | redact)
    for k in "${keep[@]}"; do
        if ! grep -qF -- "$k" <<<"$kept"; then
            echo "redact selftest OVER-REDACTED: $k" >&2
            leaks=$((leaks + 1))
        fi
    done
    if [ "$leaks" -ne 0 ]; then
        echo "redact selftest FAILED ($leaks)" >&2
        return 1
    fi
    echo "redact selftest ok (${#secrets[@]} secrets, ${#keep[@]} keeps)"
}

case "${1:-}" in
    --selftest) selftest ;;
    "") redact ;;
    *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac
