# 安全檢查工具（safe-test）

授權：MIT，詳見 [LICENSE](./LICENSE)。

`safe-test.sh` 是安全檢查的入口：用勾選清單選擇要執行的檢查項目，再依序呼叫 `applet/` 底下對應的腳本，最後列出每一項的執行結果。各 applet 也可以單獨執行。

> 僅能用於你有權限稽核的網路與主機。掃描未經授權的網路可能違法，也可能觸發入侵偵測。

## 使用方式

在 Linux 的互動式終端機中執行（本機檢查多數需要 root）：

```sh
sudo ./safe-test.sh
```

選單操作：↑/↓ 移動，空白鍵勾選或取消，`a` 全選／全不選，Enter 執行，`q` 離開。

```text
安全檢查項目
> [*] [網路] SSH 密碼登入稽核（掃描子網 22 port）
  [*] [網路] SSH 加密參數稽核（KEX / Host Key / Cipher / MAC）
  [*] [網路] 高風險 port 掃描（Telnet / SMB / RDP / Redis ...）
  [ ] [本機] sshd 設定檢查（需 root）
  [ ] [本機] 空密碼 / UID 0 帳號（需 root）
  [ ] [本機] 對外監聽的服務
  [ ] [本機] sudo 權限稽核（需 root）
  [ ] [輸出] 匯出報告（純文字檔，存到目前目錄，有風險，見下方說明）
```

勾選任一網路檢查時，會再列出本機各介面的 IPv4 子網讓你勾選，並顯示每個子網的 IP 數量。容器與虛擬介面（docker、veth、virbr、tailscale 等）預設不勾。總數超過 65536 個 IP，或任一子網大於 /16 時，必須輸入 `yes` 才會開始掃描。

執行結束會列出每一項的結果（完成／略過／失敗）。只要有任何一項失敗或略過，腳本就會回傳 1。

## 檢查項目

| 類別 | Applet | 內容 | 需要 |
| --- | --- | --- | --- |
| 網路 | `ssh-pwauth.sh` | 掃描子網的 22 port，判斷 SSH 是否允許密碼登入 | `nmap`、`ssh` |
| 網路 | `ssh-crypto.sh` | 列出伺服器提供的所有 KEX / Host Key / Cipher / MAC，標出弱演算法 | `nmap` |
| 網路 | `risky-ports.sh` | 掃描 FTP、Telnet、SMB、RDP、Redis、Docker API 等高風險 port | `nmap` |
| 本機 | `sshd-config.sh` | 以 `sshd -T` 讀取實際生效的 sshd 設定，標示 OK / WARN / BAD | root |
| 本機 | `weak-accounts.sh` | 空密碼帳號、非 root 但 UID 為 0 的帳號 | root |
| 本機 | `listening.sh` | 對外監聽的服務（略過 localhost），標出高風險 port | `ss` |
| 本機 | `sudo-users.sh` | 可登入帳號的 sudo 權限：完整 / 部分 / 無 | root、`sudo` |

### 單獨執行 applet

網路類的 applet 要帶子網參數，本機類不用：

```sh
sudo bash applet/risky-ports.sh 192.168.1.0/24
SAFE_TEST_USER=someone bash applet/ssh-pwauth.sh 10.0.0.0/24
sudo bash applet/sshd-config.sh
```

所有 applet 的退出碼統一為：**0 完成、1 失敗、2 略過**（沒有 root 或缺少工具）。

## 結果判讀

- **SSH 密碼登入**：以測試帳號（預設 `audit_user`，可用 `SAFE_TEST_USER` 更換）連線，從伺服器回應的驗證方式判斷，不會真的輸入密碼。`Match User` / `Match Group` 可能讓其他帳號得到不同結果。
- **主機金鑰**：會比對你的 `known_hosts`（以 sudo 執行時讀原使用者的檔案），比對用的是暫存副本，不會修改原檔。金鑰不符的主機結果不採信，可能有中間人攻擊；不在 `known_hosts` 裡的主機會標示為「未驗證」。
- **sshd 設定**：只檢查全域設定。`Match` 區塊對特定使用者或來源的覆寫，請用 `sshd -T -C user=...,host=...,addr=...` 個別查詢。

## 已知風險：匯出報告

勾選「匯出報告」時，報告會寫到目前目錄下的 `safe-test-<主機>-<時間>.txt`。目前**沒有**做以下防護：

- 檔名可預測，且寫入時會跟隨同名的符號連結並截斷目標。若以 root 在他人可寫入的目錄（例如 `/tmp`）執行，他人可預先放置符號連結，讓 root 覆寫任意檔案。
- 檔案權限取決於當下的 umask，報告內容（主機、開放 port、帳號、sudo 權限）可能被其他使用者讀取。

在選單中把游標移到「匯出報告」時也會顯示這段提醒。建議只在自己擁有、他人無法寫入的目錄匯出，例如：

```sh
mkdir -m 700 ~/audit && cd ~/audit && sudo /path/to/safe-test.sh
```

## 需求

- Linux、Bash 4.3 以上（使用 nameref 與關聯陣列）、互動式終端機。
- `iproute2`（`ip`、`ss`）、`nmap`、OpenSSH client；本機檢查需要 root、`sudo`、`getent`。
- 缺少的工具只會讓對應的檢查被略過，不影響其他項目。
