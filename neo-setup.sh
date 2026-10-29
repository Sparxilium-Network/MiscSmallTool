#!/usr/bin/env bash
# OpenSK neo-setup（獨立版）：自動 git clone、修補 nrfdfu、勾選選單設定並燒錄。
#
# 所有檔案都放在本腳本所在目錄：
#   ./opensk/   OpenSK（develop 分支）與其 submodule、編譯產物、crypto_data 金鑰
#   ./.neo/     Rust 工具鏈、cargo/uv 快取、Python、修正版 nrfdfu 原始碼、暫存檔
# 唯一例外是需要 sudo 的系統設定（apt 套件、dialout 群組），腳本只會印出指令，不會自己執行。
#
# 操作：↑/↓ 或 k/j 移動，空白鍵 勾選，Enter 確認，q 離開。

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSK_DIR="$BASE_DIR/opensk"
LOCAL_DIR="$BASE_DIR/.neo"
FIX_DIR="$LOCAL_DIR/nrfdfu-fix"
CARGO_ROOT="$OPENSK_DIR/third_party/wasefire/.root"
OPENSK_REPO="https://github.com/google/OpenSK.git"
OPENSK_BRANCH="develop"
NRFDFU_VERSION="0.2.1"
NRFDFU_SHA256="5bcfb2cc6f9c10f3c55a9c7e8e8c634152b0daed536f77091d7d9af44d8dcd45"
NRFDFU_MARKER="$CARGO_ROOT/.neo-nrfdfu-patched"
OPENSK_USB_ID="18d1:0239"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m錯誤:\033[0m %s\n' "$*" >&2; exit 1; }

ask_yn() { # ask_yn <問題> <預設 y|n>
  local ans hint="[y/N]"
  [ "$2" = y ] && hint="[Y/n]"
  read -r -p "$1 $hint " ans
  ans="${ans:-$2}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

pause() { read -r -p "$1（按 Enter 繼續）" _; }

# ---------- 環境：所有寫入都導向本目錄 ----------

# use_local_env <1=工具鏈也放本目錄 | 0=沿用 ~/.cargo ~/.rustup>
use_local_env() {
  mkdir -p "$LOCAL_DIR"/{bin,tmp,cache,data,state}
  export TMPDIR="$LOCAL_DIR/tmp"
  export XDG_CACHE_HOME="$LOCAL_DIR/cache"
  export XDG_DATA_HOME="$LOCAL_DIR/data"
  export XDG_STATE_HOME="$LOCAL_DIR/state"
  export UV_CACHE_DIR="$LOCAL_DIR/cache/uv"
  export UV_PYTHON_INSTALL_DIR="$LOCAL_DIR/data/uv-python"
  export UV_TOOL_DIR="$LOCAL_DIR/data/uv-tools"
  export PIP_CACHE_DIR="$LOCAL_DIR/cache/pip"
  unset RUSTUP_TOOLCHAIN
  if [ "$1" = 1 ]; then
    export RUSTUP_HOME="$LOCAL_DIR/rustup"
    export CARGO_HOME="$LOCAL_DIR/cargo"
  else
    export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
  fi
  export PATH="$LOCAL_DIR/bin:$CARGO_HOME/bin:$PATH"
}

# 需要 sudo 才能裝的系統套件：只檢查並印出指令。
check_system_deps() {
  local missing=()
  command -v git >/dev/null || missing+=(git)
  command -v curl >/dev/null || missing+=(curl)
  command -v cc >/dev/null || missing+=(build-essential)
  command -v pkg-config >/dev/null || missing+=(pkgconf)
  command -v uuidgen >/dev/null || missing+=(uuid-runtime)
  command -v lsusb >/dev/null || missing+=(usbutils)
  if command -v pkg-config >/dev/null; then
    pkg-config --exists libudev || missing+=(libudev-dev)
    pkg-config --exists openssl || missing+=(libssl-dev)
  else
    missing+=(libudev-dev libssl-dev)
  fi
  [ "${#missing[@]}" = 0 ] && return
  die "缺少系統套件，請先執行：sudo apt install ${missing[*]}"
}

# /usr/local/bin/openssl 若壞掉（例如找不到 libssl.so），改用 /usr/bin/openssl。
fix_openssl() {
  if ! openssl version >/dev/null 2>&1; then
    /usr/bin/openssl version >/dev/null 2>&1 || die "openssl 無法執行，/usr/bin/openssl 也不可用。"
    ln -sf /usr/bin/openssl "$LOCAL_DIR/bin/openssl"
    hash -r
    warn "預設 openssl 無法執行，改用 /usr/bin/openssl。"
  fi
  export OPENSSL="$(command -v openssl)"
}

ensure_rust() {
  if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
    [ "$CARGO_HOME" = "$LOCAL_DIR/cargo" ] \
      || die "找不到 $CARGO_HOME/bin/rustup。請安裝 rustup，或勾選「工具鏈也放在本目錄」。"
    info "安裝 rustup 到 $CARGO_HOME（不修改 ~/.bashrc）..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$TMPDIR/rustup-init.sh"
    sh "$TMPDIR/rustup-init.sh" -y --no-modify-path --default-toolchain=none --profile=minimal
  fi
  info "安裝 OpenSK / wasefire 指定的 Rust 工具鏈（第一次會下載數 GB）..."
  (cd "$OPENSK_DIR/third_party/wasefire" && rustup toolchain install)
  (cd "$OPENSK_DIR" && rustup toolchain install)
  rustup toolchain install stable --profile=minimal
}

ensure_uv() {
  command -v uv >/dev/null && return
  info "安裝 uv 到 $LOCAL_DIR/bin..."
  curl -LsSf https://astral.sh/uv/install.sh -o "$TMPDIR/uv-install.sh"
  UV_INSTALL_DIR="$LOCAL_DIR/bin" UV_NO_MODIFY_PATH=1 sh "$TMPDIR/uv-install.sh"
}

check_dialout() {
  id -nG | grep -w dialout >/dev/null && return
  if getent group dialout | grep -w "$USER" >/dev/null; then
    die "你已在 dialout 群組，但目前的 shell 尚未生效。請重新登入，或先執行：newgrp dialout"
  fi
  die "燒錄需要存取 /dev/ttyACM*，請先執行：sudo usermod -aG dialout $USER，再重新登入。"
}

check_modemmanager() {
  if systemctl is-active --quiet ModemManager 2>/dev/null; then
    warn "ModemManager 正在執行，可能干擾 DFU 燒錄。可先執行：sudo systemctl stop ModemManager"
    ask_yn "仍要繼續？" n || exit 1
  fi
}

# ---------- 取得並初始化 OpenSK ----------

clone_opensk() {
  if [ -d "$OPENSK_DIR/.git" ]; then
    info "沿用已存在的 $OPENSK_DIR"
  else
    info "git clone OpenSK（$OPENSK_BRANCH 分支）到 $OPENSK_DIR..."
    git clone --branch "$OPENSK_BRANCH" "$OPENSK_REPO" "$OPENSK_DIR"
  fi
  git -C "$OPENSK_DIR" submodule update --init
}

# 等同 setup.sh，但不呼叫 sudo，也不安裝用不到的 cargo-audit。
init_crypto_data() {
  info "產生 crypto_data（PKI 與 batch 憑證，已存在則保留）..."
  (
    cd "$OPENSK_DIR"
    set +u
    # shellcheck source=/dev/null
    source tools/gen_key_materials.sh
    generate_pki N
    if [ ! -f crypto_data/opensk.key ] || [ ! -f crypto_data/opensk_cert.pem ]; then
      generate_new_batch
    fi
  )
}

# ---------- nrfdfu 修正（逾時 1s -> 30s、sd_req=0x00） ----------

fetch_nrfdfu_source() {
  local crate="$TMPDIR/nrfdfu-$NRFDFU_VERSION.crate"
  info "下載 nrfdfu $NRFDFU_VERSION 原始碼..."
  curl -fsSL -o "$crate" "https://static.crates.io/crates/nrfdfu/nrfdfu-$NRFDFU_VERSION.crate"
  echo "$NRFDFU_SHA256  $crate" | sha256sum -c --quiet - || die "nrfdfu 原始碼 checksum 不符。"
  rm -rf "$FIX_DIR"
  mkdir -p "$FIX_DIR"
  tar -xzf "$crate" -C "$FIX_DIR" --strip-components=1
  rm -f "$crate"
}

patch_nrfdfu_source() {
  local main="$FIX_DIR/src/main.rs" init="$FIX_DIR/src/init_packet.rs"
  # 串列埠逾時 1 秒 -> 30 秒（修正 Operation timed out）
  sed -i 's/\.timeout(Duration::from_millis(1000))/.timeout(Duration::from_millis(30000))/' "$main"
  grep 'from_millis(30000)' "$main" >/dev/null || die "套用逾時修正失敗。"
  # init packet 加上 sd_req=0x00（修正 firmware requires unavailable SoftDevice version）
  if ! grep '"sd_req", 3' "$init" >/dev/null; then
    sed -i '/writer.write_field("hw_version", 2, &self.hw_version);/a\        // sd_req 0x00: the application may overwrite the SoftDevice (also accepted without one).\n        writer.write_field("sd_req", 3, \&0u32);' "$init"
    sed -i 's/\[a, 38, 8, 1, 12, 34, 8, 0, 10, 34, 20, 0,/[a, 3a, 8, 1, 12, 36, 8, 0, 10, 34, 18, 0, 20, 0,/' "$init"
  fi
  grep '"sd_req", 3' "$init" >/dev/null || die "套用 sd_req 修正失敗。"
}

install_patched_nrfdfu() {
  info "編譯並安裝修正版 nrfdfu 到 $CARGO_ROOT..."
  (cd "$FIX_DIR" && cargo +stable install --locked --force --path . --root "$CARGO_ROOT")
  # wasefire 的 wrapper.sh 只認 crates.io 版本的安裝紀錄，否則會重裝原版。
  sed -i "s#path+file://$FIX_DIR#registry+https://github.com/rust-lang/crates.io-index#" \
    "$CARGO_ROOT/.crates.toml" "$CARGO_ROOT/.crates2.json"
  cargo install --list --root="$CARGO_ROOT" | grep "^nrfdfu v$NRFDFU_VERSION:\$" >/dev/null \
    || die "nrfdfu 安裝紀錄修改失敗。"
  touch "$NRFDFU_MARKER"
}

apply_nrfdfu_fix() {
  if [ -f "$NRFDFU_MARKER" ]; then
    info "修正版 nrfdfu 已安裝，略過。"
    return
  fi
  fetch_nrfdfu_source
  patch_nrfdfu_source
  install_patched_nrfdfu
}

# ---------- 自訂 AAGUID ----------

choose_aaguid() {
  local current input
  current="$(tr -d '[:space:]' < "$OPENSK_DIR/crypto_data/aaguid.txt")"
  echo "目前 AAGUID：$current"
  read -r -p "輸入新的 AAGUID（Enter 保留目前值，r 隨機產生）：" input
  case "$input" in
    "") return ;;
    r|R) input="$(uuidgen)" ;;
  esac
  input="$(echo "$input" | tr 'A-F' 'a-f')"
  [[ "$input" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || die "AAGUID 格式錯誤，需為 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx。"
  [ "$input" = "$current" ] && return
  echo "$input" > "$OPENSK_DIR/crypto_data/aaguid.txt"
  info "AAGUID 改為 $input，產生新的 batch 憑證..."
  (
    cd "$OPENSK_DIR"
    set +u
    # shellcheck source=/dev/null
    source tools/gen_key_materials.sh
    generate_new_batch N
  )
}

wait_for_opensk() {
  info "請拔掉 dongle 再插上，不要按任何按鈕..."
  local i
  for i in $(seq 1 120); do
    lsusb | grep "$OPENSK_USB_ID" >/dev/null && { sleep 2; info "偵測到 OpenSK。"; return; }
    sleep 1
  done
  die "120 秒內沒有偵測到 OpenSK（$OPENSK_USB_ID）。"
}

inject_attestation() {
  ensure_uv
  info "注入 attestation 憑證與 AAGUID，出現提示時請按 dongle 上的按鈕。"
  (
    cd "$OPENSK_DIR"
    uv run tools/configure.py \
      --certificate=crypto_data/opensk_cert.pem \
      --private-key=crypto_data/opensk.key \
      --aaguid=crypto_data/aaguid.txt
  )
}

# ---------- 選單元件 ----------

restore_cursor() { tput cnorm 2>/dev/null || true; }

# read_key：把按鍵轉成 up / down / space / enter / quit / other
read_key() {
  local k rest
  IFS= read -rsn1 k
  case "$k" in
    $'\x1b')
      IFS= read -rsn2 -t 0.05 rest || true
      case "$rest" in
        "[A") echo up ;;
        "[B") echo down ;;
        *) echo other ;;
      esac ;;
    k) echo up ;;
    j) echo down ;;
    " ") echo space ;;
    "") echo enter ;;
    q|Q) echo quit ;;
    *) echo other ;;
  esac
}

