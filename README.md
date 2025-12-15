# ✅ Checkmk Update Script

A single Bash script that streamlines Checkmk Raw Edition updates on Debian/Ubuntu by handling backups, downloads, installs, and safety checks for you.

---

## 🚀 Features

- Automatically detects installed Checkmk sites and picks the single site, or lets you choose when multiple exist.
- Checks required dependencies and disk space before proceeding.
- Stops the chosen site before taking an OMD backup to keep the archive consistent and reduce load.
- Shows the estimated backup size (from `du -sk /opt/omd/sites/<SITE>`, uncompressed) plus live archive growth and the final compression ratio while the compressed backup runs to `/var/backups/checkmk`.
- Optional `--self-test` mode to verify syntax and dependencies without touching your site.
- Downloads the latest Checkmk Raw Edition package with a visible progress bar and expected size.
- Looks for script updates on GitHub with a time-limited request.
- Runs `omd update` for you after the new package is installed.
- Logs detailed debug information to `/tmp/cmkupdate/checkmk_update_debug.log` for troubleshooting.

---

## 📦 Requirements

- Debian/Ubuntu host with root privileges.
- A Checkmk Raw Edition site managed by `omd`.
- Commands available: `omd`, `lsb_release`, `wget`, `curl`, `dpkg`, `awk`, `grep`, `df`, `sort`.
- Sufficient free space on both the site volume and `/var/backups/checkmk` for the backup and package download.

---

## 📥 Installation

1. Clone this repository and change into it:
   ```bash
   git clone https://github.com/KTOrTs/checkmk_update_script.git
   cd checkmk_update_script
   ```
2. Make the script executable:
   ```bash
   chmod +x cmkupdate.sh
   ```

---

## ▶️ Usage

- Run a quick prerequisite check (syntax + required commands) without touching your site:
  ```bash
  ./cmkupdate.sh --self-test
  ```

- Perform an update (runs as root and will stop the site for the backup):
  ```bash
  sudo ./cmkupdate.sh
  ```

  During the run you will see:
  - Estimated site size (uncompressed) derived from `du -sk /opt/omd/sites/<SITE>`.
  - Live backup progress showing how the compressed archive grows compared to the estimate and the final compression ratio.
  - Download progress and expected package size.

- Need help? Display the built-in usage text:
  ```bash
  ./cmkupdate.sh --help
  ```

---

## 📦 Backup behavior

1. The script stops the selected site before creating the archive to keep data consistent.
2. It checks available space in `/var/backups/checkmk` and reports the uncompressed site size estimate.
3. `omd backup` writes a compressed archive while the script reports current MB on disk and the percentage relative to the uncompressed estimate.
4. The final backup location and compression ratio are written to both the console and the debug log.

---

## 🔄 Restore from Backup

1. Locate the desired backup in `/var/backups/checkmk` (example: `mysite_20240101_120000.omd.gz`).
2. Restore with `omd restore` (requires root):
   ```bash
   omd restore <SITE_NAME> /var/backups/checkmk/<FILE>.omd.gz
   ```
3. Start the site again if needed:
   ```bash
   omd start <SITE_NAME>
   ```

---

## ❓ Troubleshooting

- Follow the live log to confirm activity and investigate issues:
  ```bash
  tail -f /tmp/cmkupdate/checkmk_update_debug.log
  ```
- If a step fails, the script keeps the debug log and asks whether you want to continue.
- Rerun with `--self-test` to confirm dependencies if the script exits early.

---

## 💡 Disclaimer

This script is provided "as is" without warranty of any kind. Use it at your own risk and test in a staging environment before production.
