#!/usr/bin/env bash
#
# applet：SSH 加密參數稽核。
# 用 nmap ssh2-enum-algos 列出伺服器「提供」的所有演算法（不只單次連線協商出來的那一組），
# 標出其中的弱演算法。
#
# 用法：ssh-crypto.sh <CIDR> [CIDR...]
#

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need_subnets "$@" || exit 1
need_cmd nmap || exit 2

echo -e "${CYAN}=== SSH 加密參數稽核 ===${NC}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

run_nmap -p 22 --open -n --script ssh2-enum-algos -oN "$TMP/scan.nmap" "$@" || exit 1

# 弱演算法判斷（依 OpenSSH 已淘汰 / 不建議的清單）
is_weak() {
    # is_weak <類別> <演算法>
    case "$1" in
        kex_algorithms)             [[ "$2" =~ (group1-sha1|group14-sha1|group-exchange-sha1|gss-.*-sha1) ]] ;;
        server_host_key_algorithms) [[ "$2" =~ ^(ssh-dss|ssh-rsa)(-cert-v01@openssh\.com)?$ ]] ;;
        encryption_algorithms)      [[ "$2" =~ (cbc|3des|arcfour|blowfish|cast128) ]] ;;
        mac_algorithms)             [[ "$2" =~ (md5|-96|ripemd|^hmac-sha1(-etm@openssh\.com)?$) ]] ;;
        *) return 1 ;;
    esac
}

declare -A LABEL=(
    [kex_algorithms]="KEX"
    [server_host_key_algorithms]="HostKey"
    [encryption_algorithms]="Cipher"
    [mac_algorithms]="MAC"
)

# 輸出「<ip> OPEN -」或「<ip> <類別> <演算法>」
# -oN 格式：
#   Nmap scan report for 10.0.0.5
#   22/tcp open  ssh
#   | ssh2-enum-algos:
#   |   kex_algorithms: (10)
#   |       curve25519-sha256
#   |_      none
parse_algos() {
    awk '
        /^Nmap scan report for / { host = $NF; gsub(/[()]/, "", host); sec = ""; next }
        /^22\/tcp +open/ { print host, "OPEN", "-"; next }
        /^\|[ _] +[a-z_]+_algorithms: / { sec = $2; sub(/:$/, "", sec); next }
        /^\|[ _] +[^ :]+$/ && sec != "" { print host, sec, $2 }
    ' "$1"
}

hosts=()
declare -A has_data=() weak_by_host=()
while read -r ip sec algo; do
    if [[ "$sec" = OPEN ]]; then
        hosts+=("$ip")
        continue
    fi
    has_data[$ip]=1
    [[ -n "${LABEL[$sec]:-}" ]] || continue
    if is_weak "$sec" "$algo"; then
        weak_by_host[$ip]+="${weak_by_host[$ip]:+, }${LABEL[$sec]}=$algo"
    fi
done < <(parse_algos "$TMP/scan.nmap")

echo "找到 ${#hosts[@]} 台主機開啟 22 port。"
echo

weak=() clean=() nodata=()
for ip in "${hosts[@]}"; do
    if [[ -z "${has_data[$ip]:-}" ]]; then
        nodata+=("$ip")
    elif [[ -n "${weak_by_host[$ip]:-}" ]]; then
        weak+=("$ip | ${weak_by_host[$ip]}")
    else
        clean+=("$ip")
    fi
done

echo -e "${BOLD}================ SSH 加密參數總結 ================${NC}"
print_group "${RED}[!] 伺服器提供弱演算法${NC}" "${weak[@]}"
print_group "${GREEN}[+] 未發現弱演算法${NC}" "${clean[@]}"
print_group "${YELLOW}[-] 無法取得演算法清單（非標準 SSH 或連線失敗）${NC}" "${nodata[@]}"
echo "=================================================="
echo
