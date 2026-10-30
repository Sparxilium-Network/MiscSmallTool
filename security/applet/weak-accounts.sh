#!/usr/bin/env bash
#
# applet：空密碼 / UID 0 帳號檢查（需 root）。
#

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo -e "${CYAN}=== 空密碼 / UID 0 帳號 ===${NC}"
need_root "空密碼 / UID 0 帳號檢查" || exit 2

if [[ ! -r /etc/shadow ]]; then
    echo -e "${RED}[錯誤] 無法讀取 /etc/shadow。${NC}"
    exit 1
fi

# /etc/shadow 第 2 欄為空 = 不需密碼即可登入（"!"、"*" 是鎖定，不算）
mapfile -t empty_pw < <(awk -F: '$2 == "" {print $1}' /etc/shadow)
mapfile -t uid0 < <(getent passwd | awk -F: '$3 == 0 && $1 != "root" {print $1 " (shell: " $7 ")"}')

print_group "${RED}[!] 空密碼帳號${NC}" "${empty_pw[@]}"
print_group "${RED}[!] 非 root 但 UID 為 0 的帳號${NC}" "${uid0[@]}"
