#!/usr/bin/env bash
#
# 腳本用途：安全檢查入口。以勾選清單選擇要執行的檢查項目，
# 再依序呼叫 applet/ 底下對應的腳本。各 applet 也可以單獨執行。
#
#   [網路] applet/ssh-pwauth.sh     SSH 密碼登入稽核
#   [網路] applet/ssh-crypto.sh     SSH 加密參數稽核（伺服器提供的所有演算法）
#   [網路] applet/risky-ports.sh    高風險 port 掃描
#   [本機] applet/sshd-config.sh    sshd 設定檢查（需 root）
#   [本機] applet/weak-accounts.sh  空密碼 / UID 0 帳號（需 root）
#   [本機] applet/listening.sh      對外監聽的服務
#   [本機] applet/sudo-users.sh     sudo 權限稽核（需 root）
#   [輸出] 匯出報告（去除顏色的純文字檔）
#
# 已知風險（未處理）：匯出報告使用目前目錄下可預測的檔名，會跟隨同名符號連結並
# 截斷目標，檔案權限取決於 umask。請勿在他人可寫入的目錄以 root 匯出。
#
# 僅能用於你有權限稽核的網路與主機。
#

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APPLET_DIR="$SCRIPT_DIR/applet"
source "$APPLET_DIR/lib.sh"

# 子網總 IP 數超過此值，或任一子網大於 /16 時，要求輸入 yes 確認
LARGE_SCAN_IPS=65536

# 檢查項目：applet 名稱 / 說明 / 預設是否勾選 / 是否需要選子網
# applet 名稱為空的是輸出選項，不是檢查
CHECK_APPLETS=(ssh-pwauth ssh-crypto risky-ports sshd-config weak-accounts listening sudo-users "")
CHECK_LABELS=(
    "[網路] SSH 密碼登入稽核（掃描子網 22 port）"
    "[網路] SSH 加密參數稽核（KEX / Host Key / Cipher / MAC）"
    "[網路] 高風險 port 掃描（Telnet / SMB / RDP / Redis ...）"
    "[本機] sshd 設定檢查（需 root）"
    "[本機] 空密碼 / UID 0 帳號（需 root）"
    "[本機] 對外監聽的服務"
    "[本機] sudo 權限稽核（需 root）"
    "[輸出] 匯出報告（純文字檔，存到目前目錄，有風險，見下方說明）"
)
# 游標停在該項目時，在選單下方顯示的提醒
CHECK_HINTS=("" "" "" "" "" "" ""
    "${YELLOW}[風險] 報告檔名可預測，會跟隨同名符號連結並截斷目標；權限取決於 umask，稽核內容可能被他人讀取。請勿在他人可寫入的目錄（如 /tmp）以 root 匯出。${NC}"
)
CHECK_DEFAULTS=(1 1 1 0 0 0 0 0)
CHECK_NEEDS_NET=(1 1 1 0 0 0 0 0)

read_key() {
    local key="" rest=""
    IFS= read -rsn1 key </dev/tty || true
    case "$key" in
        $'\x1b')
            IFS= read -rsn2 -t 0.1 rest </dev/tty || true
            case "$rest" in
                '[A') printf 'up' ;;
                '[B') printf 'down' ;;
                *) printf 'other' ;;
            esac ;;
        ' ') printf 'space' ;;
        '') printf 'enter' ;;
        a|A) printf 'all' ;;
        q|Q) printf 'quit' ;;
        *) printf 'other' ;;
    esac
}

