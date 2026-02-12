#!/bin/bash

#######################################
# Checkmk Update Script
# GitHub: https://github.com/KTOrTs/checkmk_update_script
# Version: 1.3.0
#######################################

set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.3.0"
readonly SCRIPT_UPDATE_TIMEOUT=15
readonly BACKUP_DIR="/var/backups/checkmk"
readonly GITHUB_REPO="KTOrTs/checkmk_update_script"
readonly RAW_SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/cmkupdate.sh"
readonly GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
readonly REQUIRED_SPACE_MB=2048

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
SELF_TEST=0
AUTO_YES=0
SITE_WAS_STOPPED=0
CHECKMK_SITE=""
CHECKMK_DIR=""
INSTALLED_VERSION=""
LATEST_VERSION=""
TOTAL_PHASES=7
CURRENT_PHASE=0
BACKUP_FILE_PATH=""
DOWNLOAD_PACKAGE_PATH=""
START_SECONDS=$SECONDS

# ---------------------------------------------------------------------------
# Secure temp directory (unpredictable, restricted permissions)
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d /tmp/cmkupdate.XXXXXXXXXX)
chmod 700 "$TMP_DIR"
DEBUG_LOG_FILE="${TMP_DIR}/checkmk_update_debug.log"
touch "$DEBUG_LOG_FILE"
chmod 600 "$DEBUG_LOG_FILE"

# ---------------------------------------------------------------------------
# Color / formatting (respects NO_COLOR and non-terminal output)
# ---------------------------------------------------------------------------
setup_colors() {
    if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
        TEXT_RESET=''
        TEXT_YELLOW=''
        TEXT_GREEN=''
        TEXT_RED=''
        TEXT_CYAN=''
        TEXT_BOLD=''
        TEXT_DIM=''
    else
        TEXT_RESET='\e[0m'
        TEXT_YELLOW='\e[0;33m'
        TEXT_GREEN='\e[0;32m'
        TEXT_RED='\e[0;31m'
        TEXT_CYAN='\e[0;96m'
        TEXT_BOLD='\e[1m'
        TEXT_DIM='\e[2m'
    fi
}
setup_colors

# ---------------------------------------------------------------------------
# Output helpers with semantic prefixes
# ---------------------------------------------------------------------------
msg_info()    { echo -e "${TEXT_CYAN}[INFO]${TEXT_RESET}    $*"; }
msg_ok()      { echo -e "${TEXT_GREEN}[OK]${TEXT_RESET}      $*"; }
msg_warn()    { echo -e "${TEXT_YELLOW}[WARN]${TEXT_RESET}    $*"; }
msg_error()   { echo -e "${TEXT_RED}[ERROR]${TEXT_RESET}   $*"; }
msg_phase()   {
    CURRENT_PHASE=$((CURRENT_PHASE + 1))
    echo ""
    echo -e "${TEXT_BOLD}==> [${CURRENT_PHASE}/${TOTAL_PHASES}] $*${TEXT_RESET}"
}

# ---------------------------------------------------------------------------
# Debug logging
# ---------------------------------------------------------------------------
debug_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $1" >> "$DEBUG_LOG_FILE"
}

# ---------------------------------------------------------------------------
# Spinner for background operations
# ---------------------------------------------------------------------------
spinner() {
    local pid=$1
    local label="${2:-Working...}"
    local spin_chars='|/-\'
    local i=0

    # Only show spinner on interactive terminals
    if [[ ! -t 1 ]]; then
        wait "$pid"
        return $?
    fi

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${TEXT_DIM}  %s %s${TEXT_RESET}" "${spin_chars:i++%4:1}" "$label"
        sleep 0.3
    done
    printf "\r\033[K"
    wait "$pid"
    return $?
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------
ask_continue_on_error() {
    local error_msg="$1"
    local context="${2:-Continuing may lead to unexpected behavior.}"
    msg_error "$error_msg"
    msg_info "$context"
    msg_info "Debug log: ${DEBUG_LOG_FILE}"

    if (( AUTO_YES )); then
        debug_log "Auto-yes: continuing after error: ${error_msg}"
        return 0
    fi

    while true; do
        read -rp "Do you want to continue? [y/N]: " user_input
        case "${user_input:-N}" in
            [Yy]) debug_log "User chose to continue after: ${error_msg}"; return 0 ;;
            [Nn]|"") debug_log "User aborted after: ${error_msg}"; echo -e "${TEXT_RED}Aborted.${TEXT_RESET}"; exit 1 ;;
            *) echo "Please enter 'y' or 'n'." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Cleanup and trap handling
