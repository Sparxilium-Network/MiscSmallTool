#!/usr/bin/env bash
#
# 腳本用途：掃描本機 NVMe 磁碟，讓使用者逐顆選擇清除目標。
# 輸出詳細 SMART 記錄，並在結束時產出所選磁碟的總結報告。
#

set -euo pipefail

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 1. 檢查 Root 權限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[錯誤] 此腳本必須以 root 權限執行！${NC}" 
   exit 1
fi

# 2. 檢查必要工具
if ! command -v nvme &> /dev/null; then
    echo -e "${RED}[錯誤] 找不到 'nvme-cli'，請先安裝 (例如: apt install nvme-cli)${NC}"
    exit 1
fi

if ! command -v udevadm &> /dev/null; then
    echo -e "${RED}[錯誤] 找不到 'udevadm' 工具！${NC}"
    exit 1
fi

if ! command -v lsblk &> /dev/null || ! command -v findmnt &> /dev/null; then
    echo -e "${RED}[錯誤] 找不到 lsblk 或 findmnt（util-linux），請先安裝。${NC}"
    exit 1
fi

# 3. 判斷是否為 USB 裝置
is_usb_device() {
    local dev_path="$1"
    
    local bus_type
    bus_type=$(udevadm info --query=property --name="$dev_path" 2>/dev/null | grep "^ID_BUS=" | cut -d'=' -f2 || true)
    if [[ "$bus_type" == "usb" ]]; then
        return 0
    fi

    local sys_path
    sys_path=$(udevadm info --query=path --name="$dev_path" 2>/dev/null || true)
    if [[ "$sys_path" =~ /usb[0-9]+/ || "$sys_path" =~ /usb/ ]]; then
        return 0
    fi

    return 1
}

# 輔助函式：解析 SMART 數值
get_smart_val() {
    local dev="$1"
    local field="$2"
    nvme smart-log "$dev" 2>/dev/null | grep -E "^${field}\s*:" | awk -F: '{print $2}' | xargs || echo "N/A"
}

get_mountpoints() {
    local mounts
    mounts=$(lsblk -nrpo MOUNTPOINT "$1" 2>/dev/null | awk 'NF' | sort -u | paste -sd ', ' -)
    if [[ -n "$mounts" ]]; then
        printf '%s' "$mounts"
    else
        printf '（未掛載）'
    fi
}

read_key() {
    local key="" rest=""
    IFS= read -rsn1 key || true
    case "$key" in
        $'\x1b')
            IFS= read -rsn2 -t 0.1 rest || true
            case "$rest" in
                '[A') printf 'up' ;;
                '[B') printf 'down' ;;
                *) printf 'other' ;;
            esac ;;
        ' ') printf 'space' ;;
        '') printf 'enter' ;;
        q|Q) printf 'quit' ;;
        *) printf 'other' ;;
    esac
}

