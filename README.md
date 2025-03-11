Checkmk Update Script - Installation Guide
This script automates the process of updating a Checkmk Raw Edition site. It verifies system requirements, downloads the latest available package, installs it, and performs an omd update.

🛠 Prerequisites
OS: Debian/Ubuntu (tested)

User: Root privileges required

Dependencies: git, curl, wget, dpkg, awk, grep, lsb_release



🚀 Installation Steps
Clone the GitHub repository:

git clone https://github.com/KTOrTs/checkmk_update_script.git

Navigate to the repository directory:

cd checkmk_update_script

Make the script executable:

chmod +x checkmk_update.sh


⚠️ Perform a manual backup before executing the script!

Run the script as root:

./checkmk_update.sh
