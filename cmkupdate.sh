#!/bin/bash

#######################################
# Checkmk Update Script
# GitHub: https://github.com/KTOrTs/checkmk_update_script
# Version: 1.1.0
#######################################

TMP_DIR="/tmp/cmkupdate"
mkdir -p "$TMP_DIR"

DEBUG=1
DEBUG_LOG_FILE="${TMP_DIR}/checkmk_update_debug.log"

TEXT_RESET='\e[0m'
TEXT_YELLOW='\e[0;33m'
TEXT_GREEN='\e[0;32m'
TEXT_RED='\e[0;31m'
TEXT_BLUE='\e[0;34m'

SCRIPT_VERSION="1.1.0"

GITHUB_REPO="KTOrTs/checkmk_update_script"
RAW_SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/checkmk_update.sh"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"


debug_log() {
    local message="[DEBUG] $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${message}" >> "$DEBUG_LOG_FILE"
}

ask_continue_on_error() {
    local error_msg="$1"
    echo -e "${TEXT_RED}${error_msg}${TEXT_RESET}"
    debug_log "${error_msg}"
    echo -e "${TEXT_RED}Debug log remains available at: ${DEBUG_LOG_FILE}${TEXT_RESET}"
    while true; do
        read -rp "Do you want to continue the script? [y/n]: " user_input
        case "$user_input" in
            [Yy]) debug_log "User chose to continue the script."; break ;;
            [Nn]) debug_log "User aborted the script."; echo -e "${TEXT_RED}Script will be terminated.${TEXT_RESET}"; exit 1 ;;
            *) echo "Please enter 'y' for Yes or 'n' for No." ;;
        esac
    done
}

final_cleanup() {
    debug_log "Cleaning up temporary files (directory ${TMP_DIR})."
    rm -rf "$TMP_DIR"
}

version_gt() {
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

check_for_new_script_version() {
    echo -e "${TEXT_YELLOW}Checking for a new script version...${TEXT_RESET}"
    debug_log "Checking GitHub API for the latest release."

    API_RESPONSE=$(curl -s --fail "$GITHUB_API_URL")

    if [ $? -ne 0 ] || [[ "$API_RESPONSE" == *"API rate limit exceeded"* ]]; then
        debug_log "GitHub API request failed or rate limit exceeded."
        echo -e "${TEXT_YELLOW}Could not check for updates (API limit or connection issue).${TEXT_RESET}"
        return
    fi

    LATEST_SCRIPT_VERSION=$(echo "$API_RESPONSE" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [ -z "$LATEST_SCRIPT_VERSION" ]; then
        debug_log "Failed to extract latest version from API response."
        echo -e "${TEXT_YELLOW}Could not determine latest version.${TEXT_RESET}"
        return
    fi

    debug_log "Current script version: ${SCRIPT_VERSION}"
    debug_log "Latest script version on GitHub: ${LATEST_SCRIPT_VERSION}"



    if version_gt "$LATEST_SCRIPT_VERSION" "$SCRIPT_VERSION"; then
        echo -e "${TEXT_GREEN}A new script version (${LATEST_SCRIPT_VERSION}) is available!${TEXT_RESET}"
        while true; do
            read -rp "Do you want to download and replace this script with the latest version? [y/n]: " update_choice
            case "$update_choice" in
                [Yy])
                    debug_log "User chose to update the script to ${LATEST_SCRIPT_VERSION}."
                    echo -e "${TEXT_YELLOW}Downloading the latest script...${TEXT_RESET}"
                    curl -s -o "$0.new" "$RAW_SCRIPT_URL"
                    CURL_EXIT=$?
                    if [ $CURL_EXIT -ne 0 ]; then
                        echo -e "${TEXT_RED}Failed to download the new script version.${TEXT_RESET}"
                        debug_log "Failed to download the new script version (curl exit code: ${CURL_EXIT})"
                        return
                    fi
                    mv "$0.new" "$0"
                    chmod +x "$0"
                    echo -e "${TEXT_GREEN}Script updated to version ${LATEST_SCRIPT_VERSION}. Please re-run the script.${TEXT_RESET}"
                    debug_log "Script successfully updated to ${LATEST_SCRIPT_VERSION}. Exiting for re-run."
                    exit 0
                    ;;
                [Nn])
                    debug_log "User chose not to update the script."
                    break
                    ;;
                *)
                    echo "Please enter 'y' for Yes or 'n' for No."
                    ;;
            esac
        done
    else
        echo -e "${TEXT_GREEN}You are using the latest script version (${SCRIPT_VERSION}).${TEXT_RESET}"
        debug_log "Script is up to date (${SCRIPT_VERSION})."
    fi
}