select_targets() {
    local cursor=0 count=${#TARGET_NAMESPACES[@]} i key
    local -a SELECTED_FLAGS=()
    SELECTED_NAMESPACES=()
    for ((i = 0; i < count; i++)); do SELECTED_FLAGS[i]=0; done

    while true; do
        printf '\033[H\033[2J'
        echo -e "${BOLD}選擇要清除的 NVMe 磁碟${NC}"
        echo "↑/↓ 移動  空白鍵 選取/取消  Enter 確認  q 離開"
        echo "預設不選取任何磁碟。"
        echo
        for ((i = 0; i < count; i++)); do
            local mark='[ ]'
            [[ "${SELECTED_FLAGS[i]}" = 1 ]] && mark='[*]'
            if [[ "$i" = "$cursor" ]]; then
                printf '\033[7m> '
            else
                printf '  '
            fi
            printf '%s NVME %-2d %-24s %s (%s)\n' \
                "$mark" "$((i + 1))" "${TARGET_MOUNTS[i]}" \
                "${TARGET_NAMESPACES[i]}" "${TARGET_MODELS[i]}"
            [[ "$i" = "$cursor" ]] && printf '\033[0m'
        done

        key=$(read_key)
        case "$key" in
            up) cursor=$(((cursor - 1 + count) % count)) ;;
            down) cursor=$(((cursor + 1) % count)) ;;
            space) SELECTED_FLAGS[cursor]=$((1 - SELECTED_FLAGS[cursor])) ;;
            enter) break ;;
            quit)
                echo -e "\n${YELLOW}操作已取消。${NC}"
                exit 0 ;;
        esac
    done

    for ((i = 0; i < count; i++)); do
        [[ "${SELECTED_FLAGS[i]}" = 1 ]] && SELECTED_NAMESPACES+=("${TARGET_NAMESPACES[i]}")
    done
    if [[ ${#SELECTED_NAMESPACES[@]} -eq 0 ]]; then
        echo -e "\n${YELLOW}[提示] 沒有選取任何磁碟，未執行清除。${NC}"
        exit 0
    fi
}

echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}          NVMe 磁碟掃描與過濾程序                 ${NC}"
echo -e "${CYAN}==================================================${NC}"

# 4. 掃描 NVMe 命名空間 (排除分割區與 USB)
TARGET_NAMESPACES=()
TARGET_MODELS=()
TARGET_SERIALS=()
TARGET_MOUNTS=()
SKIPPED_DEVICES=()

for dev in /dev/nvme[0-9]*n[0-9]*; do
    [[ -e "$dev" ]] || continue

    # 過濾分割區 (如 nvme0n1p1)
    if [[ "$dev" =~ p[0-9]+$ ]]; then
        continue
    fi

    if is_usb_device "$dev"; then
        SKIPPED_DEVICES+=("$dev (USB 外接裝置)")
    else
        TARGET_NAMESPACES+=("$dev")
        TARGET_MODELS+=("$(nvme id-ctrl "$dev" 2>/dev/null | grep -E '^mn\s*:' | awk -F: '{print $2}' | xargs || echo '未知型號')")
        TARGET_SERIALS+=("$(nvme id-ctrl "$dev" 2>/dev/null | grep -E '^sn\s*:' | awk -F: '{print $2}' | xargs || echo '未知序號')")
        TARGET_MOUNTS+=("$(get_mountpoints "$dev")")
    fi
done

# 顯示忽略的外接裝置
if [[ ${#SKIPPED_DEVICES[@]} -gt 0 ]]; then
    echo -e "${YELLOW}[注意] 已忽略以下 USB/外接裝置：${NC}"
    for skipped in "${SKIPPED_DEVICES[@]}"; do
        echo -e "  - $skipped"
    done
    echo ""
fi

# 檢查是否有找到硬碟
if [[ ${#TARGET_NAMESPACES[@]} -eq 0 ]]; then
    echo -e "${YELLOW}[提示] 未發現任何本機原生 NVMe 硬碟。程式結束。${NC}"
    exit 0
fi

echo -e "${GREEN}[發現磁碟] 請在選單中逐顆選擇，未選取的磁碟不會清除。${NC}"
if [[ ! -t 0 || ! -t 1 ]]; then
    echo -e "${RED}[錯誤] NVMe 磁碟選單需要互動式終端機。${NC}"
    exit 1
fi
select_targets

# 不允許清除目前承載根檔案系統的磁碟。
ROOT_SOURCE=$(findmnt -n -o SOURCE / 2>/dev/null || true)
if [[ -n "$ROOT_SOURCE" ]]; then
    ROOT_DISKS=$(lsblk -s -nrpo NAME "$ROOT_SOURCE" 2>/dev/null || true)
    for target in "${SELECTED_NAMESPACES[@]}"; do
        if grep -Fxq "$target" <<< "$ROOT_DISKS"; then
            echo -e "${RED}[錯誤] $target 承載目前的根檔案系統，不能在此系統執行清除。${NC}"
            exit 1
        fi
    done
fi

# 5. 防呆警示與確認
echo ""
echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!! 警告 !!!!!!!!!!!!!!!!!!!!!!!!${NC}"
echo -e "${RED}即將永久清除「已選取」磁碟內的所有資料！${NC}"
echo -e "${RED}包括所有分區、系統與檔案，抹除後無法復原。${NC}"
for target in "${SELECTED_NAMESPACES[@]}"; do
    index=0
    for candidate in "${TARGET_NAMESPACES[@]}"; do
        [[ "$candidate" = "$target" ]] && break
        index=$((index + 1))
    done
    echo -e "  - ${CYAN}NVME $((index + 1)) $target${NC} (${TARGET_MODELS[index]}, 序號: ${TARGET_SERIALS[index]}, 掛載點: ${TARGET_MOUNTS[index]})"
done
echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
read -rp "只清除以上選取的磁碟。確定請輸入 'YES' (大寫): " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    echo -e "${YELLOW}操作已取消。${NC}"
    exit 0
fi

LOG_DIR="./nvme_erase_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
echo -e "\n日誌輸出目錄：${CYAN}${LOG_DIR}${NC}\n"

# 6. 開始執行清除與輸出 SMART
for dev in "${SELECTED_NAMESPACES[@]}"; do
    dev_name=$(basename "$dev")
    echo -e "\n${CYAN}--------------------------------------------------${NC}"
    echo -e "${CYAN}處理目標：${dev}${NC}"
    echo -e "${CYAN}--------------------------------------------------${NC}"

    # A. 抹除前 SMART 資訊
    echo -e "${YELLOW}>>> [1/3] 讀取抹除前 SMART 記錄...${NC}"
    pre_log="${LOG_DIR}/${dev_name}_smart_PRE.txt"
    nvme smart-log "$dev" | tee "$pre_log"

    # 卸載所選 namespace 上已掛載的分割區；有任何掛載點卸載失敗就跳過清除。
    mounted_nodes=()
    while read -r node mountpoint _; do
        [[ -n "${node:-}" && -n "${mountpoint:-}" ]] && mounted_nodes+=("$node")
    done < <(lsblk -nrpo NAME,MOUNTPOINT "$dev")
    disk_ready=1
    for ((i = ${#mounted_nodes[@]} - 1; i >= 0; i--)); do
        if ! umount -- "${mounted_nodes[i]}"; then
            echo -e "${RED}[錯誤] 無法卸載 ${mounted_nodes[i]}，跳過此磁碟。${NC}"
            disk_ready=0
        fi
    done
    remaining_mounts=$(lsblk -nrpo MOUNTPOINT "$dev" | awk 'NF')
    if [[ "$disk_ready" -ne 1 || -n "$remaining_mounts" ]]; then
        echo -e "${RED}[錯誤] $dev 仍有掛載點，未執行清除。${NC}"
        continue
    fi

    # B. 執行 NVMe Secure Erase / Format
    echo -e "\n${YELLOW}>>> [2/3] 執行 NVMe 底層清除作業 (nvme format)...${NC}"
    
    echo -e "嘗試執行 Cryptographic Erase (加密抹除)..."
    if nvme format "$dev" --ses=2 --force 2>/dev/null; then
        echo -e "${GREEN}✓ Cryptographic Erase 成功完成！${NC}"
    else
        echo -e "${YELLOW}硬碟不支援 Crypto Erase，降級執行 User Data Erase...${NC}"
        if nvme format "$dev" --ses=1 --force; then
            echo -e "${GREEN}✓ User Data Erase 成功完成！${NC}"
        else
            echo -e "${RED}✗ 清除失敗，請檢查硬碟狀態。${NC}"
            continue
        fi
    fi

    # C. 抹除後 SMART 資訊
    echo -e "\n${YELLOW}>>> [3/3] 讀取抹除後 SMART 記錄...${NC}"
    post_log="${LOG_DIR}/${dev_name}_smart_POST.txt"
    nvme smart-log "$dev" | tee "$post_log"

    echo -e "${GREEN}✓ ${dev} 處理完畢。${NC}"
done

# 7. 彙整並總結所有 SMART 資訊
SUMMARY_FILE="${LOG_DIR}/SMART_SUMMARY.txt"
{
    echo "========================================================================================================================"
    echo "                                              NVMe 抹除後 SMART 總結報告                                                "
    echo "產生日時: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================================================================================================"
    printf "%-15s %-16s %-16s %-8s %-8s %-10s %-10s %-10s %-10s %-10s\n" \
        "裝置路徑" "型號" "序號" "溫度" "耗損率" "備用空間" "通電時數" "異常斷電" "媒體錯誤" "致命警告"
    echo "------------------------------------------------------------------------------------------------------------------------"

    for dev in "${SELECTED_NAMESPACES[@]}"; do
        model=$(nvme id-ctrl "$dev" 2>/dev/null | grep -E "^mn\s*:" | awk -F: '{print $2}' | xargs || echo "未知")
        sn=$(nvme id-ctrl "$dev" 2>/dev/null | grep -E "^sn\s*:" | awk -F: '{print $2}' | xargs || echo "未知")
        temp=$(get_smart_val "$dev" "temperature" | awk '{print $1}')
        used=$(get_smart_val "$dev" "percentage_used")
        spare=$(get_smart_val "$dev" "available_spare")
        poh=$(get_smart_val "$dev" "power_on_hours")
        unsafe=$(get_smart_val "$dev" "unsafe_shutdowns")
        media_err=$(get_smart_val "$dev" "media_errors")
        crit_warn=$(get_smart_val "$dev" "critical_warning")

        printf "%-15s %-16s %-16s %-8s %-8s %-10s %-10s %-10s %-10s %-10s\n" \
            "$dev" "$model" "$sn" "${temp}C" "$used" "$spare" "${poh}h" "$unsafe" "$media_err" "$crit_warn"
    done
    echo "========================================================================================================================"
    echo "指標判讀說明："
    echo "  - 耗損率 (percentage_used): 顆粒預估壽命損耗百分比 (0% 代表全新，100% 代表達到原廠表定壽命)"
    echo "  - 備用空間 (available_spare): 剩餘備用區塊 (通常為 100%)"
    echo "  - 媒體錯誤 (media_errors): 讀寫不可復原的資料錯誤次數 (正常應為 0)"
    echo "  - 致命警告 (critical_warning): 硬體異常狀態旗標 (正常應為 0)"
    echo "========================================================================================================================"
} | tee "$SUMMARY_FILE"

echo -e "\n${GREEN}✓ 已完成所選 NVMe 磁碟的清除與 SMART 擷取作業。${NC}"
echo -e "總結報告已保存至：${CYAN}${SUMMARY_FILE}${NC}"
