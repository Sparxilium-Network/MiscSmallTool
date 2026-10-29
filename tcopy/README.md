# tcopy

在 SSH 遠端主機上，把檔案或指令輸出直接複製到**本機**的剪貼簿。

tcopy 會把內容編碼成 base64，包進 OSC 52 跳脫序列後寫入目前的終端機。剪貼簿由你本機的終端機負責寫入，所以遠端主機不需要 X11、`xclip` 或任何剪貼簿服務。

```sh
tcopy /etc/apache2/sites-enabled/ssl.conf
journalctl -u apache2 -n 50 | tcopy
```

---

## 安裝

```sh
sudo sh install-tcopy.sh
```

會安裝到 `/usr/local/bin/tcopy`，權限為 `root:root 0755`。已有舊版時直接覆蓋，重複執行也沒問題。

安裝程式的行為：

- **原子替換**：新檔案先寫在目的目錄的暫存檔，通過 `sh -n` 語法檢查並設好權限後，才用 `mv` 一次替換。任何一步失敗、磁碟滿或被中斷，舊版 tcopy 都保持原樣，也不會留下暫存檔。
- **不跟隨 symlink**：若 `/usr/local/bin/tcopy` 是 symlink，被替換的是連結本身，不會寫到它指向的檔案。目的地是目錄（或指向目錄的連結）時拒絕安裝。
- **固定目的地**：安裝路徑寫死，不接受環境變數指定，避免以 root 寫入任意位置。
- **不信任呼叫者環境**：固定 `PATH`、`LC_ALL=C`，清除 `CDPATH`、`ENV`、`BASH_ENV` 並重設 `IFS`，不依賴 sudo 的 `secure_path` 設定。
- 非 root 執行會直接拒絕。

---

## 用法

```
tcopy [--no-limit] [--] [file]
```

| 用法 | 說明 |
|---|---|
| `tcopy file` | 複製檔案內容 |
| `cmd \| tcopy` | 複製 stdin |
| `tcopy -- -name.txt` | 檔名以 `-` 開頭時用 `--` 隔開 |
| `sudo tcopy /root/file` | 需要權限的檔案由使用者自行加 `sudo` |
| `tcopy --no-limit big.log` | 解除大小上限（見下方說明） |

不帶參數、也沒有管線輸入時，會顯示用法後結束，不會卡住等待輸入。

成功時輸出：

```
tcopy: OSC 52 sequence sent (8712 encoded bytes); clipboard update depends on the terminal
```

> **注意：** OSC 52 是單向協定，終端機不會回報是否接受。這行訊息只代表序列已送到終端機，剪貼簿有沒有真的更新，請在本機貼上確認。

---

## 大小限制

上限以 **base64 編碼後的位元組數**計算，原始資料約為上限的 3/4。

| 設定 | 上限（編碼後） | 原始資料約 |
|---|---|---|
| 預設 | 65536 | 48 KiB |
| `TCOPY_MAX=N` | N，最大 1048576 | 768 KiB |
| `--no-limit` | 無上限 | — |
| `--no-limit` 加 `TCOPY_MAX=N` | N，最大 999999999 | — |

```sh
TCOPY_MAX=262144 tcopy access.log          # 提高到 256 KiB 編碼後
TCOPY_MAX=3000000 tcopy --no-limit dump.txt
```

讀取時最多只讀「上限 + 1」位元組，所以即使 stdin 無窮無盡，記憶體用量也有上限，超過就拒絕並且不送出任何內容。

`--no-limit` 不帶 `TCOPY_MAX` 時，整個輸入會讀進記憶體，例如 `yes | tcopy --no-limit` 會一直吃記憶體直到被中止。很多終端機也無法接受過大的 OSC 52，會靜默丟棄。只在明確知道輸入大小時使用。

---

## 終端機設定

tcopy 能不能成功，取決於你**本機**的終端機。