# checklist <標題> <標籤陣列名> <預設陣列名> [提醒陣列名]
# 結果寫入全域陣列 PICKED（被勾選項目的索引）
# 選單直接畫在 /dev/tty，不會進到匯出的報告裡
checklist() {
    local title="$1"
    local -n _labels="$2" _defaults="$3"
    local -a _hints=()
    if [[ -n "${4:-}" ]]; then
        local -n _hint_ref="$4"
        _hints=("${_hint_ref[@]}")
    fi
    local cursor=0 count=${#_labels[@]} i key all
    local -a flags=("${_defaults[@]}")
    PICKED=()

    while true; do
        {
            printf '\033[H\033[2J'
            echo -e "${BOLD}${title}${NC}"
            echo "↑/↓ 移動  空白鍵 勾選/取消  a 全選/全不選  Enter 執行  q 離開"
            echo
            for ((i = 0; i < count; i++)); do
                local mark='[ ]'
                [[ "${flags[i]}" = 1 ]] && mark='[*]'
                if [[ "$i" = "$cursor" ]]; then
                    printf '\033[7m> %s %s\033[0m\n' "$mark" "${_labels[i]}"
                else
                    printf '  %s %s\n' "$mark" "${_labels[i]}"
                fi
            done
            if [[ -n "${_hints[cursor]:-}" ]]; then
                echo
                echo -e "${_hints[cursor]}"
            fi
        } >/dev/tty

        key=$(read_key)
        case "$key" in
            up) cursor=$(((cursor - 1 + count) % count)) ;;
            down) cursor=$(((cursor + 1) % count)) ;;
            space) flags[cursor]=$((1 - flags[cursor])) ;;
            all)
                all=1
                for ((i = 0; i < count; i++)); do [[ "${flags[i]}" = 1 ]] || all=0; done
                for ((i = 0; i < count; i++)); do flags[i]=$((1 - all)); done ;;
            enter) break ;;
            quit)
                echo -e "\n${YELLOW}操作已取消。${NC}" >/dev/tty
                exit 0 ;;
        esac
    done
    printf '\033[H\033[2J' >/dev/tty

    for ((i = 0; i < count; i++)); do
        [[ "${flags[i]}" = 1 ]] && PICKED+=("$i")
    done
}