check_and_install_packages() {
    debug_log "---------------------------------"
    debug_log "Checking required packages..."
    debug_log "---------------------------------"

    REQUIRED_CMDS=("lsb_release" "wget" "curl" "dpkg" "awk" "grep" "df" "sort")
    MISSING_PACKAGES=()

    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            debug_log "Missing command detected: $cmd"
            case "$cmd" in
                lsb_release) MISSING_PACKAGES+=("lsb-release") ;;
                wget)        MISSING_PACKAGES+=("wget") ;;
                curl)        MISSING_PACKAGES+=("curl") ;;
                dpkg)        MISSING_PACKAGES+=("dpkg") ;;
                awk)         MISSING_PACKAGES+=("gawk") ;;
                grep)        MISSING_PACKAGES+=("grep") ;;
                df)          MISSING_PACKAGES+=("coreutils") ;;
                sort)        MISSING_PACKAGES+=("coreutils") ;;
            esac
        else
            debug_log "Command $cmd is available."
        fi
    done

    if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
        debug_log "The following packages will be installed: ${MISSING_PACKAGES[*]}"
        apt-get update -qq &>> "$DEBUG_LOG_FILE"
        APT_UPDATE_EXIT=$?
        debug_log "apt-get update -> Exit code: ${APT_UPDATE_EXIT}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING_PACKAGES[@]}" &>> "$DEBUG_LOG_FILE"
        APT_INSTALL_EXIT=$?
        debug_log "apt-get install ${MISSING_PACKAGES[*]} -> Exit code: ${APT_INSTALL_EXIT}"
        if [ $APT_INSTALL_EXIT -ne 0 ]; then
            ask_continue_on_error "Error installing required packages (Exit code: ${APT_INSTALL_EXIT})"
        else
            debug_log "All missing packages were successfully installed."
        fi
    else
        debug_log "All required packages are already installed."
    fi
}


debug_log "---------------------------------"
debug_log "Script start"
debug_log "---------------------------------"
echo "Starting update script $(date)" > "$DEBUG_LOG_FILE"
echo -e "${TEXT_BLUE}Debug log is located at: ${DEBUG_LOG_FILE}${TEXT_RESET}"
echo -e "${TEXT_BLUE}Monitor with: ${TEXT_GREEN}tail -f ${DEBUG_LOG_FILE}${TEXT_RESET}\n"
sleep 1

check_for_new_script_version

debug_log "---------------------------------"
debug_log "Checking for root privileges"
debug_log "---------------------------------"
if (( EUID != 0 )); then
    error_msg="This script must be run as root. Current user: $(whoami)"
    echo -e "${TEXT_RED}${error_msg}${TEXT_RESET}"
    debug_log "$error_msg"
    exit 1
fi

check_and_install_packages

debug_log "--------------------------------------------------"
debug_log "Fetching available Checkmk sites via 'omd sites'..."
debug_log "--------------------------------------------------"

OMD_SITES_RAW=$(omd sites 2>&1)
debug_log "Raw output from 'omd sites':"
debug_log "$OMD_SITES_RAW"

CHECKMK_SITES=($(echo "$OMD_SITES_RAW" | grep -v "^SITE" | awk '{print $1}'))
debug_log "Detected sites: ${CHECKMK_SITES[*]}"