# ---------------------------------------------------------------------------
final_cleanup() {
    local exit_code=$?

    # Restart the site if we stopped it and it is still down
    if (( SITE_WAS_STOPPED )) && [[ -n "$CHECKMK_SITE" ]]; then
        if ! omd status "$CHECKMK_SITE" &>/dev/null; then
            msg_warn "Restarting site ${CHECKMK_SITE} (was stopped during update)..."
            omd start "$CHECKMK_SITE" &>> "$DEBUG_LOG_FILE" || true
        fi
    fi

    # Remove temp files but preserve the debug log
    if [[ -d "$TMP_DIR" ]]; then
        find "$TMP_DIR" -mindepth 1 -maxdepth 1 ! -name "$(basename "$DEBUG_LOG_FILE")" -exec rm -rf {} + 2>/dev/null || true
    fi

    debug_log "Script exiting with code ${exit_code}."
    return 0
}
trap final_cleanup EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
print_usage() {
    cat <<EOF
${TEXT_BOLD}cmkupdate${TEXT_RESET} - Checkmk Raw Edition update helper (v${SCRIPT_VERSION})

${TEXT_BOLD}Usage:${TEXT_RESET}
  $0 [options]

${TEXT_BOLD}Options:${TEXT_RESET}
  -h, --help        Show this help text and exit
  -t, --self-test   Run dependency and syntax check without performing updates
  -y, --yes         Skip interactive confirmations (use with caution)

${TEXT_BOLD}Examples:${TEXT_RESET}
  sudo $0              Run an interactive update
  sudo $0 --yes        Run an update without confirmation prompts
  $0 --self-test       Verify dependencies are installed
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                print_usage
                exit 0
                ;;
            -t|--self-test)
                SELF_TEST=1
                ;;
            -y|--yes)
                AUTO_YES=1
                ;;
            *)
                msg_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Self-test mode
# ---------------------------------------------------------------------------
run_self_test() {
    debug_log "Running self-test"
    msg_info "Running self-test (syntax and dependency check)..."

    if bash -n "$0"; then
        msg_ok "Syntax check passed."
    else
        msg_error "Syntax check failed. See ${DEBUG_LOG_FILE} for details."
        exit 1
    fi

    local required=(omd lsb_release wget curl dpkg awk grep df sort)
    local missing=()

    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_error "Missing required commands: ${missing[*]}"
        debug_log "Self-test failed. Missing: ${missing[*]}"
        exit 1
    fi

    msg_ok "Self-test succeeded. All required commands are available."
    debug_log "Self-test completed successfully."
    exit 0
}

