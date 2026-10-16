#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]-}"
if [[ -n "$SCRIPT_SOURCE" && "$SCRIPT_SOURCE" != /dev/fd/* && "$SCRIPT_SOURCE" != "bash" && "$SCRIPT_SOURCE" != "-s" ]]; then
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

usage() {
    cat <<'EOF' >&2
Usage:
  sync-proxy-config.sh update [all|dnsmasq|sniproxy] [proxy-ipv4]
  sync-proxy-config.sh check [all|dnsmasq|sniproxy]

Defaults:
  - update: 同步 proxy-domains.txt 到 /etc/sniproxy.conf 和 /etc/dnsmasq.d/custom_netflix.conf，并重载服务。
  - check:  检查两边配置中的域名规则是否完整。
EOF
    exit 2
}

valid_ipv4() {
    local ip="${1:-}" octet
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

get_public_ip() {
    local ip=""
    # 1. 尝试从已有 custom_netflix.conf 中提取 IP
    if [[ -r "$DNS_CONFIG" ]]; then
        ip="$(sed -n 's#^[[:space:]]*address=/[^/]\+/\([0-9.]*\)[[:space:]]*$#\1#p' "$DNS_CONFIG" 2>/dev/null | head -n1)"
        if valid_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi
    fi
    # 2. 尝试从公网查询服务获取本机外网 IP
    for url in "https://api.ipify.org" "https://icanhazip.com" "https://ipinfo.io/ip"; do
        if command -v curl >/dev/null 2>&1; then
            ip="$(curl -s4 -m 3 "$url" 2>/dev/null || true)"
        elif command -v wget >/dev/null 2>&1; then
            ip="$(wget -qO- -T 3 "$url" 2>/dev/null || true)"
        fi
        ip="$(echo "$ip" | tr -d '[:space:]')"
        if valid_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    # 3. 尝试通过路由获取本地出口 IP
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
        if valid_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi
    fi
    return 1
}

ACTION="${1:-update}"
[[ "$ACTION" == "check" || "$ACTION" == "update" ]] || usage

TARGET="all"
IP=""

if [[ $# -ge 2 ]]; then
    if valid_ipv4 "$2"; then
        TARGET="all"
        IP="$2"
    else
        case "$2" in
            sniproxy|sni) TARGET="sniproxy" ;;
            dnsmasq|dns)  TARGET="dnsmasq" ;;
            all)          TARGET="all" ;;
            *) usage ;;
        esac
        if [[ $# -ge 3 ]]; then
            IP="$3"
        fi
    fi
fi

# Fetch remote files if missing locally
NEEDED_REMOTE=()
[[ -r "$DOMAIN_FILE" ]] || NEEDED_REMOTE+=("proxy-domains.txt")
if [[ "$TARGET" == "sniproxy" || "$TARGET" == "all" ]]; then
    [[ -r "$SNI_TEMPLATE" ]] || NEEDED_REMOTE+=("sniproxy.conf")
fi
if [[ "$TARGET" == "dnsmasq" || "$TARGET" == "all" ]]; then
    [[ -r "$DNS_TEMPLATE" ]] || NEEDED_REMOTE+=("dnsmasq.conf")
fi

if ((${#NEEDED_REMOTE[@]} > 0)); then
    STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sniproxy-sync.XXXXXX")"
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
    for file in "${NEEDED_REMOTE[@]}"; do
        fetch_file "${RAW_BASE}/${file}" "${STAGE_DIR}/${file}"
    done
    [[ ! -f "${STAGE_DIR}/proxy-domains.txt" ]] || DOMAIN_FILE="${STAGE_DIR}/proxy-domains.txt"
    [[ ! -f "${STAGE_DIR}/sniproxy.conf" ]] || SNI_TEMPLATE="${STAGE_DIR}/sniproxy.conf"
    [[ ! -f "${STAGE_DIR}/dnsmasq.conf" ]] || DNS_TEMPLATE="${STAGE_DIR}/dnsmasq.conf"
fi

[[ -r "$DOMAIN_FILE" ]] || {
    echo "Domain file missing: ${DOMAIN_FILE}" >&2
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

check_sniproxy() {
    [[ -r "$SNI_CONFIG" ]] || {
        echo "SNIProxy config is missing: ${SNI_CONFIG}" >&2
        return 1
    }
    local failures=0 missing_count=0
    for domain in "${DOMAINS[@]}"; do
        escaped="${domain//./\\.}"
        if ! grep -Fqx "    .*${escaped}\$ *" "$SNI_CONFIG" && ! grep -Fqx "    .*${escaped} *" "$SNI_CONFIG"; then
            echo "SNI rule missing: ${domain}"
            failures=1
            ((missing_count++))
        fi
    done
    if ((failures)); then
        echo "Check failed: ${missing_count} domain rule(s) missing in ${SNI_CONFIG}." >&2
        return 1
    fi
    echo "OK: all ${#DOMAINS[@]} domains have SNI rules in ${SNI_CONFIG}."
}

check_dnsmasq() {
    [[ -r "$DNS_CONFIG" ]] || {
        echo "Dnsmasq config is missing: ${DNS_CONFIG}" >&2
        return 1
    }
    local check_ip="$IP"
    if ! valid_ipv4 "$check_ip"; then
        check_ip="$(sed -n 's#^[[:space:]]*address=/[^/]\+/\([0-9.]*\)[[:space:]]*$#\1#p' "$DNS_CONFIG" 2>/dev/null | head -n1)"
    fi
    valid_ipv4 "$check_ip" || {
        echo "Could not determine proxy IPv4 for checking ${DNS_CONFIG}." >&2
        return 1
    }
    local failures=0 missing_count=0
    for domain in "${DOMAINS[@]}"; do
        if ! grep -Fqx "address=/${domain}/${check_ip}" "$DNS_CONFIG"; then
            echo "DNS rule missing: ${domain} -> ${check_ip}"
            failures=1
            ((missing_count++))
        fi
    done
    if ((failures)); then
        echo "Check failed: ${missing_count} DNS rule(s) missing in ${DNS_CONFIG}." >&2
        return 1
    fi
    echo "OK: all ${#DOMAINS[@]} domains have DNS rules in ${DNS_CONFIG} (${check_ip})."
}

update_sniproxy() {
    echo "Updating sniproxy configuration (${#DOMAINS[@]} domains)..."
    [[ -r "$SNI_TEMPLATE" ]] || {
        echo "Error: sniproxy template missing: ${SNI_TEMPLATE}" >&2
        return 1
    }

    SNI_DIR="$(dirname -- "$SNI_CONFIG")"
    mkdir -p "$SNI_DIR" /var/log/sniproxy

    STAMP="$(date +%Y%m%d%H%M%S)"
    if [[ -e "$SNI_CONFIG" ]]; then
        cp -a "$SNI_CONFIG" "${SNI_CONFIG}.bak.${STAMP}"
        echo "Backed up existing config to ${SNI_CONFIG}.bak.${STAMP}"
    fi

    SNI_TMP="$(mktemp "${TMPDIR:-/tmp}/sniproxy.conf.XXXXXX")"

    awk '/^table[[:space:]]*\{/ { exit } { print }' "$SNI_TEMPLATE" > "$SNI_TMP"
    echo "table {" >> "$SNI_TMP"
    for domain in "${DOMAINS[@]}"; do
        escaped="${domain//./\\.}"
        printf '    .*%s$ *\n' "$escaped" >> "$SNI_TMP"
    done
    echo "}" >> "$SNI_TMP"

    awk '
        /^table[[:space:]]*\{/ { in_table=1; seen_table=1; next }
        in_table && /^[[:space:]]*\}/ { in_table=0; next }
        seen_table { print }
    ' "$SNI_TEMPLATE" >> "$SNI_TMP"

    chmod 0644 "$SNI_TMP"
    mv -f "$SNI_TMP" "$SNI_CONFIG"
    SNI_TMP=""

    echo "Successfully replaced ${SNI_CONFIG} with ${#DOMAINS[@]} domains."

    echo "Restarting sniproxy service..."
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl restart sniproxy 2>/dev/null; then
            if systemctl is-active --quiet sniproxy 2>/dev/null; then
                echo "[OK] sniproxy service is active and running."
            else
                echo "[Warning] sniproxy service restarted, but is not active. Check: systemctl status sniproxy" >&2
            fi
        else
            echo "[Warning] Failed to restart sniproxy service. Check: systemctl status sniproxy" >&2
        fi
    elif command -v service >/dev/null 2>&1; then
        service sniproxy restart || echo "[Warning] Failed to restart sniproxy." >&2
    elif [[ -x /etc/init.d/sniproxy ]]; then
        /etc/init.d/sniproxy restart || echo "[Warning] Failed to restart sniproxy." >&2
    fi
}

update_dnsmasq() {
    local target_ip="$1"
    valid_ipv4 "$target_ip" || {
        echo "Invalid proxy IPv4: ${target_ip}" >&2
        return 1
    }

    echo "Updating dnsmasq configuration (${#DOMAINS[@]} domains -> ${target_ip})..."
    [[ -r "$DNS_TEMPLATE" ]] || {
        echo "Error: dnsmasq template missing: ${DNS_TEMPLATE}" >&2
        return 1
    }

    DNS_DIR="$(dirname -- "$DNS_CONFIG")"
    mkdir -p "$DNS_DIR"

    STAMP="$(date +%Y%m%d%H%M%S)"
    # 将备份存放到隐藏备份目录，防止 dnsmasq conf-dir 误读取备份文件
    local backup_dir="${DNS_DIR}/.backups"
    mkdir -p "$backup_dir"
    if [[ -e "$DNS_CONFIG" ]]; then
        cp -a "$DNS_CONFIG" "${backup_dir}/custom_netflix.conf.${STAMP}.bak"
        echo "Backed up existing dnsmasq config to ${backup_dir}/custom_netflix.conf.${STAMP}.bak"
    fi

    DNS_TMP="$(mktemp "${TMPDIR:-/tmp}/custom_netflix.conf.XXXXXX")"
    cat "$DNS_TEMPLATE" > "$DNS_TMP"
    for domain in "${DOMAINS[@]}"; do
        printf 'address=/%s/%s\n' "$domain" "$target_ip" >> "$DNS_TMP"
    done

    chmod 0644 "$DNS_TMP"

    # 测试新生成配置文件的语法
    if command -v dnsmasq >/dev/null 2>&1; then
        if ! dnsmasq --test --conf-file="$DNS_TMP" >/dev/null 2>&1; then
            echo "[Error] dnsmasq syntax test failed on generated config." >&2
            rm -f "$DNS_TMP"
            DNS_TMP=""
            return 1
        fi
    fi

    mv -f "$DNS_TMP" "$DNS_CONFIG"
    DNS_TMP=""
    echo "Successfully replaced ${DNS_CONFIG} with ${#DOMAINS[@]} domains."

    # 重启 dnsmasq 服务
    echo "Restarting dnsmasq service..."
    local restart_ok=0
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl restart dnsmasq 2>/dev/null; then
            if systemctl is-active --quiet dnsmasq 2>/dev/null; then
                echo "[OK] dnsmasq service is active and running."
                restart_ok=1
            fi
        fi
    elif command -v service >/dev/null 2>&1; then
        if service dnsmasq restart 2>/dev/null; then
            echo "[OK] dnsmasq service restarted."
            restart_ok=1
        fi
    elif [[ -x /etc/init.d/dnsmasq ]]; then
        if /etc/init.d/dnsmasq restart 2>/dev/null; then
            echo "[OK] dnsmasq service restarted."
            restart_ok=1
        fi
    fi

    if ((!restart_ok)); then
        echo "[Warning] dnsmasq service failed to restart or is not active." >&2
        if command -v ss >/dev/null 2>&1 && ss -tlunp 2>/dev/null | grep -q ':53 '; then
            echo "[Note] 53 port is in use (often systemd-resolved). If so, see README to disable DNSStubListener." >&2
        elif command -v netstat >/dev/null 2>&1 && netstat -tlunp 2>/dev/null | grep -q ':53 '; then
            echo "[Note] 53 port is in use (often systemd-resolved). If so, see README to disable DNSStubListener." >&2
        fi
        if command -v journalctl >/dev/null 2>&1; then
            echo "--- dnsmasq error logs ---" >&2
            journalctl -u dnsmasq -n 5 --no-pager 2>/dev/null || true
            echo "--------------------------" >&2
        fi
    fi
}

if [[ "$ACTION" == "check" ]]; then
    case "$TARGET" in
        sniproxy)
            check_sniproxy
            ;;
        dnsmasq)
            check_dnsmasq
            ;;
        all)
            sni_fail=0
            dns_fail=0
            check_sniproxy || sni_fail=1
            if [[ -e "$DNS_CONFIG" ]]; then
                check_dnsmasq || dns_fail=1
            fi
            if ((sni_fail || dns_fail)); then
                exit 1
            fi
            ;;
    esac
    exit 0
fi

if [[ "$ACTION" == "update" ]]; then
    [[ $EUID -eq 0 ]] || { echo "Run update with sudo/root." >&2; exit 1; }
    case "$TARGET" in
        sniproxy)
            update_sniproxy
            ;;
        dnsmasq)
            if ! valid_ipv4 "$IP"; then
                IP="$(get_public_ip || true)"
            fi
            valid_ipv4 "$IP" || {
                echo "Could not auto-detect proxy IPv4. Please specify: $0 update dnsmasq 203.0.113.10" >&2
                exit 1
            }
            update_dnsmasq "$IP"
            ;;
        all)
            # 同时更新两者
            if ! valid_ipv4 "$IP"; then
                IP="$(get_public_ip || true)"
            fi
            if valid_ipv4 "$IP"; then
                update_dnsmasq "$IP"
            else
                echo "[Warning] Could not auto-detect proxy IPv4. Skipped dnsmasq update. Run '$0 update all <IP>' to update dnsmasq." >&2
            fi
            update_sniproxy
            ;;
    esac
    exit 0
fi
