# ✅ Checkmk Update Script

This script simplifies the update process for Checkmk Raw Edition sites on Debian/Ubuntu systems.

---

## 🚀 Features

- Automatically detects installed Checkmk sites
- Checks for and installs missing required packages
- Downloads and installs the latest Checkmk Raw Edition package
- Performs `omd update` on the selected site
- Logs detailed debug information
- Includes safety checks (disk space, root permissions, etc.)

---

## ⚠️ Perform a manual backup before executing the script!
## 📥 Installation

### Clone this repository and make the script executable

```bash
git clone https://github.com/KTOrTs/checkmk_update_script.git
```

2. Change into the repository directory

```bash
cd checkmk_update_script
```

3. Make the script executable:
```bash
chmod +x checkmk_update.sh
```
4. Run the script as root
```bash
./checkmk_update.sh
```

---

## ❓ Troubleshooting
- If something goes wrong, the script will display an error and ask whether you want to continue.
- Check the debug log for detailed output:
```bash  
tail -f /tmp/cmkupdate/checkmk_update_debug.log
```
---
## 💡 Disclaimer
This script is provided "as is" without warranty of any kind. Use it at your own risk!
Test in a staging environment before running in production.