# ---------------------------------------------------------------------------
# Version comparison helper
# ---------------------------------------------------------------------------
version_gt() {
    [[ $# -eq 2 ]] || return 1
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" != "$1" ]]
}

# Strip edition suffix (.cre, .cee, .cce, .cme) from a version string
strip_edition() {
    echo "$1" | sed -E 's/\.(cre|cee|cce|cme)$//'
}

# ---------------------------------------------------------------------------
# Ensure omd is available
# ---------------------------------------------------------------------------
ensure_omd_available() {
    if ! command -v omd &>/dev/null; then
        msg_error "The 'omd' command is not available."
        msg_info "Please install Checkmk before running this script."
        debug_log "omd not found."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Check and install missing packages
# ---------------------------------------------------------------------------
check_and_install_packages() {
    debug_log "Checking required packages..."

    local required_cmds=("lsb_release" "wget" "curl" "dpkg" "awk" "grep" "df" "sort")
    local missing_packages=()

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            debug_log "Missing command: $cmd"
            case "$cmd" in
                lsb_release) missing_packages+=("lsb-release") ;;
                wget)        missing_packages+=("wget") ;;
                curl)        missing_packages+=("curl") ;;
                dpkg)        missing_packages+=("dpkg") ;;
                awk)         missing_packages+=("gawk") ;;
                grep)        missing_packages+=("grep") ;;
                df|sort)     missing_packages+=("coreutils") ;;
            esac
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        msg_info "Installing missing packages: ${missing_packages[*]}"
        apt-get update -qq &>> "$DEBUG_LOG_FILE"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing_packages[@]}" &>> "$DEBUG_LOG_FILE"
        local apt_exit=$?
        debug_log "apt-get install ${missing_packages[*]} -> Exit code: ${apt_exit}"
        if [[ $apt_exit -ne 0 ]]; then
            ask_continue_on_error \
                "Failed to install required packages (exit code: ${apt_exit})." \
                "Try running 'apt-get update && apt-get install ${missing_packages[*]}' manually."
        else
            msg_ok "Packages installed."
        fi
    else
        msg_ok "All dependencies satisfied."
        debug_log "All required packages present."
    fi
}

# ---------------------------------------------------------------------------
# Check for new script version on GitHub
# ---------------------------------------------------------------------------
check_for_new_script_version() {
    msg_info "Checking for script updates..."
    debug_log "Querying GitHub API for latest release."

    local api_response curl_exit
    api_response=$(curl -s --fail --proto =https --max-time "$SCRIPT_UPDATE_TIMEOUT" "$GITHUB_API_URL" 2>>"$DEBUG_LOG_FILE") || true
    curl_exit=$?
    debug_log "GitHub API curl exit code: ${curl_exit}"

    if [[ $curl_exit -ne 0 ]] || [[ "$api_response" == *"API rate limit exceeded"* ]]; then
        if [[ $curl_exit -eq 28 ]]; then
            msg_warn "Script update check timed out after ${SCRIPT_UPDATE_TIMEOUT}s."
        else
            msg_warn "Could not check for script updates (API limit or connection issue)."
        fi
        return
    fi

    local latest_script_version
    latest_script_version=$(echo "$api_response" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [[ -z "$latest_script_version" ]]; then
        msg_warn "Could not determine latest script version."
        debug_log "Failed to extract version from API response."
        return
    fi

    debug_log "Current: ${SCRIPT_VERSION}, Latest: ${latest_script_version}"

    if version_gt "$latest_script_version" "$SCRIPT_VERSION"; then
        msg_info "New script version available: ${SCRIPT_VERSION} -> ${latest_script_version}"

        if (( AUTO_YES )); then
            debug_log "Auto-yes: skipping self-update."
            return
        fi

        while true; do
            read -rp "Download and update the script? [y/N]: " update_choice
            case "${update_choice:-N}" in
                [Yy])
                    debug_log "User chose to update script to ${latest_script_version}."
                    msg_info "Downloading new version..."
                    local new_script="${TMP_DIR}/cmkupdate.sh.new"
                    if ! curl --fail --proto =https --max-time "$SCRIPT_UPDATE_TIMEOUT" -o "$new_script" "$RAW_SCRIPT_URL" 2>>"$DEBUG_LOG_FILE"; then
                        msg_error "Failed to download the new script version."
                        debug_log "Self-update download failed."
                        return
                    fi
                    # Basic validation: must start with a shebang
                    if ! head -c 2 "$new_script" | grep -q '#!'; then
                        msg_error "Downloaded file does not look like a valid script. Aborting update."
                        debug_log "Self-update validation failed (no shebang)."
                        rm -f "$new_script"
                        return
                    fi
                    local script_path
                    script_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
                    cp "$new_script" "$script_path"
                    chmod +x "$script_path"
                    rm -f "$new_script"
                    msg_ok "Script updated to ${latest_script_version}. Please re-run."
                    debug_log "Self-update successful. Exiting for re-run."
                    exit 0
                    ;;
                [Nn]|"")
                    debug_log "User declined self-update."
                    break
                    ;;
                *)
                    echo "Please enter 'y' or 'n'."
                    ;;
            esac
        done
    else
        msg_ok "Script is up to date (${SCRIPT_VERSION})."
    fi
}

