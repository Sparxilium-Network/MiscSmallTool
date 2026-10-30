#!/usr/bin/env bash
#
# applet：SSH 密碼登入稽核。
# 掃描子網內開啟 22 port 的主機，以測試帳號連線，從伺服器回應的驗證方式判斷是否允許密碼登入。
#
# 用法：ssh-pwauth.sh <CIDR> [CIDR...]
# 環境變數：SAFE_TEST_USER  測試帳號（預設 audit_user，不需存在）
#
# 注意：結果是以測試帳號測得的。若 sshd 有 Match User / Group 設定，其他帳號的結果可能不同。
#

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_USER="${SAFE_TEST_USER:-audit_user}"

need_subnets "$@" || exit 1
need_cmd nmap ssh ssh-keygen || exit 2

echo -e "${CYAN}=== SSH 密碼登入稽核（測試帳號：$TEST_USER）===${NC}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

run_nmap -p 22 --open -n -oG "$TMP/scan.gnmap" "$@" || exit 1
mapfile -t HOSTS < <(parse_nmap_grepable "$TMP/scan.gnmap" | awk '$2 == 22 {print $1}')
echo "找到 ${#HOSTS[@]} 台主機開啟 22 port。"
echo
[[ ${#HOSTS[@]} -eq 0 ]] && exit 0

# 主機金鑰驗證：複製使用者的 known_hosts 到暫存檔（不改動原檔）。
# 已知主機若金鑰不符，ssh 會直接中止，結果標成「金鑰不符」，避免被中間人回應誤導；
# 未知主機則接受新金鑰，結果加註「未驗證」。
KH_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" ]]; then
    KH_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi
KH="$TMP/known_hosts"
cp "$KH_HOME/.ssh/known_hosts" "$KH" 2>/dev/null || : >"$KH"

is_known_host() {
    ssh-keygen -F "$1" -f "$KH" &>/dev/null ||
        { [[ -r /etc/ssh/ssh_known_hosts ]] && ssh-keygen -F "$1" -f /etc/ssh/ssh_known_hosts &>/dev/null; }
}

pw_on=() pw_kbd=() pw_off=() failed=() key_bad=()
unverified=0

for ip in "${HOSTS[@]}"; do
    echo "--------------------------------------------------"
    echo "主機: $ip"

    note=""
    if ! is_known_host "$ip"; then
        note=" （主機金鑰未驗證）"
        unverified=$((unverified + 1))
    fi

    # -F /dev/null：不套用使用者 ssh_config（避免 ProxyJump 等干擾）
    out=$(ssh -v -F /dev/null \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KH" \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "${TEST_USER}@${ip}" true 2>&1 </dev/null)

    methods=$(sed -n 's/.*Permission denied (\([^)]*\)).*/\1/p' <<<"$out" | tail -n 1)

    if grep -q -E 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed' <<<"$out"; then
        status="HOSTKEY-MISMATCH"
        key_bad+=("$ip")
    elif [[ -z "$methods" ]]; then
        status="FAILED"
        failed+=("$ip | $(grep -m1 -E 'timed out|refused|No route|Connection closed|reset|kex_exchange' <<<"$out" || echo '無法判斷')")
    elif [[ ",$methods," == *",password,"* ]]; then
        status="ENABLED"
        pw_on+=("$ip | $methods$note")
    elif [[ ",$methods," == *",keyboard-interactive,"* ]]; then
        status="KBD-INTERACTIVE"
        pw_kbd+=("$ip | $methods$note")
    else
        status="DISABLED"
        pw_off+=("$ip | $methods$note")
    fi

    echo "  - 允許的驗證方式 : ${methods:-N/A}"
    echo "  - 密碼登入       : $status$note"
done

echo
echo -e "${BOLD}================ SSH 密碼登入總結 ================${NC}"
print_group "${RED}[!] 允許密碼登入${NC}" "${pw_on[@]}"
print_group "${YELLOW}[?] 僅 keyboard-interactive（可能仍接受密碼，視 PAM 設定）${NC}" "${pw_kbd[@]}"
print_group "${GREEN}[+] 不允許密碼登入${NC}" "${pw_off[@]}"
print_group "${RED}[!] 主機金鑰與 known_hosts 不符（可能遭中間人或主機重灌，結果不採信）${NC}" "${key_bad[@]}"
print_group "${YELLOW}[-] 連線失敗 / 無法判斷${NC}" "${failed[@]}"
echo "說明：以上結果以測試帳號 $TEST_USER 測得；sshd 若有 Match User/Group 設定，其他帳號可能不同。"
if [[ $unverified -gt 0 ]]; then
    echo "說明：$unverified 台主機不在 known_hosts 中，主機金鑰未驗證，結果可能被同網段的攻擊者偽造。"
fi
echo "=================================================="
echo