# checklist <標題> <標籤陣列名> <狀態陣列名> <鎖定原因陣列名>
#   狀態：1 = [*]、0 = [ ]；鎖定原因非空時不可切換，顯示 [*]（強制啟用）或 [-]（不可用）。
#   RADIO=1 時為單選，顯示 (*) / ( )。
checklist() {
  local title="$1" radio="${RADIO:-0}"
  local -n labels="$2" states="$3" reasons="$4"
  local cursor=0 n=${#labels[@]} i mark key
  tput civis 2>/dev/null || true
  while true; do
    clear
    printf '\033[1m%s\033[0m\n' "$title"
    if [ "$radio" = 1 ]; then
      echo "↑/↓ 移動  空白鍵 選擇  Enter 確認  q 離開"
    else
      echo "↑/↓ 移動  空白鍵 勾選/取消  Enter 確認  q 離開"
    fi
    echo
    for ((i = 0; i < n; i++)); do
      if [ "$radio" = 1 ]; then
        [ "${states[i]}" = 1 ] && mark="(*)" || mark="( )"
      elif [ -n "${reasons[i]}" ]; then
        [ "${states[i]}" = 1 ] && mark="[*]" || mark="[-]"
      else
        [ "${states[i]}" = 1 ] && mark="[*]" || mark="[ ]"
      fi
      if [ "$i" = "$cursor" ]; then
        printf '\033[7m> %s %s\033[0m' "$mark" "${labels[i]}"
      else
        printf '  %s %s' "$mark" "${labels[i]}"
      fi
      [ -n "${reasons[i]}" ] && printf '  \033[2m(%s)\033[0m' "${reasons[i]}"
      echo
    done
    key="$(read_key)"
    case "$key" in
      up) cursor=$(((cursor - 1 + n) % n)) ;;
      down) cursor=$(((cursor + 1) % n)) ;;
      space)
        [ -n "${reasons[cursor]}" ] && continue
        if [ "$radio" = 1 ]; then
          for ((i = 0; i < n; i++)); do states[i]=0; done
          states[cursor]=1
        else
          states[cursor]=$((1 - states[cursor]))
        fi ;;
      enter) break ;;
      quit) clear; restore_cursor; echo "已取消。"; exit 1 ;;
    esac
  done
  restore_cursor
  clear
}

