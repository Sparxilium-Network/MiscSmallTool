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
