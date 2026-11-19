# Samba 部署工具

授權：MIT，詳見 [LICENSE](./LICENSE)。

這個目錄有兩支腳本，都會在 Debian / Ubuntu 主機上安裝 Samba，把一個目錄分享成 SMB share，並套用偏嚴格的 SMB 安全設定：

| 腳本 | 分享路徑 | Share 名稱 |
| --- | --- | --- |
| [`deploy-samba-selective-v1.sh`](./deploy-samba-selective-v1.sh)（新） | 預設為使用者的 Home，可自行輸入其他路徑，例如 `/opt` | 預設自動帶出，可自行修改 |
| [`deploy-samba-home-selective-v3.sh`](./deploy-samba-home-selective-v3.sh)（舊） | 固定為使用者的 Home | 固定為 `<使用者>-home` |

**兩支腳本互不相容**，同一台主機請只用其中一支，見[兩支腳本不相容](#兩支腳本不相容)。

> **警告：這兩支腳本都只建議用於 Codex / Claude 等 AI agent 的沙箱環境**，目的是讓使用者可以直接從 Windows 讀取、操作 agent 沙箱內的檔案。請勿用在一般工作機、正式環境或存有重要資料與金鑰的主機上。
>
> 不要把 TCP/445 直接 Port Forward 到公網。

## 使用方式

在 Linux 的互動式終端機中，以 Share 要使用的那位使用者身分透過 sudo 執行：

```sh
sudo bash deploy-samba-selective-v1.sh
```

```sh
sudo bash deploy-samba-home-selective-v3.sh
```

- 使用者預設為 `SUDO_USER`；若取不到（或是 root），會改用 `logname`，再不行就要求輸入使用者名稱。
- 執行前會列出即將套用的項目，必須輸入 `YES` 才會修改系統。
- 完成後會顯示 Windows 連線路徑，例如 `\\192.168.1.10\paul-home`。

### v1：選擇分享路徑與 Share 名稱

v1 一開始會先詢問分享路徑與 Share 名稱，直接按 Enter 使用方括號中的預設值：

```text
要分享的路徑 [/home/paul]: /opt
Share 名稱 [opt]:
```

- **分享路徑**：預設為使用者的 Home。必須是已存在的目錄，且要用絕對路徑；symlink 會先解析成實際路徑再寫入設定。路徑中不能有 `%`（smb.conf 會當成變數替換）或換行。
- **Share 名稱**：路徑是 Home 時預設為 `<使用者>-home`，其他路徑預設為最後一層目錄名稱（`/opt` → `opt`）。只能使用英數字與 `.`、`_`、`-`，開頭必須是英數字，最長 80 字元；`global`、`homes`、`printers`、`print$`、`ipc$` 是保留名稱，不能使用。
- 非互動環境下不詢問，直接使用使用者的 Home 與預設 Share 名稱。

### v1：路徑權限檢查

Share 一律以 `force user` 指定的使用者身分存取檔案，所以能否讀寫取決於**該使用者對路徑的權限**，跟路徑由誰擁有無關。例如 `/opt` 由 root 擁有，但使用者透過群組或 ACL 有 rwx 權限，就能正常讀寫，新增的檔案會屬於該使用者。

套用前，v1 會以該使用者身分檢查分享路徑是否可讀、可寫、可進入（群組與 ACL 都會算進去）。檢查使用 bash 內建的 `[[ -r && -w && -x ]]`，不使用外部的 `test` 指令，因為 Ubuntu 25.10 起預設的 uutils coreutils 版 `test -w` 會忽略 ACL，造成誤判。沒有完整權限時會顯示警告，必須輸入 `yes` 才會繼續；此時從 Windows 存取會出現「存取被拒」。**腳本不會修改任何檔案權限**，需要時請自行用 `chown`、`chmod` 或 `setfacl` 調整。

### 已有 Samba 設定時的選單

偵測到既有的 `smb.conf`、同名 share 或 Samba 使用者時，會先顯示勾選選單，讓你決定要套用／覆蓋哪些項目（以下為 v1 的畫面，v3 第 2 項顯示為「Home Share 設定」）：

```text
選擇要套用 / 覆蓋的項目：

 > [*] 1. SMB 安全設定
   [*] 2. Share 設定 (opt)
   [ ] 3. Samba 密碼
   [*] 4. Samba / NetBIOS 服務設定
   [*] 5. UFW 防火牆設定
```

操作：↑/↓ 移動，空白鍵切換，Enter 確認，`A` 全選，`N` 全不選。Samba 使用者尚不存在時，「Samba 密碼」為必要項目，無法取消。非互動環境下不顯示選單，直接使用預設選取項目。

## 各項目內容

| 項目 | 內容 |
| --- | --- |
| SMB 安全設定 | 在 `[global]` 寫入：只允許 SMB 3.1.1、強制加密與簽章、只接受 NTLMv2、禁止 guest 與匿名、關閉 NetBIOS（只開 445）、關閉印表機分享，並移除 `[printers]`、`[print$]` 區段。其他既有 share 保留不動。 |
| Share 設定 | 新增（或覆蓋同名的）share。v1 使用你選擇的路徑與名稱，v3 固定為 `[<使用者>-home]` 與整個 Home。可讀寫、不允許 guest、`force user` 為該使用者、`wide links = No`。 |
| Samba 密碼 | 建立或重設 Samba 使用者密碼。至少 12 個字元，與 Linux / SSH 密碼互相獨立（不會同步）。 |
| Samba / NetBIOS 服務設定 | 停用 `nmbd`，啟用並重新啟動 `smbd`。 |
| UFW 防火牆設定 | UFW 已啟用時，移除 `Samba` 規則，只允許預設路由介面所在的子網連到 TCP/445。UFW 未啟用時不會自動啟用。 |

可以用環境變數指定允許連線的子網，取代自動偵測：

```sh
sudo SMB_ALLOWED_CIDR=192.168.1.0/24 bash deploy-samba-selective-v1.sh
```

## 備份與還原

每次執行都會先把 `/etc/samba/smb.conf` 備份成 `/etc/samba/smb.conf.bak.<時間戳記>`。寫入後會用 `testparm` 驗證，驗證失敗時會自動還原備份並結束。

腳本寫入 `[global]` 的設定區塊會加上標記：v1 為 `# Managed by deploy-samba-selective-v1.sh`，v3 為 `# Managed by deploy-samba-home-selective-v3.sh`。重新執行同一支腳本時，會依標記與設定名稱移除舊的區塊再寫入新的，所以重複執行不會累積重複設定。標記名稱與腳本檔名相同，請勿更改，否則已部署的主機上舊的標記行不會被清除。

## 兩支腳本不相容

v1 不會辨認、也不會處理 v3 留下的設定，反之亦然：

- 在 v3 部署過的主機上執行 v1，`[global]` 中同名的設定會被 v1 取代，但 v3 的標記行會留下來。
- v3 建立的 `[<使用者>-home]` share 只有在 v1 使用相同 Share 名稱時才會被覆蓋，否則兩個 share 會同時存在。
- 要從 v3 換到 v1，建議先手動清理 `/etc/samba/smb.conf` 中 v3 的標記行與不需要的 share，再執行 v1。

## 需求

- Debian / Ubuntu 系（使用 `apt-get`、`systemctl`；v1 另外使用 `runuser`、`realpath`）
- root 權限
- 會自動安裝 `samba`、`python3`

## 已知風險

- **整個分享路徑都會暴露**。分享的是 Home（或包含 Home 的上層目錄，例如 `/`、`/home`）時，`.ssh`、私鑰、`authorized_keys` 與各種設定檔也會暴露，能登入這個 share 的人就能讀取私鑰，或改寫 `authorized_keys` 取得 SSH 登入權限。v1 偵測到這種情況會額外警告。請使用強密碼，並只在信任的區網中開放。
- **檔案操作一律以該使用者身分執行**（`force user`），SMB 端看不出是誰做的修改。
- **只支援 SMB 3.1.1**：Windows 10 / 11 可以連線，舊版 Windows、部分 NAS 與舊的 Linux / macOS 用戶端可能無法連線。
- 未啟用 UFW 時，TCP/445 會對所有能連到這台主機的網路開放，需要自行用其他防火牆限制。