# ---------- 選項定義 ----------

TARGETS=(nrf52840_dongle nrf52840dk nrf52840_mdk opentitan host)
TARGET_LABELS=(
  "nrf52840_dongle   Nordic nRF52840 Dongle"
  "nrf52840dk        Nordic nRF52840 DK"
  "nrf52840_mdk      Makerdiary nRF52840 MDK"
  "opentitan         OpenTitan"
  "host              本機模擬裝置"
)
TARGET_STATES=(1 0 0 0 0)
TARGET_REASONS=("" "" "" "" "")

OPT_FIX=0 OPT_UPDATE=1 OPT_AAGUID=2 OPT_LOCAL_TOOLS=3 OPT_RECLONE=4
OPTION_LABELS=(
  "套用 nrfdfu 修正（逾時 1s→30s、允許覆蓋 SoftDevice）"
  "保留 dongle 內已註冊的憑證（--update）"
  "自訂 AAGUID 並注入 attestation 憑證"
  "Rust / uv 工具鏈也放在本目錄（第一次約下載 4 GB）"
  "刪除 ./opensk 重新 clone（會遺失 crypto_data 金鑰）"
)
OPTION_STATES=(1 0 0 1 0)
OPTION_REASONS=("" "" "" "" "")

FEATURES_ALL=(ctap1 config-command debug led-1 ed25519 fingerprint)
FEATURE_LABELS=(
  "ctap1            支援 U2F（CTAP1）"
  "config-command   authenticatorConfig 指令"
  "debug            輸出除錯訊息"
  "led-1            單顆 LED 閃爍模式"
  "ed25519          Ed25519 簽章演算法"
  "fingerprint      指紋（需感測器）"
)
FEATURE_STATES=(1 1 0 0 0 0)

