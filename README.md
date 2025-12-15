# ✅ Checkmk Update Script

This script simplifies the update process for Checkmk Raw Edition sites on Debian/Ubuntu systems.

---

## 🚀 Features

- Automatically detects installed Checkmk sites
- Checks for missing packages and installs them
- Stops the site before creating an OMD backup to reduce load and keep the archive consistent (stored in `/var/backups/checkmk`)
- Optional self-test mode to verify prerequisites before running an update
- Downloads and installs the latest Checkmk Raw Edition package
- Checks GitHub for script updates with a time-limited request
- Performs `omd update` on the selected site
- Logs detailed debug information
- Includes safety checks (disk space, root permissions, etc.)

---
## 📥 Installation

1. Clone this repository and make the script executable

```bash
git clone https://github.com/KTOrTs/checkmk_update_script.git
```

2. Change into the repository directory

```bash
cd checkmk_update_script
```

3. Make the script executable:
```bash
chmod +x cmkupdate.sh
```
4. Run the script as root
```bash
./cmkupdate.sh
```

---

## ❓ Troubleshooting
- If something goes wrong, the script will display an error and ask whether you want to continue.
- Check the debug log for detailed output:
```bash
tail -f /tmp/cmkupdate/checkmk_update_debug.log
```

---
## 🔄 Restore aus dem Backup
1. Den passenden Backup-Pfad im Verzeichnis `/var/backups/checkmk` auswählen (Beispiel: `my-site_20240101_120000.omd.gz`).
2. Den Ziel-Site-Namen kontrollieren oder bei Bedarf eine neue Site anlegen.
3. Das Backup mit `omd restore` einspielen:
   ```bash
   omd restore <SITE_NAME> /var/backups/checkmk/<DATEI>.omd.gz
   ```
4. Die Site wieder starten (falls sie gestoppt ist):
   ```bash
   omd start <SITE_NAME>
   ```
Alle Schritte benötigen Root-Rechte.
---
## 💡 Disclaimer
This script is provided "as is" without warranty of any kind. Use it at your own risk!
Test in a staging environment before running in production.

