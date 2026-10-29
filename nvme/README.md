# NVMe 磁碟清除工具

授權：MIT，詳見 [LICENSE](./LICENSE)。

`nvme-clean.sh` 會掃描本機 NVMe 磁碟，讓你逐顆勾選要清除的目標。未選取的磁碟不會被清除，也不會自動清除全部磁碟。

## 使用方式

在 Linux 的互動式終端機中，以 root 權限執行：

```sh
sudo ./nvme-clean.sh
```

選單會列出 NVMe 編號、掛載點、裝置路徑與型號。用 ↑/↓ 移動，空白鍵選取或取消，Enter 確認，`q` 離開。所有磁碟預設為未勾選；確認畫面只會列出你選取的磁碟，並要求輸入 `YES` 才會繼續。

選單範例：

```text
[*] NVME 1 /mnt/XX             /dev/nvme0n1 (Example SSD)
[ ] NVME 2 /                   /dev/nvme1n1 (Example SSD)
```

目前系統的根檔案系統 `/` 所在磁碟不能由這個系統清除。其他所選磁碟上的掛載分割區會先嘗試卸載；若仍有掛載點或卸載失敗，腳本會略過該磁碟。

掃描時會排除 USB 外接 NVMe 與分割區。清除前後會擷取 SMART 資料，並嘗試 Cryptographic Erase；若不支援，則改用 User Data Erase。紀錄與總結會寫入目前目錄下的 `nvme_erase_logs_<時間戳記>/`。

## 需求與注意事項

- Linux、Bash、`nvme-cli`、`util-linux`（需有 `lsblk`、`findmnt`），以及 `udevadm`。
- 需要 root 權限與互動式終端機。
- 清除會永久刪除所選磁碟資料。輸入 `YES` 前，請核對裝置路徑、型號、序號與掛載點。
