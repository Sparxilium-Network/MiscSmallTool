#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rc=$?; echo "錯誤：第 ${LINENO} 行執行失敗（exit=${rc}）：${BASH_COMMAND}" >&2; exit "${rc}"' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "請使用 sudo 執行：sudo bash $0"
    exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
    read -r -p "請輸入 Share 要使用的 Linux 使用者名稱: " TARGET_USER
fi
if ! id "${TARGET_USER}" >/dev/null 2>&1; then
    echo "錯誤：Linux 使用者 '${TARGET_USER}' 不存在。"
    exit 1
fi

TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
TARGET_HOME_REAL=""
if [[ -n "${TARGET_HOME}" && -d "${TARGET_HOME}" ]]; then
    TARGET_HOME_REAL="$(realpath -e -- "${TARGET_HOME}")"
fi

# 分享路徑：預設為使用者的 Home，可自行輸入其他絕對路徑（例如 /opt）。
DEFAULT_PATH="${TARGET_HOME_REAL}"
if [[ -t 0 ]]; then
    read -r -p "要分享的路徑 [${DEFAULT_PATH:-<無預設>}]: " SHARE_PATH_INPUT
else
    SHARE_PATH_INPUT=""
fi
SHARE_PATH_INPUT="${SHARE_PATH_INPUT:-${DEFAULT_PATH}}"
if [[ -z "${SHARE_PATH_INPUT}" ]]; then
    echo "錯誤：找不到 ${TARGET_USER} 的 Home 目錄，且沒有輸入分享路徑。"
    exit 1