# 依 target 鎖定 feature（flash.sh 不會傳入平台層的 ed25519 / fingerprint）。
feature_reasons_for() {
  FEATURE_REASONS=("" "" "" "" "" "")
  if [ "$1" = nrf52840_mdk ]; then
    FEATURE_REASONS[3]="MDK 必須啟用"
    FEATURE_STATES[3]=1
  fi
  if [ "$1" != host ]; then
    FEATURE_REASONS[4]="僅 host 支援"
    FEATURE_STATES[4]=0
  fi
  FEATURE_REASONS[5]="flash.sh 不支援"
  FEATURE_STATES[5]=0
  return 0
}

# ---------- 主流程 ----------

main() {
  [ -t 0 ] && [ -t 1 ] || die "neo-setup 需要在互動式終端機中執行。"
  trap restore_cursor EXIT

  local i TARGET="" SELECTED=() FEATURES
  RADIO=1 checklist "neo-setup 1/3：選擇燒錄目標" TARGET_LABELS TARGET_STATES TARGET_REASONS
  for i in "${!TARGETS[@]}"; do
    [ "${TARGET_STATES[i]}" = 1 ] && TARGET="${TARGETS[i]}"
  done

  # nrfdfu 只用在 nrf52840_dongle 的燒錄。
  if [ "$TARGET" != nrf52840_dongle ]; then
    OPTION_REASONS[OPT_FIX]="僅 nrf52840_dongle 需要"
    OPTION_STATES[OPT_FIX]=0
  fi
  if [ ! -d "$OPENSK_DIR/.git" ]; then
    OPTION_REASONS[OPT_RECLONE]="尚未 clone"
    OPTION_STATES[OPT_RECLONE]=0
  fi
  checklist "neo-setup 2/3：流程選項（目標：$TARGET）" OPTION_LABELS OPTION_STATES OPTION_REASONS

  feature_reasons_for "$TARGET"
  checklist "neo-setup 3/3：韌體功能（目標：$TARGET）" FEATURE_LABELS FEATURE_STATES FEATURE_REASONS

  for i in "${!FEATURES_ALL[@]}"; do
    [ "${FEATURE_STATES[i]}" = 1 ] && SELECTED+=("${FEATURES_ALL[i]}")
  done
  [ "${#SELECTED[@]}" -gt 0 ] || die "至少要選一個韌體功能。"
  FEATURES="$(IFS=,; echo "${SELECTED[*]}")"

  local FLASH_ARGS=(--features="$FEATURES")
  [ "${OPTION_STATES[OPT_UPDATE]}" = 1 ] && FLASH_ARGS+=(--update)

  yesno() { [ "$1" = 1 ] && echo 是 || echo 否; }
  echo "設定摘要："
  echo "  安裝目錄       $BASE_DIR"
  echo "  燒錄目標       $TARGET"
  echo "  韌體功能       $FEATURES"
  echo "  nrfdfu 修正    $(yesno "${OPTION_STATES[OPT_FIX]}")"
  echo "  --update       $(yesno "${OPTION_STATES[OPT_UPDATE]}")"
  echo "  自訂 AAGUID    $(yesno "${OPTION_STATES[OPT_AAGUID]}")"
  echo "  工具鏈在本目錄 $(yesno "${OPTION_STATES[OPT_LOCAL_TOOLS]}")"
  echo "  重新 clone     $(yesno "${OPTION_STATES[OPT_RECLONE]}")"
  echo
  ask_yn "開始執行？" y || { echo "已取消。"; exit 1; }

  use_local_env "${OPTION_STATES[OPT_LOCAL_TOOLS]}"
  check_system_deps
  fix_openssl

  if [ "${OPTION_STATES[OPT_RECLONE]}" = 1 ]; then
    ask_yn "確定刪除 $OPENSK_DIR（含 crypto_data 金鑰）？" n || exit 1
    rm -rf "$OPENSK_DIR"
  fi
  clone_opensk
  ensure_rust
  init_crypto_data

  [ "${OPTION_STATES[OPT_FIX]}" = 1 ] && apply_nrfdfu_fix

  if [ "${OPTION_STATES[OPT_AAGUID]}" = 1 ]; then
    warn "attestation 只能寫入一次；dongle 已寫過不同憑證時會失敗，需不加 --update 重新燒錄。"
    warn "自訂憑證只有你在用，網站可藉此關聯你的註冊（隱私風險）。"
    choose_aaguid
  fi

  if [ "$TARGET" != host ]; then
    check_dialout
    check_modemmanager
    pause "請讓裝置進入 DFU / 燒錄模式（dongle：按側邊 reset 鍵，紅燈慢閃）"
  fi

  info "執行 ./flash.sh ${FLASH_ARGS[*]} $TARGET"
  (cd "$OPENSK_DIR" && ./flash.sh "${FLASH_ARGS[@]}" "$TARGET")
  info "燒錄完成。"

  if [ "${OPTION_STATES[OPT_AAGUID]}" = 1 ]; then
    [ "$TARGET" != host ] && wait_for_opensk
    inject_attestation
  fi

  info "全部完成。所有檔案都在 $BASE_DIR"
}

# 直接執行時跑主流程；被 source 時只提供函式（方便測試）。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
