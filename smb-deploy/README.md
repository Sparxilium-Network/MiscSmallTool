# Samba Home 部署工具

授權：MIT，詳見 [LICENSE](./LICENSE)。

`deploy-samba-home.sh` 會在 Debian / Ubuntu 主機上安裝 Samba，把一位 Linux 使用者的整個 Home 目錄分享成 SMB share，並套用偏嚴格的 SMB 安全設定。適合在區網內的 VM 或開發機上，讓 Windows 直接存取 Linux Home。

> 不要把 TCP/445 直接 Port Forward 到公網。

## 使用方式

在 Linux 的互動式終端機中，以要分享 Home 的那位使用者身分透過 sudo 執行：

```sh
sudo bash deploy-samba-home.sh
```

- 分享對象預設為 `SUDO_USER`；若取不到（或是 root），會改用 `logname`，再不行就要求輸入使用者名稱。
- Share 名稱固定為 `<使用者>-home`，例如 `paul-home`。
- 執行前會列出即將套用的項目，必須輸入 `YES` 才會修改系統。
- 完成後會顯示 Windows 連線路徑，例如 `\\192.168.1.10\paul-home`。

### 已有 Samba 設定時的選單

偵測到既有的 `smb.conf`、同名 share 或 Samba 使用者時，會先顯示勾選選單，讓你決定要套用／覆蓋哪些項目：

```text
選擇要套用 / 覆蓋的項目：

 > [*] 1. SMB 安全設定
   [*] 2. Home Share 設定 (paul-home)
   [ ] 3. Samba 密碼
   [*] 4. Samba / NetBIOS 服務設定
   [*] 5. UFW 防火牆設定
```

操作：↑/↓ 移動，空白鍵切換，Enter 確認，`A` 全選，`N` 全不選。Samba 使用者尚不存在時，「Samba 密碼」為必要項目，無法取消。非互動環境下不顯示選單，直接使用預設選取項目。

## 各項目內容

| 項目 | 內容 |
| --- | --- |
| SMB 安全設定 | 在 `[global]` 寫入：只允許 SMB 3.1.1、強制加密與簽章、只接受 NTLMv2、禁止 guest 與匿名、關閉 NetBIOS（只開 445）、關閉印表機分享，並移除 `[printers]`、`[print$]` 區段。其他既有 share 保留不動。 |
| Home Share 設定 | 新增（或覆蓋同名的）`[<使用者>-home]`，路徑為整個 Home 目錄，可讀寫、不允許 guest、`force user` 為該使用者、`wide links = No`。 |
| Samba 密碼 | 建立或重設 Samba 使用者密碼。至少 12 個字元，與 Linux / SSH 密碼互相獨立（不會同步）。 |
| Samba / NetBIOS 服務設定 | 停用 `nmbd`，啟用並重新啟動 `smbd`。 |
| UFW 防火牆設定 | UFW 已啟用時，移除 `Samba` 規則，只允許預設路由介面所在的子網連到 TCP/445。UFW 未啟用時不會自動啟用。 |

可以用環境變數指定允許連線的子網，取代自動偵測：

```sh
sudo SMB_ALLOWED_CIDR=192.168.1.0/24 bash deploy-samba-home.sh
```

## 備份與還原

每次執行都會先把 `/etc/samba/smb.conf` 備份成 `/etc/samba/smb.conf.bak.<時間戳記>`。寫入後會用 `testparm` 驗證，驗證失敗時會自動還原備份並結束。

腳本寫入 `[global]` 的設定區塊會以 `# Managed by deploy-samba-home-selective-v3.sh` 標記。重新執行時會依這個標記與設定名稱移除舊的區塊再寫入新的，所以重複執行不會累積重複設定。

## 需求

- Debian / Ubuntu 系（使用 `apt-get`、`systemctl`）
- root 權限
- 會自動安裝 `samba`、`python3`

## 已知風險

- **整個 Home 都會暴露**：包含 `.ssh`、私鑰、`authorized_keys` 與各種設定檔。能登入這個 share 的人，就能讀取私鑰，或改寫 `authorized_keys` 取得 SSH 登入權限。請使用強密碼，並只在信任的區網中開放。
- **檔案操作一律以該使用者身分執行**（`force user`），SMB 端看不出是誰做的修改。
- **只支援 SMB 3.1.1**：Windows 10 / 11 可以連線，舊版 Windows、部分 NAS 與舊的 Linux / macOS 用戶端可能無法連線。
- 未啟用 UFW 時，TCP/445 會對所有能連到這台主機的網路開放，需要自行用其他防火牆限制。
