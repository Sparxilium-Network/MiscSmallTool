#!/usr/bin/env bash
#
# applet：本機 sshd 設定檢查（需 root）。
# 讀取 sshd -T 輸出的實際生效設定（已合併 Include），逐項標示 OK / WARN / BAD。
#

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo -e "${CYAN}=== 本機 sshd 設定檢查 ===${NC}"
need_root "sshd 設定檢查" || exit 2

SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)
if [[ ! -x "$SSHD_BIN" ]]; then
    echo -e "${YELLOW}[提示] 找不到 sshd，本機可能沒有安裝 SSH 伺服器。${NC}"
    echo
    exit 0
fi

# sshd -T 鍵值為小寫
declare -A cfg=()
if ! out=$("$SSHD_BIN" -T 2>&1); then
    echo -e "${RED}[錯誤] sshd -T 執行失敗（可能設定檔有誤）：${NC}"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    exit 1
fi
while read -r k v; do cfg[$k]="$v"; done <<<"$out"

bad=0 warn=0
report_item() {
    # report_item <OK|WARN|BAD> <項目> <值> [說明]
    local color="$GREEN"
    case "$1" in
        WARN) color="$YELLOW"; warn=$((warn + 1)) ;;
        BAD)  color="$RED"; bad=$((bad + 1)) ;;
    esac
    printf "  ${color}%-4s${NC} %-32s %-20s %s\n" "$1" "$2" "$3" "${4:-}"
}

val="${cfg[permitrootlogin]:-?}"
case "$val" in
    yes) report_item BAD PermitRootLogin "$val" "root 可用密碼登入" ;;
    no) report_item OK PermitRootLogin "$val" ;;
    *) report_item OK PermitRootLogin "$val" "root 僅能用金鑰" ;;
esac

val="${cfg[passwordauthentication]:-?}"
if [[ "$val" = yes ]]; then
    report_item WARN PasswordAuthentication "$val" "建議改用金鑰登入"
else
    report_item OK PasswordAuthentication "$val"
fi

val="${cfg[permitemptypasswords]:-?}"
if [[ "$val" = yes ]]; then
    report_item BAD PermitEmptyPasswords "$val" "空密碼帳號可直接登入"
else
    report_item OK PermitEmptyPasswords "$val"
fi

# OpenSSH 8.7 起改名為 KbdInteractiveAuthentication
k=kbdinteractiveauthentication
[[ -z "${cfg[$k]:-}" ]] && k=challengeresponseauthentication
val="${cfg[$k]:-?}"
if [[ "$val" = yes && "${cfg[usepam]:-no}" = yes ]]; then
    report_item WARN KbdInteractiveAuthentication "$val" "搭配 UsePAM 時等同允許密碼"
else
    report_item OK KbdInteractiveAuthentication "$val"
fi

val="${cfg[x11forwarding]:-?}"
if [[ "$val" = yes ]]; then
    report_item WARN X11Forwarding "$val" "不需要的話建議關閉"
else
    report_item OK X11Forwarding "$val"
fi

val="${cfg[maxauthtries]:-?}"
if [[ "$val" =~ ^[0-9]+$ && "$val" -gt 6 ]]; then
    report_item WARN MaxAuthTries "$val" "建議 6 以下"
else
    report_item OK MaxAuthTries "$val"
fi

echo
echo "  結果：${bad} 項高風險、${warn} 項建議調整"
echo "  說明：以上為全域設定；Match 區塊對特定使用者 / 來源的覆寫請用 sshd -T -C 個別查詢。"
echo
