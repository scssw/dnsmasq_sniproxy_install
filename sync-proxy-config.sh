#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]-}"
if [[ -n "$SCRIPT_SOURCE" && "$SCRIPT_SOURCE" != /dev/fd/* ]]; then
    ROOT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"
else
    ROOT_DIR="$PWD"
fi
DOMAIN_FILE="${ROOT_DIR}/proxy-domains.txt"
DNS_TEMPLATE="${ROOT_DIR}/dnsmasq.conf"
SNI_TEMPLATE="${ROOT_DIR}/sniproxy.conf"
DNS_CONFIG="${DNS_CONFIG:-/etc/dnsmasq.d/custom_netflix.conf}"
SNI_CONFIG="${SNI_CONFIG:-/etc/sniproxy.conf}"
STAGE_DIR=""
DNS_TMP=""
SNI_TMP=""

cleanup() {
    [[ -z "$DNS_TMP" ]] || rm -f "$DNS_TMP"
    [[ -z "$SNI_TMP" ]] || rm -f "$SNI_TMP"
    [[ -z "$STAGE_DIR" ]] || rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

if [[ ! -r "$DOMAIN_FILE" || ! -r "$DNS_TEMPLATE" || ! -r "$SNI_TEMPLATE" ]]; then
    STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dnsmasq-sniproxy.XXXXXX")"
    RAW_BASE="https://raw.githubusercontent.com/scssw/dnsmasq_sniproxy_install/master"
    fetch_file() {
        local url="$1" output="$2"
        if command -v curl >/dev/null 2>&1; then
            curl --fail --location --silent --show-error "$url" -o "$output"
        elif command -v wget >/dev/null 2>&1; then
            wget -q -O "$output" "$url"
        else
            echo "Install curl or wget to fetch project configuration." >&2
            return 1
        fi
    }
    fetch_file "${RAW_BASE}/proxy-domains.txt" "${STAGE_DIR}/proxy-domains.txt"
    fetch_file "${RAW_BASE}/dnsmasq.conf" "${STAGE_DIR}/dnsmasq.conf"
    fetch_file "${RAW_BASE}/sniproxy.conf" "${STAGE_DIR}/sniproxy.conf"
    DOMAIN_FILE="${STAGE_DIR}/proxy-domains.txt"
    DNS_TEMPLATE="${STAGE_DIR}/dnsmasq.conf"
    SNI_TEMPLATE="${STAGE_DIR}/sniproxy.conf"
fi

usage() {
    echo "Usage: $0 check | update [proxy-ipv4]" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
ACTION="$1"
[[ "$ACTION" == check || "$ACTION" == update ]] || usage
[[ -r "$DOMAIN_FILE" && -r "$DNS_TEMPLATE" && -r "$SNI_TEMPLATE" ]] || {
    echo "Required repository files are missing or unreadable." >&2
    exit 1
}

mapfile -t DOMAINS < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$DOMAIN_FILE" | tr '[:upper:]' '[:lower:]' | sort -u)
((${#DOMAINS[@]} > 0)) || { echo "Domain list is empty." >&2; exit 1; }

for domain in "${DOMAINS[@]}"; do
    [[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || {
        echo "Invalid domain in ${DOMAIN_FILE}: ${domain}" >&2
        exit 1
    }
done

valid_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

if [[ "$ACTION" == check ]]; then
    [[ -r "$DNS_CONFIG" && -r "$SNI_CONFIG" ]] || {
        echo "Installed configs are missing: ${DNS_CONFIG} and/or ${SNI_CONFIG}" >&2
        exit 1
    }
    IP="${2:-$(sed -n 's#^[[:space:]]*address=/[^/]\+/\([0-9.]*\)[[:space:]]*$#\1#p' "$DNS_CONFIG" | head -n1)}"
    valid_ipv4 "$IP" || {
        echo "Could not determine the proxy IPv4 from ${DNS_CONFIG}." >&2
        exit 1
    }
    failures=0
    for domain in "${DOMAINS[@]}"; do
        escaped="${domain//./\\.}"
        grep -Fqx "address=/${domain}/${IP}" "$DNS_CONFIG" || {
            echo "DNS rule missing: ${domain} -> ${IP}"
            failures=1
        }
        grep -Fqx "    .*${escaped}\$ *" "$SNI_CONFIG" || {
            echo "SNI rule missing: ${domain}"
            failures=1
        }
    done
    if ((failures)); then
        exit 1
    fi
    echo "OK: all ${#DOMAINS[@]} domains have DNS and SNI rules (${IP})."
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo "Run update with sudo/root." >&2; exit 1; }
IP="${2:-$(sed -n 's#^[[:space:]]*address=/[^/]\+/\([0-9.]*\)[[:space:]]*$#\1#p' "$DNS_CONFIG" 2>/dev/null | head -n1)}"
valid_ipv4 "$IP" || {
    echo "Pass the proxy server IPv4: $0 update 203.0.113.10" >&2
    exit 1
}

DNS_DIR="$(dirname -- "$DNS_CONFIG")"
SNI_DIR="$(dirname -- "$SNI_CONFIG")"
mkdir -p "$DNS_DIR" "$SNI_DIR"
STAMP="$(date +%Y%m%d%H%M%S)"
[[ ! -e "$DNS_CONFIG" ]] || cp -a "$DNS_CONFIG" "${DNS_CONFIG}.bak.${STAMP}"
[[ ! -e "$SNI_CONFIG" ]] || cp -a "$SNI_CONFIG" "${SNI_CONFIG}.bak.${STAMP}"
DNS_TMP="$(mktemp "${DNS_DIR}/.custom_netflix.conf.XXXXXX")"
SNI_TMP="$(mktemp "${SNI_DIR}/.sniproxy.conf.XXXXXX")"
cat "$DNS_TEMPLATE" > "$DNS_TMP"
for domain in "${DOMAINS[@]}"; do
    printf 'address=/%s/%s\n' "$domain" "$IP" >> "$DNS_TMP"
done
awk -v domains_file="$DOMAIN_FILE" '
    BEGIN {
        while ((getline domain < domains_file) > 0) {
            sub(/[[:space:]]*#.*/, "", domain)
            domain = tolower(domain)
            if (domain != "") {
                gsub(/\./, "\\\\.", domain)
                generated[".*" domain "$"] = 1
            }
        }
        close(domains_file)
    }
    /^table[[:space:]]*\{/ {
        print
        while ((getline line) > 0 && line !~ /^[[:space:]]*\}/) {}
        for (domain in generated) print "    " domain " *"
        print "}"
        next
    }
    { print }
' "$SNI_TEMPLATE" > "$SNI_TMP"
chmod 0644 "$DNS_TMP" "$SNI_TMP"
if command -v dnsmasq >/dev/null 2>&1; then
    dnsmasq --test --conf-file="$DNS_TMP"
fi
mv -f "$DNS_TMP" "$DNS_CONFIG"
mv -f "$SNI_TMP" "$SNI_CONFIG"
DNS_TMP=""
SNI_TMP=""
systemctl restart dnsmasq
systemctl restart sniproxy
echo "Updated ${#DOMAINS[@]} DNS/SNI domain rules for ${IP}. Backups use .bak.${STAMP}."
