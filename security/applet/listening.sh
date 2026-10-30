#!/usr/bin/env bash
#
# applet：列出對外監聽的服務（略過只聽 localhost 的服務）。
# 非 root 也能執行，但看不到其他使用者的程式名稱。
#

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo -e "${CYAN}=== 對外監聽的服務 ===${NC}"
need_cmd ss || exit 2
[[ $EUID -ne 0 ]] && echo -e "${YELLOW}[提示] 非 root 執行，無法顯示其他使用者的程式名稱。${NC}"

if ! out=$(ss -H -tulnp 2>&1); then
    echo -e "${RED}[錯誤] ss 執行失敗：${NC}"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    exit 1
fi

all_if=() specific=()
declare -A seen=()
while read -r proto local_addr proc; do
    [[ -n "$proto" ]] || continue
    port="${local_addr##*:}"
    addr="${local_addr%:*}"
    addr="${addr%%\%*}"   # 去掉 %eth0 之類的介面後綴
    case "$addr" in
        127.*|'[::1]'|::1) continue ;;
        0.0.0.0|'*'|'[::]'|::) scope="all" ;;
        *) scope="$addr" ;;
    esac
    # users:(("sshd",pid=1,fd=3)) -> sshd
    proc=$(sed -n 's/^users:(("\([^"]*\)".*/\1/p' <<<"$proc")
    entry=$(printf '%-4s %-6s %s' "$proto" "$port" "${proc:--}")
    [[ -n "${RISKY_PORTS[$port]:-}" ]] && entry+=" ${RED}← 高風險：${RISKY_PORTS[$port]}${NC}"

    # IPv4 / IPv6 各聽一次的同一個服務只列一次
    [[ -n "${seen[$scope|$proto|$port]:-}" ]] && continue
    seen[$scope|$proto|$port]=1
    if [[ "$scope" = all ]]; then
        all_if+=("$entry")
    else
        specific+=("$scope  $entry")
    fi
done < <(awk '{print $1, $5, ($7 == "" ? "-" : $7)}' <<<"$out")

print_group "${YELLOW}[!] 監聽所有介面（0.0.0.0 / ::）${NC}" "${all_if[@]}"
print_group "[i] 監聽特定位址" "${specific[@]}"