# 偵測子網讓使用者勾選，並確認掃描範圍。結果寫入全域陣列 SUBNETS
select_subnets() {
    local -a sub_labels=() sub_cidrs=() sub_defaults=()
    local iface cidr prefix i total=0 large=0
    SUBNETS=()

    while read -r iface cidr; do
        prefix="${cidr#*/}"
        sub_cidrs+=("$cidr")
        sub_labels+=("$(printf '%-16s %-20s %s 個 IP' "$iface" "$cidr" "$((1 << (32 - prefix)))")")
        # 容器 / 虛擬橋接介面預設不勾
        if [[ "$iface" =~ ^(docker|br-|veth|virbr|cni|flannel|cali|tailscale|zt) ]]; then
            sub_defaults+=(0)
        else
            sub_defaults+=(1)
        fi
    done < <(ip -o -4 addr show | awk '$2 != "lo" {print $2, $4}')

    if [[ ${#sub_cidrs[@]} -eq 0 ]]; then
        echo -e "${RED}[錯誤] 找不到任何有 IPv4 位址的網路介面。${NC}"
        return 1
    fi

    checklist "選擇要掃描的子網" sub_labels sub_defaults
    for i in "${PICKED[@]}"; do
        cidr="${sub_cidrs[i]}"
        prefix="${cidr#*/}"
        SUBNETS+=("$cidr")
        total=$((total + (1 << (32 - prefix))))
        [[ "$prefix" -lt 16 ]] && large=1
    done
    [[ ${#SUBNETS[@]} -eq 0 ]] && return 0

    {
        echo -e "${BOLD}掃描範圍${NC}"
        for cidr in "${SUBNETS[@]}"; do echo "  - $cidr"; done
        echo "  共 $total 個 IP"
    } >/dev/tty

    if [[ $large = 1 || $total -gt $LARGE_SCAN_IPS ]]; then
        local answer
        echo -e "${YELLOW}[注意] 掃描範圍很大，會花很長時間，也可能觸發網路的入侵偵測。${NC}" >/dev/tty
        read -rp "確定要掃描請輸入 yes：" answer </dev/tty >/dev/tty 2>&1
        if [[ "$answer" != yes ]]; then
            echo -e "${YELLOW}已取消網路檢查。${NC}" >/dev/tty
            SUBNETS=()
        fi
    fi
}

# ---- 主流程 ----

if [[ ! -t 1 ]] || ! { : </dev/tty; } 2>/dev/null; then
    echo -e "${RED}[錯誤] 勾選選單需要互動式終端機。${NC}"
    exit 1
fi

checklist "安全檢查項目" CHECK_LABELS CHECK_DEFAULTS CHECK_HINTS

EXPORT=0
NEEDS_NET=0
RUN_IDX=()
for i in "${PICKED[@]}"; do
    if [[ -z "${CHECK_APPLETS[i]}" ]]; then
        EXPORT=1
    else
        RUN_IDX+=("$i")
        [[ "${CHECK_NEEDS_NET[i]}" = 1 ]] && NEEDS_NET=1
    fi
done
if [[ ${#RUN_IDX[@]} -eq 0 ]]; then
    echo -e "${YELLOW}[提示] 沒有勾選任何檢查項目。${NC}"
    exit 0
fi

SUBNETS=()
if [[ $NEEDS_NET = 1 ]]; then
    if need_cmd ip; then
        select_subnets || true
    fi
fi

REPORT=""
if [[ $EXPORT = 1 ]]; then
    REPORT="$PWD/safe-test-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).txt"
    if ! : >"$REPORT" 2>/dev/null; then
        echo -e "${RED}[錯誤] 無法寫入 $REPORT，請換到可寫入的目錄再執行。${NC}"
        exit 1
    fi
    # 畫面照常顯示彩色輸出；報告檔去除 ANSI 控制碼
    exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g' >"$REPORT")) 2>&1
    TEE_PID=$!
fi

echo "==================== safe-test ===================="
echo "時間  : $(date '+%Y-%m-%d %H:%M:%S')"
echo "主機  : $(hostname 2>/dev/null)"
echo "執行者: $(id -un) (UID $EUID)"
[[ $NEEDS_NET = 1 ]] && echo "子網  : ${SUBNETS[*]:-（未選取）}"
echo "項目  :"
for i in "${RUN_IDX[@]}"; do echo "  - ${CHECK_LABELS[i]}"; done
echo "==================================================="
echo

# 依序執行 applet，記錄每一項的結果
RESULTS=()
rc=0
for i in "${RUN_IDX[@]}"; do
    applet="$APPLET_DIR/${CHECK_APPLETS[i]}.sh"
    args=()
    if [[ "${CHECK_NEEDS_NET[i]}" = 1 ]]; then
        if [[ ${#SUBNETS[@]} -eq 0 ]]; then
            RESULTS+=("${YELLOW}略過${NC}  ${CHECK_LABELS[i]}（沒有選取子網）")
            rc=1
            continue
        fi
        args=("${SUBNETS[@]}")
    fi

    if [[ ! -f "$applet" ]]; then
        echo -e "${RED}[錯誤] 找不到 $applet${NC}"
        echo
        status=1
    else
        bash "$applet" "${args[@]}"
        status=$?
    fi

    case "$status" in
        0) RESULTS+=("${GREEN}完成${NC}  ${CHECK_LABELS[i]}") ;;
        2) RESULTS+=("${YELLOW}略過${NC}  ${CHECK_LABELS[i]}"); rc=1 ;;
        *) RESULTS+=("${RED}失敗${NC}  ${CHECK_LABELS[i]}（exit $status）"); rc=1 ;;
    esac
done

echo -e "${BOLD}==================== 執行結果 ====================${NC}"
for r in "${RESULTS[@]}"; do echo -e "  $r"; done
echo "==================================================="

if [[ -n "$REPORT" ]]; then
    echo "報告已存到：$REPORT"
    # 關閉輸出讓 tee / sed 寫完再結束
    exec >&- 2>&-
    wait "$TEE_PID" 2>/dev/null
    sleep 0.2
fi
exit "$rc"