if [ ${#CHECKMK_SITES[@]} -eq 0 ]; then
    debug_log "No Checkmk sites found. Exiting script."
    echo -e "${TEXT_RED}No Checkmk site found!${TEXT_RESET}"
    exit 1
fi

debug_log "---------------------------------"
debug_log "One or multiple sites detected?"
debug_log "---------------------------------"
if [ ${#CHECKMK_SITES[@]} -eq 1 ]; then
    CHECKMK_SITE=${CHECKMK_SITES[0]}
    debug_log "Exactly one site found: ${CHECKMK_SITE}"
else
    echo -e "${TEXT_YELLOW}Multiple Checkmk sites found. Please select one:${TEXT_RESET}"
    debug_log "Multiple sites found: ${CHECKMK_SITES[*]}"
    select site in "${CHECKMK_SITES[@]}"; do
        if [[ -n "$site" ]]; then
            CHECKMK_SITE="$site"
            debug_log "User selected site: ${CHECKMK_SITE}"
            break
        else
            echo "Invalid selection. Please enter a valid number."
        fi
    done
fi

debug_log "--------------------------------------------------"
debug_log "Starting update for site: ${CHECKMK_SITE}"
debug_log "--------------------------------------------------"

CHECKMK_DIR="/opt/omd/sites/${CHECKMK_SITE}"
INSTALLED_VERSION=$(omd version | awk '{print $NF}')
DISTRO=$(lsb_release -sc)
ARCH=$(dpkg --print-architecture)

debug_log "Site name: ${CHECKMK_SITE}"
debug_log "Site directory: ${CHECKMK_DIR}"
debug_log "Installed version (omd version): ${INSTALLED_VERSION}"
debug_log "Linux distribution: ${DISTRO}"
debug_log "Architecture: ${ARCH}"

debug_log "---------------------------------"
debug_log "Checking disk space"
debug_log "---------------------------------"
REQUIRED_SPACE=2048
AVAILABLE_SPACE=$(df --output=avail /opt/omd/ | tail -n 1)

debug_log "Available space on /opt/omd/: ${AVAILABLE_SPACE} KB"
debug_log "Required minimum space: ${REQUIRED_SPACE} MB"

if (( AVAILABLE_SPACE < REQUIRED_SPACE * 1024 )); then
    ask_continue_on_error "Not enough disk space on /opt/omd/. Available: ${AVAILABLE_SPACE} KB"
else
    debug_log "Sufficient disk space available."
fi

debug_log "---------------------------------"
debug_log "Checking for latest version"
debug_log "---------------------------------"
echo -e "${TEXT_YELLOW}Checking for the latest available Checkmk version...${TEXT_RESET}"
TMP_FILE="${TMP_DIR}/checkmk_versions.html"
curl -s https://checkmk.com/download -o "$TMP_FILE"
CURL_EXIT=$?
debug_log "curl -s https://checkmk.com/download -> Exit code: ${CURL_EXIT}"

if [ $CURL_EXIT -ne 0 ]; then
    ask_continue_on_error "Error fetching Checkmk versions (curl exit code: ${CURL_EXIT})"
fi

LATEST_VERSION=$(grep -oP '(?<=check-mk-raw-)[0-9]+\.[0-9]+\.[0-9]+(?:p[0-9]+)?' "$TMP_FILE" | sort -V | tail -n 1)
debug_log "Latest detected version: ${LATEST_VERSION}"

if [ -z "$LATEST_VERSION" ]; then
    ask_continue_on_error "Could not determine the latest Checkmk version."
fi

echo -e "${TEXT_YELLOW}Installed version: ${TEXT_GREEN}${INSTALLED_VERSION}${TEXT_RESET}"
echo -e "${TEXT_YELLOW}Latest available version: ${TEXT_GREEN}${LATEST_VERSION}${TEXT_RESET}"

if [ "$INSTALLED_VERSION" == "$LATEST_VERSION.cre" ]; then
    echo -e "${TEXT_GREEN}Checkmk is already up to date.${TEXT_RESET}"
    debug_log "Checkmk is already up to date. No updates required."
    rm -f "$TMP_FILE"
    final_cleanup
    exit 0
fi

debug_log "---------------------------------"
debug_log "Downloading update"
debug_log "---------------------------------"
echo -e "${TEXT_BLUE}Update available! Starting download...${TEXT_RESET}"
UPDATE_PACKAGE="check-mk-raw-${LATEST_VERSION}_0.${DISTRO}_${ARCH}.deb"
DOWNLOAD_URL="https://download.checkmk.com/checkmk/${LATEST_VERSION}/${UPDATE_PACKAGE}"

debug_log "Update package: ${UPDATE_PACKAGE}"
debug_log "Download URL: ${DOWNLOAD_URL}"

wget -q "$DOWNLOAD_URL" -O "${TMP_DIR}/${UPDATE_PACKAGE}"
WGET_EXIT=$?
debug_log "wget download -> Exit code: ${WGET_EXIT}"

if [ $WGET_EXIT -ne 0 ]; then
    ask_continue_on_error "Error downloading the update package (wget exit code: ${WGET_EXIT})"
else
    debug_log "Download successful. File: ${TMP_DIR}/${UPDATE_PACKAGE}"
fi

debug_log "---------------------------------"
debug_log "Installing the update"
debug_log "---------------------------------"
echo -e "${TEXT_YELLOW}Installing update package...${TEXT_RESET}"
dpkg -i "${TMP_DIR}/${UPDATE_PACKAGE}" &>> "$DEBUG_LOG_FILE"
DPKG_EXIT=$?
debug_log "dpkg installation -> Exit code: ${DPKG_EXIT}"

if [ $DPKG_EXIT -ne 0 ]; then
    ask_continue_on_error "Error during installation (dpkg exit code: ${DPKG_EXIT})"
else
    debug_log "Update package installed successfully."
fi

debug_log "---------------------------------"
debug_log "Stopping Checkmk site"
debug_log "---------------------------------"
echo -e "${TEXT_YELLOW}Stopping Checkmk site (${CHECKMK_SITE})...${TEXT_RESET}"
omd stop "$CHECKMK_SITE" &>> "$DEBUG_LOG_FILE"
STOP_EXIT=$?
debug_log "omd stop -> Exit code: ${STOP_EXIT}"

if [ $STOP_EXIT -ne 0 ]; then
    ask_continue_on_error "Error stopping the site (omd stop exit code: ${STOP_EXIT})"
else
    debug_log "Site ${CHECKMK_SITE} stopped."
fi

debug_log "--------------------------------------------------"
debug_log "Starting omd update ${CHECKMK_SITE}..."
debug_log "--------------------------------------------------"
echo -e "${TEXT_YELLOW}Running omd update for ${CHECKMK_SITE}...${TEXT_RESET}"
omd update "$CHECKMK_SITE" 2>&1 | tee -a "$DEBUG_LOG_FILE"
UPDATE_EXIT=${PIPESTATUS[0]}

if [ $UPDATE_EXIT -ne 0 ]; then
    ask_continue_on_error "Error running omd update (exit code: ${UPDATE_EXIT})"
else
    debug_log "omd update completed successfully."
fi

debug_log "---------------------------------"
debug_log "Starting Checkmk site"
debug_log "---------------------------------"
echo -e "${TEXT_YELLOW}Starting Checkmk site (${CHECKMK_SITE})...${TEXT_RESET}"
omd start "$CHECKMK_SITE" &>> "$DEBUG_LOG_FILE"
START_EXIT=$?
debug_log "omd start -> Exit code: ${START_EXIT}"

if [ $START_EXIT -ne 0 ]; then
    ask_continue_on_error "Error starting the site (omd start exit code: ${START_EXIT})"
else
    debug_log "Site ${CHECKMK_SITE} started."
fi

debug_log "---------------------------------"
debug_log "Cleanup & status check"
debug_log "---------------------------------"
echo -e "${TEXT_YELLOW}Running omd cleanup...${TEXT_RESET}"
omd cleanup &>> "$DEBUG_LOG_FILE"
CLEANUP_EXIT=$?
debug_log "omd cleanup -> Exit code: ${CLEANUP_EXIT}"

echo -e "${TEXT_YELLOW}Checking site status...${TEXT_RESET}"
STATUS_OUTPUT=$(omd status "$CHECKMK_SITE")
STATUS_EXIT=$?

debug_log "omd status:\n${STATUS_OUTPUT}"
debug_log "omd status exit code: ${STATUS_EXIT}"

echo -e "${TEXT_BLUE}Checkmk status:${TEXT_RESET}\n$STATUS_OUTPUT"

if [ $STATUS_EXIT -ne 0 ]; then
    echo -e "${TEXT_RED}Checkmk site is NOT running correctly!${TEXT_RESET}"
    debug_log "Site ${CHECKMK_SITE} is NOT running correctly."
else
    echo -e "${TEXT_GREEN}Checkmk site is running fine.${TEXT_RESET}"
    debug_log "Site ${CHECKMK_SITE} is running fine."
fi

debug_log "---------------------------------"
debug_log "Final cleanup"
debug_log "---------------------------------"
echo -e "${TEXT_GREEN}Update completed and cleanup done!${TEXT_RESET}"
debug_log "Update completed."

final_cleanup
exit 0
