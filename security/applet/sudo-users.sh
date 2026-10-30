#!/usr/bin/env bash
#
# applet：本機 sudo 權限稽核（需 root）。
# 列出可登入帳號的 sudo 權限：完整 sudo / 部分 sudo / 無。
#

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo -e "${CYAN}=== 本機 sudo 權限稽核 ===${NC}"
need_root "sudo 權限稽核" || exit 2
need_cmd sudo getent || exit 2

full=() partial=() errors=()
printf "%-20s %-7s %s\n" "USER" "UID" "SUDO"
while IFS=: read -r user _ uid _ _ _ shell; do
    # 略過無法登入的系統帳號（若想看全部，刪掉這段）
    case "$shell" in */nologin|*/false) continue ;; esac

    if [[ "$uid" -eq 0 ]]; then
        status="ROOT (UID 0)"
        printf "%-20s %-7s %s\n" "$user" "$uid" "$status"
        continue
    fi

    # 沒有權限的帳號 sudo 可能回傳非 0，所以先看輸出內容，都對不上才算查詢失敗
    out=$(LC_ALL=C sudo -n -l -U "$user" 2>&1)
    rc=$?
    # 例如 (ALL : ALL) ALL、(ALL) NOPASSWD: ALL、(root) ALL
    if grep -qE '\((ALL|root)( ?: ?ALL)?\) ([A-Z_]+: )*ALL[[:space:]]*$' <<<"$out"; then
        status="YES - 完整 sudo"
        full+=("$user")
    elif grep -q "may run the following" <<<"$out"; then
        status="部分 sudo（僅限特定指令）"
        partial+=("$user")
    elif grep -q "is not allowed to run sudo" <<<"$out" || [[ $rc -eq 0 ]]; then
        status="NO"
    else
        status="無法查詢"
        errors+=("$user | $(head -n 1 <<<"$out")")
    fi
    printf "%-20s %-7s %s\n" "$user" "$uid" "$status"
done < <(getent passwd)
echo

print_group "${RED}[!] 擁有完整 sudo 的帳號${NC}" "${full[@]}"
print_group "${YELLOW}[i] 擁有部分 sudo 的帳號${NC}" "${partial[@]}"
if [[ ${#errors[@]} -gt 0 ]]; then
    print_group "${RED}[錯誤] 無法查詢的帳號${NC}" "${errors[@]}"
    exit 1
fi
