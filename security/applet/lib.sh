# shellcheck shell=bash
#
# safe-test applet 共用函式。由各 applet 以 source 載入，不單獨執行。
#
# applet 退出碼約定：
#   0 = 檢查完成（不論有沒有發現問題）
#   1 = 執行失敗（工具出錯、參數錯誤等）
#   2 = 略過（缺少 root 權限或必要工具）
#

set -uo pipefail

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 高風險 port：常見未加密或預設無驗證的服務
declare -A RISKY_PORTS=(
    [21]="FTP（明文）"
    [23]="Telnet（明文）"
    [445]="SMB"
    [2375]="Docker API（無 TLS）"
    [3306]="MySQL"
    [3389]="RDP"
    [5432]="PostgreSQL"
    [5900]="VNC"
    [6379]="Redis"
    [9200]="Elasticsearch"
    [11211]="Memcached"
    [27017]="MongoDB"
)

# need_cmd <指令...>：缺少任一指令就回傳 2
need_cmd() {
    local c
    for c in "$@"; do
        if ! command -v "$c" &>/dev/null; then
            echo -e "${RED}[錯誤] 找不到 '$c'，請先安裝。${NC}"
            return 2
        fi
    done
}

# need_root <項目名稱>：非 root 就回傳 2
need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[錯誤] 「$1」需要 root，已略過（請用 sudo 執行）。${NC}"
        return 2
    fi
}

# need_subnets <CIDR...>：網路 applet 必須帶至少一個子網參數
need_subnets() {
    if [[ $# -eq 0 ]]; then
        echo "用法：$(basename "$0") <CIDR> [CIDR...]   例如：$(basename "$0") 192.168.1.0/24"
        return 1
    fi
}

print_group() {
    local title="$1"; shift
    echo -e "$title ($#):"
    local e
    for e in "$@"; do printf '  - %b\n' "$e"; done
    echo
}

# run_nmap <nmap 參數...>：結果請用 -oG / -oN 寫到檔案。
# nmap 失敗時印出錯誤並回傳 1，避免把掃描失敗誤當成「沒有主機」。
run_nmap() {
    local err rc
    err=$(nmap "$@" 2>&1 >/dev/null)
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo -e "${RED}[錯誤] nmap 執行失敗（exit $rc）：${NC}"
        printf '%s\n' "$err" | tail -n 5 | sed 's/^/  /'
        return 1
    fi
}

# parse_nmap_grepable <檔案>：輸出每個開啟的 port，一行一筆「<ip> <port>」
# -oG 格式：Host: <ip> ()<TAB>Ports: 22/open/tcp//ssh///, 23/open/tcp//telnet///<TAB>...
parse_nmap_grepable() {
    awk '
        /Ports:/ {
            ip = $2
            sub(/.*Ports: /, ""); sub(/\t.*/, "")
            n = split($0, a, ", ")
            for (i = 1; i <= n; i++) {
                split(a[i], f, "/")
                if (f[2] == "open") print ip, f[1]
            }
        }' "$1"
}