# ---------------------------------------------------------------------------
# Create site backup
# ---------------------------------------------------------------------------
create_site_backup() {
    if ! mkdir -p "$BACKUP_DIR"; then
        ask_continue_on_error \
            "Failed to create backup directory ${BACKUP_DIR}." \
            "Continuing means NO backup will be created."
        return
    fi
    chmod 750 "$BACKUP_DIR" 2>/dev/null || true

    BACKUP_FILE_PATH="${BACKUP_DIR}/${CHECKMK_SITE}_$(date +%Y%m%d_%H%M%S).omd.gz"
    local site_size_kb available_kb site_size_mb

    site_size_kb=$(du -sk "$CHECKMK_DIR" 2>>"$DEBUG_LOG_FILE" | awk '{print $1}')
    available_kb=$(df --output=avail "$BACKUP_DIR" 2>/dev/null | tail -n 1 | tr -d ' ')

    if [[ -n "$site_size_kb" ]]; then
        site_size_mb=$(awk -v kb="$site_size_kb" 'BEGIN { printf "%.0f", kb/1024 }')
    else
        site_size_mb="unknown"
    fi

    debug_log "Site size estimate: ${site_size_kb:-unknown} KB, available: ${available_kb:-unknown} KB"
    msg_info "Estimated site size: ${site_size_mb} MB (uncompressed)"

    if [[ -n "$site_size_kb" && -n "$available_kb" ]] && (( available_kb < site_size_kb )); then
        ask_continue_on_error \
            "Potentially insufficient space for backup in ${BACKUP_DIR}." \
            "Available: $((available_kb / 1024)) MB, site size: ${site_size_mb} MB. Continuing may result in a partial backup."
    fi

    msg_info "Creating backup for site ${CHECKMK_SITE}..."
    omd backup "$CHECKMK_SITE" "$BACKUP_FILE_PATH" &>> "$DEBUG_LOG_FILE" &
    local backup_pid=$!

    # Progress display
    local start_time=$SECONDS
    while kill -0 "$backup_pid" 2>/dev/null; do
        local current_mb="0" pct="" elapsed
        elapsed=$(( SECONDS - start_time ))

        if [[ -f "$BACKUP_FILE_PATH" ]]; then
            local current_bytes
            current_bytes=$(stat -c%s "$BACKUP_FILE_PATH" 2>/dev/null || echo 0)
            current_mb=$(( current_bytes / 1048576 ))
        fi

        if [[ "$site_size_mb" != "unknown" && "$site_size_mb" -gt 0 ]]; then
            pct=$(( current_mb * 100 / site_size_mb ))
            # Compression usually yields < 100%, clamp display
            [[ $pct -gt 99 ]] && pct=99
            printf "\r\033[K  ${TEXT_DIM}Backup: %s MB / ~%s MB (%s%%) | elapsed %dm %ds${TEXT_RESET}" \
                "$current_mb" "$site_size_mb" "$pct" $((elapsed/60)) $((elapsed%60))
        else
            printf "\r\033[K  ${TEXT_DIM}Backup: %s MB | elapsed %dm %ds${TEXT_RESET}" \
                "$current_mb" $((elapsed/60)) $((elapsed%60))
        fi
        sleep 2
    done
    printf "\r\033[K"

    wait "$backup_pid"
    local backup_exit=$?
    debug_log "omd backup -> Exit code: ${backup_exit}; File: ${BACKUP_FILE_PATH}"

    if [[ $backup_exit -ne 0 ]]; then
        BACKUP_FILE_PATH=""
        ask_continue_on_error \
            "Backup failed for ${CHECKMK_SITE} (exit code: ${backup_exit})." \
            "Continuing without a backup means you CANNOT roll back if the update fails."
    else
        local final_mb="0"
        if [[ -f "$BACKUP_FILE_PATH" ]]; then
            local final_bytes
            final_bytes=$(stat -c%s "$BACKUP_FILE_PATH" 2>/dev/null || echo 0)
            final_mb=$(( final_bytes / 1048576 ))
            chmod 640 "$BACKUP_FILE_PATH" 2>/dev/null || true
            debug_log "Backup size: ${final_bytes} bytes (${final_mb} MB)"
        fi
        msg_ok "Backup created: ${BACKUP_FILE_PATH} (${final_mb} MB)"
        msg_info "Restore with: omd restore ${CHECKMK_SITE} ${BACKUP_FILE_PATH}"
    fi
}