| 環境 | 設定 |
|---|---|
| iTerm2 | Settings → General → Selection → 允許終端機應用程式存取剪貼簿 |
| WezTerm、kitty、Alacritty、foot | 通常預設支援 |
| Windows Terminal | 預設支援 |
| Warp | 新版預設拒絕 OSC 52，需在設定中允許；部分版本在 macOS 上有 OSC 52 寫入失效的回歸問題 |
| tmux | `~/.tmux.conf` 加入 `set -g set-clipboard on`，再執行 `tmux source ~/.tmux.conf` |
| GNU screen | 預設會攔下 OSC 52，不建議搭配使用 |

用這行確認終端機本身是否支援，貼上後應得到 `hello`：

```sh
printf '\033]52;c;aGVsbG8=\a'
```

本機分頁可以、SSH 裡不行，問題在中間層（tmux、screen）；本機分頁也不行，問題在終端機設定或版本。

---

## 錯誤訊息

所有錯誤都輸出到 stderr，結束碼為 1，而且**不會送出任何 OSC 52 序列**。

| 訊息 | 原因 |
|---|---|
| `not found or not a regular file` | 路徑不存在，或是目錄、裝置等非一般檔案 |
| `cannot read file` | 沒有讀取權限，需要的話改用 `sudo tcopy` |
| `empty input, nothing sent` | 輸入為空。刻意拒絕，避免部分終端機把空 payload 當成清空剪貼簿 |
| `input too large (...)` | 超過大小上限 |
| `reading or encoding the input failed, nothing sent` | 讀取或編碼過程中有任何一個階段失敗 |
| `cannot write to /dev/tty` | 沒有控制終端機，例如在 cron 或非互動環境中執行 |
| `TCOPY_MAX must ...` | `TCOPY_MAX` 不是合法的正整數或超出範圍 |

---

## 安全設計

- **不輸出檔名**：Unix 檔名可以包含 ESC、BEL 和 C1 控制位元組，回顯到終端機可能造成跳脫序列注入。所有訊息都不含檔名。
- **只開檔一次**：檢查之後只開啟一次檔案，所有讀取都來自同一個 descriptor，沒有先 `wc -c` 再讀的 TOCTOU。
- **有上限的讀取**：優先用 `head -c`；沒有時退回 `dd bs=1`。不用更大的 `dd` block size，因為在管線上短讀會讓資料被靜默截斷。
- **每個管線階段都檢查失敗**：POSIX sh 沒有 `pipefail`。每個階段失敗時都寫入一個不在 base64 字母表中的 `!` 標記，只要輸出中出現就整筆拒絕，不會送出被截斷的內容。
- **固定 PATH 與 locale**：tcopy 只使用 `/usr/bin:/bin:/usr/sbin:/sbin` 中的工具，並設定 `LC_ALL=C`，在 `sudo tcopy` 下也不受呼叫者的 PATH 影響。
- **寫入 `/dev/tty`**：序列直接寫到終端機，不走 stdout，所以 `tcopy file > out` 不會把跳脫序列寫進檔案。
- **32-bit 安全的數值範圍**：所有數值都低於 2³¹，在 shell 算術只有 32-bit 的平台上也不會溢位。

已知限制：`[ -f ]` 檢查和開檔之間仍有很小的時間窗。若路徑位於攻擊者可寫的目錄，檔案可能在這之間被換成 FIFO，造成開檔阻塞。純 POSIX sh 無法以非阻塞方式開檔，所以無法完全消除。讀到的內容仍只來自那唯一一次開檔，並受大小上限保護。

---

## 相容性

- 純 POSIX `/bin/sh`，已在 dash（Debian、Ubuntu 的 `/bin/sh`）和 bash 下測試。
- 依賴：`base64`、`tr`、`head`（或 `dd`）、`cat`，都必須位於系統目錄。`base64` 不屬於 POSIX，但 GNU coreutils、BSD、macOS 和 busybox 都有。
- 二進位檔可以編碼送出，但剪貼簿收到的是文字，貼上結果通常沒有意義。