fi
if [[ "${SHARE_PATH_INPUT}" != /* ]]; then
    echo "錯誤：分享路徑必須是絕對路徑：${SHARE_PATH_INPUT}"
    exit 1
fi
if [[ ! -d "${SHARE_PATH_INPUT}" ]]; then
    echo "錯誤：分享路徑不存在或不是目錄：${SHARE_PATH_INPUT}"
    exit 1
fi
SHARE_PATH="$(realpath -e -- "${SHARE_PATH_INPUT}")"
# smb.conf 會把 % 當成變數替換、換行會破壞設定檔，這兩種直接拒絕。
if [[ "${SHARE_PATH}" == *%* || "${SHARE_PATH}" == *$'\n'* ]]; then
    echo "錯誤：分享路徑不能包含 % 或換行：${SHARE_PATH}"
    exit 1
fi

# Share 名稱：Home → <使用者>-home；其他路徑 → 最後一層目錄名稱。可自行修改。
if [[ -n "${TARGET_HOME_REAL}" && "${SHARE_PATH}" == "${TARGET_HOME_REAL}" ]]; then
    DEFAULT_SHARE="${TARGET_USER}-home"
elif [[ "${SHARE_PATH}" == "/" ]]; then
    DEFAULT_SHARE="root"
else
    DEFAULT_SHARE="$(basename -- "${SHARE_PATH}")"
fi
if [[ -t 0 ]]; then
    read -r -p "Share 名稱 [${DEFAULT_SHARE}]: " SHARE_NAME
else
    SHARE_NAME=""
fi
SHARE_NAME="${SHARE_NAME:-${DEFAULT_SHARE}}"
if [[ ! "${SHARE_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]]; then
    echo "錯誤：Share 名稱只能使用英數字、. _ -，開頭必須是英數字，最長 80 字元：${SHARE_NAME}"
    exit 1
fi
case "${SHARE_NAME,,}" in
    global|homes|printers|print\$|ipc\$)
        echo "錯誤：${SHARE_NAME} 是 Samba 保留名稱，請換一個。"
        exit 1
        ;;
esac

# 檢查分享路徑是否包含該使用者的 Home（例如分享 / 或 /home），用來顯示 .ssh 警告。
SHARE_CONTAINS_HOME=0
if [[ -n "${TARGET_HOME_REAL}" ]]; then
    if [[ "${SHARE_PATH}" == "/" || "${TARGET_HOME_REAL}" == "${SHARE_PATH}" || "${TARGET_HOME_REAL}" == "${SHARE_PATH}/"* ]]; then
        SHARE_CONTAINS_HOME=1
    fi
fi

# 以該使用者身分檢查存取權限（群組、ACL 都會被核心納入判斷）。
# 使用 bash 內建的 [[ ]]，不用外部 /usr/bin/test：Ubuntu 25.10 起的 uutils
# coreutils 版 test -w 會忽略 POSIX ACL，造成有 ACL 寫入權限時誤判。
PATH_ACCESS_OK=1
if ! runuser -u "${TARGET_USER}" -- bash -c '[[ -r "$1" && -w "$1" && -x "$1" ]]' _ "${SHARE_PATH}"; then
    PATH_ACCESS_OK=0
fi

SMB_CONF="/etc/samba/smb.conf"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${SMB_CONF}.bak.${TIMESTAMP}"

EXISTING_CONF=0
EXISTING_SHARE=0
EXISTING_USER=0

[[ -s "${SMB_CONF}" ]] && EXISTING_CONF=1
if [[ -f "${SMB_CONF}" ]] && grep -Eiq "^[[:space:]]*\[${SHARE_NAME//./\\.}\][[:space:]]*$" "${SMB_CONF}"; then
    EXISTING_SHARE=1
fi
if command -v pdbedit >/dev/null 2>&1 && pdbedit -L 2>/dev/null | cut -d: -f1 | grep -Fxq "${TARGET_USER}"; then
    EXISTING_USER=1
fi

SEL_SECURITY=1
SEL_SHARE=1
SEL_PASSWORD=1
SEL_SERVICE=1
SEL_FIREWALL=1
(( EXISTING_USER )) && SEL_PASSWORD=0

mark() {
    if (( "$1" )); then printf '[*]'; else printf '[ ]'; fi
}

toggle_var() {
    local name="$1"
    local value="${!name}"
    if (( value )); then printf -v "${name}" '%d' 0; else printf -v "${name}" '%d' 1; fi
}

selector_value() {
    case "$1" in
        0) printf '%s' "${SEL_SECURITY}" ;;
        1) printf '%s' "${SEL_SHARE}" ;;
        2) printf '%s' "${SEL_PASSWORD}" ;;
        3) printf '%s' "${SEL_SERVICE}" ;;
        4) printf '%s' "${SEL_FIREWALL}" ;;
    esac
}

selector_label() {
    case "$1" in
        0) printf '%s' "SMB 安全設定" ;;
        1) printf '%s' "Share 設定 (${SHARE_NAME})" ;;
        2) printf '%s' "Samba 密碼" ;;
        3) printf '%s' "Samba / NetBIOS 服務設定" ;;
        4) printf '%s' "UFW 防火牆設定" ;;
    esac
}

toggle_selector_index() {
    case "$1" in
        0) toggle_var SEL_SECURITY ;;
        1) toggle_var SEL_SHARE ;;
        2)
            if (( EXISTING_USER )); then
                toggle_var SEL_PASSWORD
            else
                SEL_PASSWORD=1
            fi
            ;;
        3) toggle_var SEL_SERVICE ;;
        4) toggle_var SEL_FIREWALL ;;
    esac
}

show_selector() {
    local cursor="$1"
    local i value prefix lock_note

    # 清掉畫面後重繪選單，避免方向鍵 escape sequence 出現在提示列。
    printf '\033[2J\033[H'
    echo "============================================================"
    echo "偵測到既有 Samba 設定 / 使用者"
    echo
    printf "  smb.conf      : %s\n" "$([[ ${EXISTING_CONF} -eq 1 ]] && echo '存在' || echo '不存在')"
    printf "  Share         : %s (%s)\n" "$([[ ${EXISTING_SHARE} -eq 1 ]] && echo '存在' || echo '不存在')" "${SHARE_NAME}"
    printf "  SMB User      : %s (%s)\n" "$([[ ${EXISTING_USER} -eq 1 ]] && echo '存在' || echo '不存在')" "${TARGET_USER}"
    echo
    echo "選擇要套用 / 覆蓋的項目："
    echo

    for i in 0 1 2 3 4; do
        value="$(selector_value "${i}")"
        if (( i == cursor )); then
            prefix=">"
        else
            prefix=" "
        fi

        lock_note=""
        if (( i == 2 && !EXISTING_USER )); then
            lock_note="  (必要)"
        fi

        printf " %s %s %d. %s%s\n" \
            "${prefix}" "$(mark "${value}")" "$((i + 1))" \
            "$(selector_label "${i}")" "${lock_note}"
    done

    echo
    echo "操作：↑/↓ 移動   Space 切換   Enter 確認"
    echo "      A 全選      N 全不選"
    echo "============================================================"
}

interactive_selector() {
    local cursor=0
    local key rest

    # 非互動環境時，保留目前預設選項直接繼續。
    if [[ ! -t 0 ]]; then
        echo "警告：目前不是互動式終端，使用預設選取項目。"
        return 0
    fi

    while true; do
        show_selector "${cursor}"

        key=""
        IFS= read -rsn1 key || true

        # 方向鍵會送出 ESC [ A / ESC [ B。
        if [[ "${key}" == $'\x1b' ]]; then
            rest=""
            IFS= read -rsn2 -t 0.2 rest || true
            key+="${rest}"
        fi

        case "${key}" in
            $'\x1b[A')
                (( cursor > 0 )) && ((cursor--)) || true
                ;;
            $'\x1b[B')
                (( cursor < 4 )) && ((cursor++)) || true
                ;;
            ' ')
                toggle_selector_index "${cursor}"
                ;;
            '')
                break
                ;;
            a|A)
                SEL_SECURITY=1
                SEL_SHARE=1
                SEL_PASSWORD=1
                SEL_SERVICE=1
                SEL_FIREWALL=1
                ;;
            n|N)
                SEL_SECURITY=0
                SEL_SHARE=0
                if (( EXISTING_USER )); then
                    SEL_PASSWORD=0
                else
                    SEL_PASSWORD=1
                fi
                SEL_SERVICE=0
                SEL_FIREWALL=0
                ;;
        esac
    done

    # 清除選單畫面，再顯示最終選擇摘要。
    printf '\033[2J\033[H'
    echo "已確認選取項目："
    printf "  %s SMB 安全設定\n" "$(mark "${SEL_SECURITY}")"
    printf "  %s Share 設定\n" "$(mark "${SEL_SHARE}")"
    printf "  %s Samba 密碼\n" "$(mark "${SEL_PASSWORD}")"
    printf "  %s Samba / NetBIOS 服務設定\n" "$(mark "${SEL_SERVICE}")"
    printf "  %s UFW 防火牆設定\n" "$(mark "${SEL_FIREWALL}")"
    echo
}

if (( EXISTING_CONF || EXISTING_SHARE || EXISTING_USER )); then
    interactive_selector
fi

if (( !SEL_SECURITY && !SEL_SHARE && !SEL_PASSWORD && !SEL_SERVICE && !SEL_FIREWALL )); then
    echo "沒有選取任何項目，結束。"
    exit 0
fi

if (( !EXISTING_USER && !SEL_PASSWORD )); then
    echo "錯誤：Samba 使用者 '${TARGET_USER}' 尚不存在，必須選取 [*] 3. Samba 密碼。"
    exit 1
fi

SMB_PASSWORD=""
if (( SEL_PASSWORD )); then
    echo
    if (( EXISTING_USER )); then
        echo "即將重設 Samba 使用者 '${TARGET_USER}' 的密碼。"
    else
        echo "請設定 Samba 使用者 '${TARGET_USER}' 的密碼。"
    fi
    echo "建議至少 12 個字元，且不要與 Linux / SSH 密碼相同。"
    read -r -s -p "SMB 密碼: " SMB_PASSWORD
    echo
    read -r -s -p "再次輸入 SMB 密碼: " SMB_PASSWORD_CONFIRM
    echo
    if [[ "${SMB_PASSWORD}" != "${SMB_PASSWORD_CONFIRM}" ]]; then
        echo "錯誤：兩次輸入的 SMB 密碼不一致。"
        exit 1
    fi
    if (( ${#SMB_PASSWORD} < 12 )); then
        echo "錯誤：SMB 密碼至少需要 12 個字元。"
        exit 1
    fi
    unset SMB_PASSWORD_CONFIRM
fi

PRIMARY_IF="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
AUTO_CIDR=""
if [[ -n "${PRIMARY_IF}" ]]; then
    AUTO_CIDR="$(ip -4 route show dev "${PRIMARY_IF}" proto kernel scope link 2>/dev/null | awk '$1 ~ /^[0-9]+\./ && $1 ~ /\// {print $1; exit}')"
fi
SMB_ALLOWED_CIDR="${SMB_ALLOWED_CIDR:-${AUTO_CIDR}}"

echo
echo "================================================================"
echo "即將套用以下項目"
printf "  %s SMB 安全設定\n" "$(mark "${SEL_SECURITY}")"
printf "  %s Share 設定\n" "$(mark "${SEL_SHARE}")"
printf "  %s Samba 密碼\n" "$(mark "${SEL_PASSWORD}")"
printf "  %s Samba / NetBIOS 服務設定\n" "$(mark "${SEL_SERVICE}")"
printf "  %s UFW 防火牆設定\n" "$(mark "${SEL_FIREWALL}")"
echo
echo "Linux 使用者 : ${TARGET_USER}"
echo "分享路徑     : ${SHARE_PATH}"
echo "SMB Share    : ${SHARE_NAME}"
if (( SEL_SECURITY )); then
    echo
    echo "安全設定：SMB3.1.1 only、加密 required、signing mandatory、NTLMv2 only、禁 guest/NetBIOS/printing"
fi
if (( SEL_SHARE )); then
    echo
    echo "警告：整個 ${SHARE_PATH} 將透過 SMB 暴露。"
    if (( SHARE_CONTAINS_HOME )); then
        echo "警告：此路徑包含 ${TARGET_USER} 的 Home（${TARGET_HOME_REAL}），.ssh、私鑰與 authorized_keys 也會暴露。"
    fi
    echo "連入 ${SHARE_NAME} 後，檔案操作會強制以 ${TARGET_USER} 執行。"
fi
if (( SEL_FIREWALL )); then
    echo "LAN CIDR     : ${SMB_ALLOWED_CIDR:-<無法自動偵測>}"
fi
echo "================================================================"
echo

if (( SEL_SHARE && !PATH_ACCESS_OK )); then
    echo "警告：${TARGET_USER} 對 ${SHARE_PATH} 沒有完整的讀 / 寫 / 進入（rwx）權限。"
    echo "      透過 SMB 存取時會出現「存取被拒」。本腳本不會修改任何檔案權限，"
    echo "      需要時請自行用 chown / chmod / setfacl 調整。"
    read -r -p "仍要繼續？請輸入 yes: " ACCESS_CONFIRM
    if [[ "${ACCESS_CONFIRM}" != "yes" ]]; then
        unset SMB_PASSWORD
        echo "已取消，沒有修改系統。"
        exit 0
    fi
    echo
fi

read -r -p "確定套用以上選取項目？請輸入 YES: " CONFIRM
if [[ "${CONFIRM}" != "YES" ]]; then
    unset SMB_PASSWORD
    echo "已取消，沒有修改系統。"
    exit 0
fi

echo
echo "[1/8] 確認 Samba / Python..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y samba python3

echo "[2/8] 備份 Samba 設定..."
if [[ -f "${SMB_CONF}" ]]; then cp -a "${SMB_CONF}" "${BACKUP}"; else : > "${BACKUP}"; fi
echo "備份：${BACKUP}"

if (( SEL_SECURITY )); then
    echo "[3/8] 套用 SMB 安全設定..."
    python3 - "${SMB_CONF}" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
lines = text.splitlines(keepends=True)
settings = [
    ("security", "user"),
    ("server role", "standalone server"),

    ("map to guest", "Never"),
    ("restrict anonymous", "2"),
    ("usershare allow guests", "No"),
    ("usershare max shares", "0"),

    ("ntlm auth", "ntlmv2-only"),
    ("lanman auth", "No"),

    # SMB password and Linux/PAM password remain independent.
    ("unix password sync", "No"),
    ("pam password change", "No"),

    ("server min protocol", "SMB3_11"),
    ("server max protocol", "SMB3"),
    ("server signing", "mandatory"),
    ("server smb encrypt", "required"),

    ("disable netbios", "Yes"),
    ("smb ports", "445"),

    ("load printers", "No"),
    ("disable spoolss", "Yes"),
    ("printcap name", "/dev/null"),
]
managed = {k.casefold() for k, _ in settings}
section_re = re.compile(r"^\s*\[([^\]]+)\]\s*$")
key_re = re.compile(r"^\s*([^#;][^=]*?)\s*=")
start = end = None
for i, line in enumerate(lines):
    m = section_re.match(line.rstrip("\r\n"))
    if m and m.group(1).strip().casefold() == "global":
        start = i
        end = len(lines)
        for j in range(i + 1, len(lines)):
            if section_re.match(lines[j].rstrip("\r\n")):
                end = j
                break
        break
block = ["\n", "    # Managed by deploy-samba-selective-v1.sh\n"] + [f"    {k} = {v}\n" for k, v in settings]
if start is None:
    lines = ["[global]\n"] + block + ["\n"] + lines
else:
    body = []
    for line in lines[start + 1:end]:
        m = key_re.match(line.rstrip("\r\n"))
        if m and m.group(1).strip().casefold() in managed:
            continue
        if "Managed by deploy-samba-selective-v1.sh" in line:
            continue
        body.append(line)
    while body and not body[-1].strip():
        body.pop()
    replacement = [lines[start]] + body + block + ["\n"]
    lines = lines[:start] + replacement + lines[end:]

# Security mode removes Samba's default printing shares entirely.
# Other existing shares are preserved.
remove_sections = {"printers", "print$"}
result = []
i = 0
while i < len(lines):
    m = section_re.match(lines[i].rstrip("\r\n"))
    if m and m.group(1).strip().casefold() in remove_sections:
        i += 1
        while i < len(lines):
            if section_re.match(lines[i].rstrip("\r\n")):
                break
            i += 1
        # Trim blank lines left behind by the removed section.
        while result and not result[-1].strip():
            result.pop()
        result.append("\n")
        continue
    result.append(lines[i])
    i += 1

path.write_text("".join(result), encoding="utf-8")
PY
else
    echo "[3/8] SMB 安全設定：略過"
fi

if (( SEL_SHARE )); then
    echo "[4/8] 套用 Share 設定..."
    python3 - "${SMB_CONF}" "${SHARE_NAME}" "${SHARE_PATH}" "${TARGET_USER}" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1]); share_name = sys.argv[2]; share_path = sys.argv[3]; target_user = sys.argv[4]
text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
lines = text.splitlines(keepends=True)
section_re = re.compile(r"^\s*\[([^\]]+)\]\s*$")
start = end = None
for i, line in enumerate(lines):
    m = section_re.match(line.rstrip("\r\n"))
    if m and m.group(1).strip().casefold() == share_name.casefold():
        start = i; end = len(lines)
        for j in range(i + 1, len(lines)):
            if section_re.match(lines[j].rstrip("\r\n")):
                end = j; break
        break
if start is not None:
    lines = lines[:start] + lines[end:]
while lines and not lines[-1].strip(): lines.pop()
share = [
    "\n\n", f"[{share_name}]\n", f"    path = {share_path}\n",
    "    browseable = Yes\n", "    read only = No\n", "    guest ok = No\n",
    f"    force user = {target_user}\n", "    hide dot files = No\n",
    "    inherit permissions = Yes\n", "    wide links = No\n",
    "    server smb encrypt = required\n",
]
lines.extend(share)
path.write_text("".join(lines), encoding="utf-8")
PY
else
    echo "[4/8] Share 設定：略過"
fi

echo "[5/8] 驗證 smb.conf..."
if ! testparm -s "${SMB_CONF}" >/dev/null 2>&1; then
    echo "錯誤：Samba 設定驗證失敗，正在還原 ${BACKUP} ..."
    cp -a "${BACKUP}" "${SMB_CONF}"
    systemctl restart smbd 2>/dev/null || true
    unset SMB_PASSWORD
    exit 1
fi
echo "smb.conf 驗證成功。"

if (( SEL_PASSWORD )); then
    echo "[6/8] 建立 / 重設 Samba 使用者密碼..."
    printf '%s\n%s\n' "${SMB_PASSWORD}" "${SMB_PASSWORD}" | smbpasswd -s -a "${TARGET_USER}"
    smbpasswd -e "${TARGET_USER}" >/dev/null 2>&1 || true
    unset SMB_PASSWORD
    if ! pdbedit -L | cut -d: -f1 | grep -Fxq "${TARGET_USER}"; then
        echo "錯誤：Samba 使用者 '${TARGET_USER}' 建立失敗。"
        exit 1
    fi
else
    echo "[6/8] Samba 密碼：保留原設定"
fi

if (( SEL_SERVICE )); then
    echo "[7/8] 套用 Samba / NetBIOS 服務設定..."
    systemctl disable --now nmbd >/dev/null 2>&1 || true
    systemctl enable --now smbd
    systemctl restart smbd
else
    echo "[7/8] Samba / NetBIOS 服務設定：略過"
    if (( SEL_SECURITY || SEL_SHARE )); then systemctl restart smbd; fi
fi

if (( SEL_FIREWALL )); then
    echo "[8/8] 套用 UFW 防火牆設定..."
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw delete allow Samba >/dev/null 2>&1 || true
        if [[ -n "${SMB_ALLOWED_CIDR}" ]]; then
            ufw allow from "${SMB_ALLOWED_CIDR}" to any port 445 proto tcp >/dev/null
            echo "UFW：允許 ${SMB_ALLOWED_CIDR} -> TCP/445"
        else
            echo "警告：UFW 已啟用，但無法自動偵測 LAN CIDR；沒有自動新增 TCP/445 規則。"
        fi
    else
        echo "UFW 未啟用；不會自動啟用，以免影響 SSH / 其他服務。"
    fi
else
    echo "[8/8] UFW 防火牆設定：略過"
fi

VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "================================================================"
echo "完成"
echo "Linux 使用者：${TARGET_USER}"
echo "分享路徑    ：${SHARE_PATH}"
echo "SMB Share   ：${SHARE_NAME}"
if [[ -n "${VM_IP}" ]]; then echo "Windows UNC ：\\\\${VM_IP}\\${SHARE_NAME}"; else echo "Windows UNC ：\\\\<VM-IP>\\${SHARE_NAME}"; fi
echo
echo "本次套用："
printf "  %s SMB 安全設定\n" "$(mark "${SEL_SECURITY}")"
printf "  %s Share 設定\n" "$(mark "${SEL_SHARE}")"
printf "  %s Samba 密碼\n" "$(mark "${SEL_PASSWORD}")"
printf "  %s Samba / NetBIOS 服務設定\n" "$(mark "${SEL_SERVICE}")"
printf "  %s UFW 防火牆設定\n" "$(mark "${SEL_FIREWALL}")"
echo
echo "設定備份：${BACKUP}"
echo
echo "目前 Samba 使用者："
pdbedit -L 2>/dev/null || true
echo
echo "目前 Share："
testparm -s 2>/dev/null | grep '^\[' || true
echo
echo "TCP/445："
ss -ltnp 2>/dev/null | grep ':445' || true
echo "================================================================"
echo "不要把 TCP/445 直接 Port Forward 到公網。"