# ---------------------------------------------------------------------------
# Detect and select Checkmk site
# ---------------------------------------------------------------------------
detect_site() {
    debug_log "Fetching sites via 'omd sites'..."
    local omd_sites_raw
    if ! omd_sites_raw=$(omd sites 2>&1); then
        msg_error "Failed to query Checkmk sites."
        msg_info "Ensure Checkmk is installed and 'omd sites' works."
        debug_log "omd sites failed: ${omd_sites_raw}"
        exit 1
    fi
    debug_log "omd sites output: ${omd_sites_raw}"

    local sites=()
    mapfile -t sites < <(echo "$omd_sites_raw" | awk '!/^SITE/ && NF {print $1}')
    debug_log "Detected sites: ${sites[*]:-none}"

    if [[ ${#sites[@]} -eq 0 ]]; then
        msg_error "No Checkmk sites found."
        debug_log "No sites detected."
        exit 1
    fi

    if [[ ${#sites[@]} -eq 1 ]]; then
        CHECKMK_SITE="${sites[0]}"
        debug_log "Single site found: ${CHECKMK_SITE}"
    else
        msg_info "Multiple Checkmk sites found. Please select one:"
        select site in "${sites[@]}"; do
            if [[ -n "$site" ]]; then
                CHECKMK_SITE="$site"
                debug_log "User selected site: ${CHECKMK_SITE}"
                break
            else
                echo "Invalid selection. Please enter a valid number."
            fi
        done
    fi

    CHECKMK_DIR="/opt/omd/sites/${CHECKMK_SITE}"
}

# ---------------------------------------------------------------------------
# Get installed version for the selected site
# ---------------------------------------------------------------------------
get_installed_version() {
    local raw_version
    raw_version=$(omd version "$CHECKMK_SITE" 2>/dev/null | awk '{print $NF}')
    INSTALLED_VERSION=$(strip_edition "$raw_version")
    debug_log "Installed version for ${CHECKMK_SITE}: ${raw_version} (stripped: ${INSTALLED_VERSION})"
}

# ---------------------------------------------------------------------------
# Fetch latest available Checkmk version
# ---------------------------------------------------------------------------
fetch_latest_version() {
    msg_info "Checking latest Checkmk version..."
    local tmp_file="${TMP_DIR}/checkmk_versions.html"

    if ! curl -sf --proto =https -o "$tmp_file" "https://checkmk.com/download" 2>>"$DEBUG_LOG_FILE"; then
        ask_continue_on_error \
            "Failed to fetch Checkmk version information." \
            "Check your internet connection and try again."
        return 1
    fi

    LATEST_VERSION=$(grep -oP '(?<=check-mk-raw-)[0-9]+\.[0-9]+\.[0-9]+(?:p[0-9]+)?' "$tmp_file" | sort -V | tail -n 1)
    debug_log "Latest version detected: ${LATEST_VERSION:-none}"
    rm -f "$tmp_file"

    if [[ -z "$LATEST_VERSION" ]]; then
        msg_error "Could not determine the latest Checkmk version."
        debug_log "Version detection failed."
        exit 1
    fi

    # Validate version format
    if ! [[ "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(p[0-9]+)?$ ]]; then
        msg_error "Detected version '${LATEST_VERSION}' has unexpected format."
        debug_log "Version format validation failed: ${LATEST_VERSION}"
        exit 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Check disk space
# ---------------------------------------------------------------------------
check_disk_space() {
    local available_kb
    available_kb=$(df --output=avail /opt/omd/ 2>/dev/null | tail -n 1 | tr -d ' ')
    debug_log "Available on /opt/omd/: ${available_kb:-unknown} KB, required: ${REQUIRED_SPACE_MB} MB"

    if [[ -n "$available_kb" ]] && (( available_kb < REQUIRED_SPACE_MB * 1024 )); then
        ask_continue_on_error \
            "Low disk space on /opt/omd/: $((available_kb / 1024)) MB available, ${REQUIRED_SPACE_MB} MB recommended." \
            "The update may fail if there is not enough space."
    else
        msg_ok "Disk space: $((available_kb / 1024)) MB available."
    fi
}

# ---------------------------------------------------------------------------
# Download and verify update package
# ---------------------------------------------------------------------------
download_update() {
    local distro arch update_package download_url
    distro=$(lsb_release -sc)
    arch=$(dpkg --print-architecture)
    update_package="check-mk-raw-${LATEST_VERSION}_0.${distro}_${arch}.deb"
    download_url="https://download.checkmk.com/checkmk/${LATEST_VERSION}/${update_package}"

    debug_log "Package: ${update_package}"
    debug_log "URL: ${download_url}"

    # Get expected file size
    local content_length
    content_length=$(curl -sI --proto =https "$download_url" 2>>"$DEBUG_LOG_FILE" \
        | awk '/[Cc]ontent-[Ll]ength/ {print $2}' | tr -d '\r')

    if [[ -n "$content_length" ]]; then
        msg_info "Expected download size: $(( content_length / 1048576 )) MB"
        debug_log "Expected size: ${content_length} bytes"
    fi

    msg_info "Downloading ${update_package}..."
    DOWNLOAD_PACKAGE_PATH="${TMP_DIR}/${update_package}"
    curl --fail --location --proto =https --progress-bar \
        -o "$DOWNLOAD_PACKAGE_PATH" "$download_url" 2>&1
    local curl_exit=$?

    if [[ $curl_exit -ne 0 ]]; then
        debug_log "Download failed: curl exit code ${curl_exit}"
        DOWNLOAD_PACKAGE_PATH=""
        ask_continue_on_error \
            "Download failed (exit code: ${curl_exit})." \
            "Check the URL ${download_url} and your internet connection."
        return 1
    fi

    if [[ ! -s "$DOWNLOAD_PACKAGE_PATH" ]]; then
        debug_log "Download produced empty file."
        DOWNLOAD_PACKAGE_PATH=""
        ask_continue_on_error \
            "Download finished but the package file is empty." \
            "The download server may be experiencing issues."
        return 1
    fi

    local downloaded_mb
    downloaded_mb=$(( $(stat -c%s "$DOWNLOAD_PACKAGE_PATH") / 1048576 ))
    msg_ok "Download complete: ${downloaded_mb} MB"

    # Attempt SHA256 verification
    local checksum_url="https://download.checkmk.com/checkmk/${LATEST_VERSION}/${update_package}.sha256"
    local checksum_file="${TMP_DIR}/${update_package}.sha256"

    if curl -sf --proto =https --max-time 15 -o "$checksum_file" "$checksum_url" 2>>"$DEBUG_LOG_FILE"; then
        local expected_hash actual_hash
        expected_hash=$(awk '{print $1}' "$checksum_file")
        actual_hash=$(sha256sum "$DOWNLOAD_PACKAGE_PATH" | awk '{print $1}')
        debug_log "Expected SHA256: ${expected_hash}"
        debug_log "Actual SHA256:   ${actual_hash}"

        if [[ "$expected_hash" == "$actual_hash" ]]; then
            msg_ok "SHA256 checksum verified."
        else
            msg_error "SHA256 checksum mismatch!"
            msg_info "Expected: ${expected_hash}"
            msg_info "Got:      ${actual_hash}"
            ask_continue_on_error \
                "Package integrity check failed." \
                "The downloaded file may be corrupted or tampered with. Continuing is NOT recommended."
        fi
        rm -f "$checksum_file"
    else
        msg_warn "SHA256 checksum not available from server. Skipping verification."
        debug_log "Checksum file not available at ${checksum_url}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Install the .deb package
# ---------------------------------------------------------------------------
install_package() {
    local package_path="$1"
    msg_info "Installing update package..."

    dpkg -i "$package_path" &>> "$DEBUG_LOG_FILE" &
    local dpkg_pid=$!
    spinner "$dpkg_pid" "Installing package..."
    local dpkg_exit=$?

    debug_log "dpkg -i -> Exit code: ${dpkg_exit}"
    if [[ $dpkg_exit -ne 0 ]]; then
        ask_continue_on_error \
            "Package installation failed (exit code: ${dpkg_exit})." \
            "Check the debug log for details. You may need to run 'apt-get -f install' to fix dependencies."
    else
        msg_ok "Package installed."
    fi
}

# ---------------------------------------------------------------------------
# Print banner
# ---------------------------------------------------------------------------
print_banner() {
    echo -e "${TEXT_BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║      Checkmk Update Script v${SCRIPT_VERSION}       ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${TEXT_RESET}"
    msg_info "Debug log: ${DEBUG_LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Print pre-update confirmation
# ---------------------------------------------------------------------------
confirm_update() {
    echo ""
    echo -e "${TEXT_BOLD}  Update Summary${TEXT_RESET}"
    echo    "  ──────────────────────────────────────────"
    printf  "  %-22s %s\n" "Site:" "$CHECKMK_SITE"
    printf  "  %-22s %s\n" "Current version:" "$INSTALLED_VERSION"
    printf  "  %-22s %s\n" "Target version:" "$LATEST_VERSION"
    printf  "  %-22s %s\n" "Backup location:" "$BACKUP_DIR"
    echo    "  ──────────────────────────────────────────"
    echo ""
    msg_warn "The site will be STOPPED during the update."

    if (( AUTO_YES )); then
        debug_log "Auto-yes: proceeding with update."
        return 0
    fi

    while true; do
        read -rp "Proceed with update? [y/N]: " confirm
        case "${confirm:-N}" in
            [Yy]) debug_log "User confirmed update."; return 0 ;;
            [Nn]|"") msg_info "Update cancelled."; exit 0 ;;
            *) echo "Please enter 'y' or 'n'." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Print completion summary
# ---------------------------------------------------------------------------
print_summary() {
    local new_version elapsed_s elapsed_m elapsed_sec
    new_version=$(omd version "$CHECKMK_SITE" 2>/dev/null | awk '{print $NF}')
    elapsed_s=$(( SECONDS - START_SECONDS ))
    elapsed_m=$(( elapsed_s / 60 ))
    elapsed_sec=$(( elapsed_s % 60 ))

    local site_status site_status_text
    if omd status "$CHECKMK_SITE" &>/dev/null; then
        site_status_text="${TEXT_GREEN}Running${TEXT_RESET}"
    else
        site_status_text="${TEXT_RED}NOT running${TEXT_RESET}"
    fi

    echo ""
    echo -e "${TEXT_BOLD}  ╔══════════════════════════════════════════╗"
    echo -e "  ║            Update Complete                ║"
    echo -e "  ╚══════════════════════════════════════════╝${TEXT_RESET}"
    echo    "  ──────────────────────────────────────────"
    printf  "  %-22s %s\n" "Site:" "$CHECKMK_SITE"
    printf  "  %-22s %s\n" "Previous version:" "$INSTALLED_VERSION"
    printf  "  %-22s %s\n" "New version:" "${new_version:-unknown}"
    if [[ -n "$BACKUP_FILE_PATH" && -f "$BACKUP_FILE_PATH" ]]; then
        local backup_mb
        backup_mb=$(( $(stat -c%s "$BACKUP_FILE_PATH" 2>/dev/null || echo 0) / 1048576 ))
        printf  "  %-22s %s (%s MB)\n" "Backup:" "$BACKUP_FILE_PATH" "$backup_mb"
    else
        printf  "  %-22s %s\n" "Backup:" "none"
    fi
    echo -ne "  "; printf "%-22s " "Site status:"; echo -e "$site_status_text"
    printf  "  %-22s %dm %ds\n" "Duration:" "$elapsed_m" "$elapsed_sec"
    printf  "  %-22s %s\n" "Debug log:" "$DEBUG_LOG_FILE"
    echo    "  ──────────────────────────────────────────"
    echo ""
}

# ===========================================================================
# MAIN
# ===========================================================================

debug_log "Script start (v${SCRIPT_VERSION})"
parse_args "$@"

# Self-test exits early
if (( SELF_TEST )); then
    run_self_test
fi

# --- Root check (before anything else that modifies system state) ----------
if (( EUID != 0 )); then
    msg_error "This script must be run as root. Current user: $(whoami)"
    msg_info "Run with: sudo $0"
    exit 1
fi

# --- Banner ----------------------------------------------------------------
print_banner

# --- Phase 1: Prerequisites -----------------------------------------------
msg_phase "Checking prerequisites"
ensure_omd_available
check_and_install_packages

# --- Phase 2: Script update check -----------------------------------------
msg_phase "Checking for updates"
check_for_new_script_version

# --- Phase 3: Site detection and version check -----------------------------
msg_phase "Detecting Checkmk site"
detect_site
get_installed_version
check_disk_space

# Fetch latest version
fetch_latest_version

msg_info "Installed: ${INSTALLED_VERSION}"
msg_info "Available: ${LATEST_VERSION}"

if [[ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]]; then
    msg_ok "Checkmk is already up to date."
    debug_log "Already up to date."
    exit 0
fi

# --- Confirmation ----------------------------------------------------------
confirm_update

# --- Phase 4: Backup ------------------------------------------------------
msg_phase "Creating backup"
msg_info "Stopping site ${CHECKMK_SITE} for consistent backup..."
omd stop "$CHECKMK_SITE" &>> "$DEBUG_LOG_FILE" &
local_pid=$!
spinner "$local_pid" "Stopping site..."
stop_exit=$?
SITE_WAS_STOPPED=1
debug_log "omd stop -> Exit code: ${stop_exit}"

if [[ $stop_exit -ne 0 ]]; then
    ask_continue_on_error \
        "Failed to stop site (exit code: ${stop_exit})." \
        "The backup may be inconsistent if the site is still running."
else
    msg_ok "Site stopped."
fi

create_site_backup

# --- Phase 5: Download ----------------------------------------------------
msg_phase "Downloading update"
download_update
download_exit=$?

if [[ $download_exit -ne 0 || -z "$DOWNLOAD_PACKAGE_PATH" || ! -s "$DOWNLOAD_PACKAGE_PATH" ]]; then
    ask_continue_on_error \
        "No valid package available for installation." \
        "The update cannot proceed without a valid package."
    exit 1
fi

# --- Phase 6: Install and update ------------------------------------------
msg_phase "Installing update"
install_package "$DOWNLOAD_PACKAGE_PATH"

msg_info "Running omd update for ${CHECKMK_SITE}..."
omd update "$CHECKMK_SITE" 2>&1 | tee -a "$DEBUG_LOG_FILE"
update_exit=${PIPESTATUS[0]}

if [[ $update_exit -ne 0 ]]; then
    ask_continue_on_error \
        "omd update failed (exit code: ${update_exit})." \
        "Check the debug log. You may need to run 'omd update ${CHECKMK_SITE}' manually."
else
    msg_ok "omd update completed."
fi

# --- Phase 7: Verification ------------------------------------------------
msg_phase "Verifying and starting site"

msg_info "Starting site ${CHECKMK_SITE}..."
omd start "$CHECKMK_SITE" &>> "$DEBUG_LOG_FILE" &
local_pid=$!
spinner "$local_pid" "Starting site..."
start_exit=$?
debug_log "omd start -> Exit code: ${start_exit}"

if [[ $start_exit -ne 0 ]]; then
    ask_continue_on_error \
        "Failed to start site (exit code: ${start_exit})." \
        "Try starting manually: omd start ${CHECKMK_SITE}"
else
    SITE_WAS_STOPPED=0
    msg_ok "Site started."
fi

msg_info "Running omd cleanup..."
omd cleanup &>> "$DEBUG_LOG_FILE" || true

# --- Summary ---------------------------------------------------------------
print_summary
exit 0
