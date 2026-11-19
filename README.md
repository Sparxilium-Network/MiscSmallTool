# Misc Small Tool

A collection of small scripts, utilities, and miscellaneous tools.  
這裡收集一些小型腳本、實用工具與其他雜項程式。

Repository:  
https://github.com/Sparxilium-Network/MiscSmallTool

## Tools / Scripts

| Name | What is this | 這是甚麼 | License / 授權 |
| --- | --- | --- | --- |
| [opensk-setup.sh](./opensk-neo/opensk-setup.sh) | Interactive OpenSK setup and flashing helper. It can clone OpenSK, prepare the local toolchain and crypto data, patch `nrfdfu`, configure AAGUID/attestation, select firmware features, and flash supported targets. See [its README](./opensk-neo/README.md) for setup and usage details. | OpenSK 互動式安裝與燒錄輔助腳本，可自動 clone OpenSK、準備工具鏈與 crypto data、修補 `nrfdfu`、設定 AAGUID／attestation、選擇韌體功能並燒錄支援的裝置。詳細說明請見[專屬 README](./opensk-neo/README.md)。 | GNU AGPLv3 |
| [install-tcopy.sh](./tcopy/install-tcopy.sh) | Installs or atomically replaces the `tcopy` OSC 52 clipboard utility. See [README](./tcopy/README.md). | 安裝或原子替換 `tcopy` 終端機剪貼簿工具。用法與安全設計請見[說明文件](./tcopy/README.md)。 | MIT ([LICENSE](./tcopy/LICENSE)) |
| [nvme-clean.sh](./nvme/nvme-clean.sh) | Scans local NVMe disks and lets you select individual erase targets. See [README](./nvme/README.md). | 掃描本機 NVMe 磁碟並逐顆勾選清除目標。操作與注意事項請見[說明文件](./nvme/README.md)。 | MIT ([LICENSE](./nvme/LICENSE)) |
| [safe-test.sh](./security/safe-test.sh) | Interactive security audit launcher. Pick checks from a checklist (SSH password auth, SSH crypto, risky ports, sshd config, weak accounts, listening services, sudo users) and it runs each one as a separate script under `applet/`. See [README](./security/README.md). | 互動式安全檢查入口，以勾選清單選擇 SSH 密碼登入、SSH 加密參數、高風險 port、sshd 設定、弱帳號、對外監聽服務、sudo 權限等檢查，各項由 `applet/` 下的獨立腳本執行。用法與已知風險請見[說明文件](./security/README.md)。 | MIT ([LICENSE](./security/LICENSE)) |
| [deploy-samba-selective-v1.sh](./smb-deploy/deploy-samba-selective-v1.sh) | Shares a directory over SMB with the same hardened Samba settings and checklist as the v3 script. The path defaults to the user's home but can be any directory (e.g. `/opt`), and the share name is editable. It checks that the user can read and write the path but never changes permissions. **Not compatible with the v3 script; only recommended for Codex / Claude agent sandboxes.** See [README](./smb-deploy/README.md). | 以 SMB 分享一個目錄，安全設定與勾選清單同 v3。路徑預設為使用者 Home，可自行輸入其他目錄（例如 `/opt`），Share 名稱可修改；會檢查使用者能否讀寫該路徑，但不會修改權限。**與 v3 腳本不相容，只建議用於 Codex / Claude agent 沙箱。** 用法與風險請見[說明文件](./smb-deploy/README.md)。 | MIT ([LICENSE](./smb-deploy/LICENSE)) |
| [deploy-samba-home-selective-v3.sh](./smb-deploy/deploy-samba-home-selective-v3.sh) | Shares a Linux user's home directory over SMB with hardened Samba settings (SMB 3.1.1 only, encryption and signing required, no guest/NetBIOS/printing), with a checklist for re-applying individual parts and LAN-only UFW rules. **Only recommended for Codex / Claude agent sandboxes**, so you can read and work with the sandbox's files directly. See [README](./smb-deploy/README.md). | 把 Linux 使用者的 Home 目錄以 SMB 分享，並套用強化的 Samba 安全設定（僅 SMB 3.1.1、強制加密與簽章、禁 guest／NetBIOS／印表機），可用勾選清單個別重新套用，並將 UFW 限制在區網。**只建議用於 Codex / Claude agent 沙箱**，讓使用者可以直接操作、讀取沙箱內的檔案。用法與風險請見[說明文件](./smb-deploy/README.md)。 | MIT ([LICENSE](./smb-deploy/LICENSE)) |

## Notes

- Each tool or script may have its own requirements, usage instructions, and license.
- Please check the source code or related documentation before use.
- Some scripts may be experimental or created for specific use cases.
- Licenses may differ between individual scripts.

---

- 每個工具或腳本可能有不同的依賴、使用方式與授權條款。
- 使用前請先查看原始碼或相關說明。
- 部分腳本可能屬於實驗性質，或只針對特定用途設計。
- 各腳本的授權可能不同，請以表格或腳本目錄內的授權說明為準。

## License

Each script or tool may use a different license.  
Please refer to the **License / 授權** column above and any license file included with the individual script.

每個腳本或工具可能採用不同的授權條款。  
請參考上方的 **License / 授權** 欄位，以及各腳本目錄內附帶的授權文件。
