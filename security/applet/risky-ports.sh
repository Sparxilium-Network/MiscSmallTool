#!/usr/bin/env bash
#
# applet：高風險 port 掃描。
# 找出開啟常見未加密或預設無驗證服務（清單見 lib.sh 的 RISKY_PORTS）的主機。
#
# 用法：risky-ports.sh <CIDR> [CIDR...]
#

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need_subnets "$@" || exit 1
need_cmd nmap || exit 2

PORT_LIST=$(printf '%s\n' "${!RISKY_PORTS[@]}" | sort -n | paste -sd, -)
echo -e "${CYAN}=== 高風險 port 掃描（port: $PORT_LIST）===${NC}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

run_nmap -p "$PORT_LIST" --open -n -oG "$TMP/scan.gnmap" "$@" || exit 1

declare -A host_risky=()
while read -r ip port; do
    [[ -n "${RISKY_PORTS[$port]:-}" ]] || continue
    host_risky[$ip]+="${host_risky[$ip]:+, }$port ${RISKY_PORTS[$port]}"
done < <(parse_nmap_grepable "$TMP/scan.gnmap")

risky=()
while read -r ip; do
    [[ -n "$ip" ]] && risky+=("$ip | ${host_risky[$ip]}")
done < <(printf '%s\n' "${!host_risky[@]}" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)

print_group "${RED}[!] 開啟高風險 port${NC}" "${risky[@]}"
