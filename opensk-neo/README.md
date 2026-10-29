# opensk-neo

這個資料夾目前的兩個專案檔案：

| 檔案 | 說明 |
|---|---|
| [`opensk-setup.sh`](./opensk-setup.sh) | OpenSK 互動式安裝、設定與燒錄腳本。 |
| `README.md` | 本文件，說明腳本用途、操作方式、產生的目錄與注意事項。 |

`opensk-setup.sh` 是一支獨立的 OpenSK 安裝與燒錄腳本，用勾選選單操作。執行時它會自行 clone [google/OpenSK](https://github.com/google/OpenSK) 的 develop 分支、修補燒錄工具 nrfdfu，再燒錄到裝置上。所有產生的檔案都放在這個目錄裡。

```bash
./opensk-setup.sh
```

操作方式：↑/↓（或 k/j）移動，空白鍵勾選，Enter 確認，q 離開。

## 目錄結構

```
opensk-neo/
├── opensk-setup.sh     腳本本體（單一檔案，不依賴其他腳本）
├── README.md
├── opensk/          自動 clone 的 OpenSK（develop）＋ wasefire submodule
│   ├── crypto_data/ attestation 金鑰、憑證、AAGUID（不在 git 裡，刪掉就沒了）
│   └── third_party/wasefire/.root/bin/nrfdfu   修正版 nrfdfu
└── .neo/            腳本產生的所有其他東西
    ├── rustup/  cargo/      Rust 工具鏈與 crate 快取（RUSTUP_HOME / CARGO_HOME）
    ├── bin/                 uv、openssl 替身
    ├── cache/ data/ state/  uv 快取、uv 下載的 Python（XDG_* / UV_*）
    ├── nrfdfu-fix/          修補後的 nrfdfu 0.2.1 原始碼
    └── tmp/                 暫存檔（TMPDIR）
```

要整個移除，直接刪掉 `opensk-neo/` 這個資料夾就好。

## 做了什麼

### 1. 把檔案限制在本目錄

腳本會把下面這些環境變數全部指向 `.neo/`：`RUSTUP_HOME`、`CARGO_HOME`、`TMPDIR`、`XDG_CACHE_HOME`、`XDG_DATA_HOME`、`XDG_STATE_HOME`、`UV_CACHE_DIR`、`UV_PYTHON_INSTALL_DIR`、`UV_TOOL_DIR`、`PIP_CACHE_DIR`。

- 安裝 rustup 時加 `--no-modify-path`，安裝 uv 時設 `UV_NO_MODIFY_PATH=1`，所以不會改到 `~/.bashrc` 或 `~/.profile`。
- 需要 sudo 的系統層設定，腳本不會自己執行，只會印出指令後停下：
  - apt 套件：git、curl、build-essential、pkgconf、libudev-dev、libssl-dev、uuid-runtime、usbutils
  - 把使用者加進 dialout 群組
  - 停止 ModemManager
- 在流程選項取消勾選「工具鏈也放在本目錄」，就改用現有的 `~/.cargo` 和 `~/.rustup`，可以省下約 4 GB 的下載。不過這樣 crate 快取會寫到家目錄。

### 2. 取得並初始化 OpenSK（取代 `setup.sh`）

- `git clone --branch develop`，接著 `git submodule update --init`。如果 `opensk/` 已經存在就沿用。
- 安裝 OpenSK 和 wasefire 的 `rust-toolchain.toml` 指定的工具鏈（nightly-2026-06-03 以及它的 targets/components），再加上 stable。
- 呼叫 `tools/gen_key_materials.sh` 產生 PKI、batch 憑證和 AAGUID。已經存在的會保留。
- 原本的 `setup.sh` 可能會呼叫 `sudo apt-get`，也會安裝用不到的 cargo-audit，這兩件事都略過。
- 如果 `/usr/local/bin/openssl` 壞掉（找不到 libssl.so），會在 `.neo/bin` 放一個指向 `/usr/bin/openssl` 的替身。

### 3. 修補 nrfdfu（nRF52840 Dongle 用）

腳本從 crates.io 下載 nrfdfu 0.2.1，驗證 sha256 後解壓到 `.neo/nrfdfu-fix/`，套用兩個修正，再安裝到 `opensk/third_party/wasefire/.root`：

| 檔案 | 修改 | 修正的錯誤 |
|---|---|---|
| `src/main.rs` | 串列埠逾時 `1000` → `30000` ms | `Operation timed out` |
| `src/init_packet.rs` | init packet 加入 `sd_req = 0x00` | `firmware requires unavailable SoftDevice version`（dongle 上還有 SoftDevice 時） |

- 安裝完之後，會把 `.root/.crates.toml` 和 `.crates2.json` 裡的來源改成 crates.io。不改的話，wasefire 的 `wrapper.sh` 會判定版本不符，自動裝回原版。
- 完成後會留下標記檔 `.root/.neo-nrfdfu-patched`，下次執行就略過這一步。

### 4. 三個選單

1. **燒錄目標**（單選）：nrf52840_dongle（預設）、nrf52840dk、nrf52840_mdk、opentitan、host
2. **流程選項**
   - `[*]` 套用 nrfdfu 修正：只在 nrf52840_dongle 時可以選
   - `[ ]` `--update`：保留已註冊的憑證
   - `[ ]` 自訂 AAGUID 並注入 attestation 憑證
   - `[*]` Rust / uv 工具鏈也放在本目錄
   - `[ ]` 刪除 `./opensk` 重新 clone：會遺失 crypto_data，執行前會再問一次；還沒 clone 時不能選
3. **韌體功能**（傳給 `flash.sh --features=`）
   - `[*]` ctap1、`[*]` config-command、`[ ]` debug
   - `[ ]` led-1：給只有單顆 LED 的板子用；選 MDK 時強制為 `[*]`
   - `[-]` ed25519：只有 host 能選
   - `[-]` fingerprint：`flash.sh` 不會傳平台層需要的 feature，所以不能選

`[-]` 和強制的 `[*]` 都是鎖定狀態，按空白鍵不會變。選完會先顯示設定摘要，確認之後才開始執行。

### 5. 執行流程

1. 檢查系統套件和 openssl
2. clone OpenSK，安裝工具鏈，產生金鑰
3. 套用 nrfdfu 修正（如果有勾選）
4. 自訂 AAGUID（如果有勾選）：可以輸入 UUID、按 r 隨機產生，或按 Enter 保留目前的值；改了就重新產生 batch 憑證
5. 檢查 dialout 和 ModemManager，提示讓裝置進入 DFU 模式（dongle 要按側邊的 reset 鍵）
6. `./flash.sh --features=... [--update] <target>`
7. 注入（如果有勾選）：等待 `18d1:0239` 出現，用 `uv run tools/configure.py` 寫入憑證、私鑰和 AAGUID，過程中要按裝置上的按鈕

## 已驗證

- 選單：在虛擬終端機操作過 dongle、host、MDK 三種目標。鎖定項目無法切換，摘要內容正確。
- clone、工具鏈安裝、金鑰產生、nrfdfu 修補與安裝：在本目錄實際跑過，都成功。
- 發現 stable 工具鏈曾被中斷成半套（`missing manifest`），已加上自動偵測並重裝。
- 最後一次執行時確認過：crate 下載寫到 `.neo/cargo/registry`，`~/.cargo` 和 `~/.rustup` 都沒有變動。
- 2026-10-29 實機測試：用 opensk-setup.sh 安裝並燒錄成功，裝置可正常使用。

## 尚未驗證 / 注意事項

- 「自訂 AAGUID 並注入 attestation」這個選項還沒有單獨確認過結果。
- 如果你在一般 shell 裡直接執行 `opensk/flash.sh`，而不是透過 opensk-setup.sh，就不會套用這些環境變數，cargo 會用 `~/.cargo`。
- attestation 只能寫入一次。dongle 已經寫過不同的憑證時注入會失敗，要先不加 `--update` 重新燒錄。
- 自訂 AAGUID 和憑證不在 FIDO MDS 裡，網站還是不會認得這把金鑰的型號；而且這組憑證只有你在用，網站可以藉此把你的各個註冊關聯起來。
- hmac-secret（WebAuthn PRF）一律啟用，沒有開關。
