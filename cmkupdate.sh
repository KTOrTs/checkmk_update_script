#!/bin/bash

#######################################
# Checkmk Update Script
# GitHub: https://github.com/KTOrTs/checkmk_update_script
# Version: 1.4.0
#######################################

set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.4.0"
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
UI_MODE="on"   # on|off (on by default; --no-ui disables for this run)
UI_ENABLED=0
DRY_RUN=0
SKIP_BACKUP=0
SITE_WAS_STOPPED=0
SITE_WAS_RUNNING_INITIAL=0
CHECKMK_SITE=""
CHECKMK_DIR=""
INSTALLED_VERSION=""
INSTALLED_VERSION_RAW=""
INSTALLED_EDITION=""
LATEST_VERSION=""
TOTAL_PHASES=7
CURRENT_PHASE=0
BACKUP_FILE_PATH=""
DOWNLOAD_PACKAGE_PATH=""
UPDATE_PACKAGE=""
DOWNLOAD_URL=""
DOWNLOAD_CONTENT_LENGTH=""
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
# TUI (based on tui_concept.sh)
# ---------------------------------------------------------------------------
setup_colors() {
    if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
        C_RESET='' C_BOLD='' C_DIM=''
        C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_WHITE='' C_BLUE=''
    else
        C_RESET=$'\e[0m'
        C_BOLD=$'\e[1m'
        C_DIM=$'\e[2m'

        C_CYAN=$'\e[96m'
        C_GREEN=$'\e[92m'
        C_YELLOW=$'\e[93m'
        C_RED=$'\e[91m'
        C_WHITE=$'\e[97m'
        C_BLUE=$'\e[94m'
    fi
}
setup_colors

ui_init() {
    UI_ENABLED=0
    if [[ "${UI_MODE:-on}" == "off" ]]; then
        return 0
    fi
    [[ -t 1 ]] || return 0
    UI_ENABLED=1
}

# --- Box drawing + icons ----------------------------------------------------
readonly BOX_DTL='╔' BOX_DTR='╗' BOX_DBL='╚' BOX_DBR='╝'
readonly BOX_DH='═' BOX_DV='║'
readonly BOX_TL='┌' BOX_TR='┐' BOX_BL='└' BOX_BR='┘'
readonly BOX_H='─' BOX_V='│'
readonly BOX_LT='├' BOX_RT='┤'
readonly BOX_RTL='╭' BOX_RTR='╮' BOX_RBL='╰' BOX_RBR='╯'

readonly SYM_CHECK='✓'
readonly SYM_CROSS='✗'
readonly SYM_ARROW='▸'
readonly SYM_DOT='●'
readonly SYM_CIRCLE='○'
readonly SYM_WARN='▲'
readonly SYM_DASH='─'
readonly SYM_ELLIPSIS='…'
readonly SYM_BULLET='•'

readonly BAR_FULL='█'
readonly BAR_7='▉'
readonly BAR_6='▊'
readonly BAR_5='▋'
readonly BAR_4='▌'
readonly BAR_3='▍'
readonly BAR_2='▎'
readonly BAR_1='▏'
readonly BAR_EMPTY='░'

readonly SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# --- Layout helpers ---------------------------------------------------------
get_term_width() {
    local width
    width=$(tput cols 2>/dev/null) || width=80
    (( width < 60 )) && width=60
    echo "$width"
}

draw_line() {
    local char="${1:-$BOX_H}" width="${2:-$(get_term_width)}" color="${3:-$C_DIM}"
    printf '%s' "$color"
    printf '%*s' "$width" '' | tr ' ' "$char"
    printf '%s\n' "$C_RESET"
}

left_right() {
    local left="$1" right="$2" width="${3:-$(get_term_width)}"
    local clean_left clean_right
    clean_left=$(echo -e "$left" | sed 's/\x1b\[[0-9;]*m//g')
    clean_right=$(echo -e "$right" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$(( width - ${#clean_left} - ${#clean_right} ))
    (( pad < 0 )) && pad=1
    printf '%s%*s%s\n' "$left" "$pad" '' "$right"
}

# --- Header -----------------------------------------------------------------
print_header() {
    local version="${1:-$SCRIPT_VERSION}"
    local width inner
    width=$(get_term_width)
    inner=$(( width - 4 ))

    local title="Checkmk Update"
    local ver_str="v${version}"
    local title_len=${#title}
    local ver_len=${#ver_str}
    local space_between=$(( inner - title_len - ver_len - 2 ))
    (( space_between < 1 )) && space_between=1

    echo ""
    printf '  %s%s%s%s%s\n' "$C_BOLD" "$BOX_DTL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_DH")" "$BOX_DTR" "$C_RESET"
    printf '  %s%s%s %s%s%s%*s%s%s %s%s\n' \
        "$C_BOLD" "$BOX_DV" \
        "$C_CYAN" "$title" "$C_RESET" "$C_BOLD" \
        "$space_between" '' \
        "$C_DIM" "$ver_str" \
        "$BOX_DV" "$C_RESET"
    printf '  %s%s%s%s%s\n' "$C_BOLD" "$BOX_DBL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_DH")" "$BOX_DBR" "$C_RESET"
}

# --- Phase tracker ----------------------------------------------------------
declare -a PHASE_NAMES=(
    "Prerequisites"
    "Script Update"
    "Site Detection"
    "Backup"
    "Download"
    "Install"
    "Verify"
)
declare -a PHASE_STATUS=()  # pending|active|done|error|skipped
declare -a PHASE_DETAIL=()
CURRENT_PHASE_IDX=-1
TOTAL_PHASES=${#PHASE_NAMES[@]}

init_phases() {
    PHASE_STATUS=()
    PHASE_DETAIL=()
    local i
    for (( i=0; i<TOTAL_PHASES; i++ )); do
        PHASE_STATUS+=("pending")
        PHASE_DETAIL+=("")
    done
    CURRENT_PHASE_IDX=-1
}

render_phase_compact() {
    local line="" i
    for (( i=0; i<TOTAL_PHASES; i++ )); do
        case "${PHASE_STATUS[$i]}" in
            done)    line+="${C_GREEN}${SYM_CHECK}${C_RESET} " ;;
            active)  line+="${C_CYAN}${C_BOLD}${SYM_DOT}${C_RESET} " ;;
            error)   line+="${C_RED}${SYM_CROSS}${C_RESET} " ;;
            skipped) line+="${C_DIM}${SYM_DASH}${C_RESET} " ;;
            *)       line+="${C_DIM}${SYM_CIRCLE}${C_RESET} " ;;
        esac

        case "${PHASE_STATUS[$i]}" in
            active) line+="${C_BOLD}${PHASE_NAMES[$i]}${C_RESET}" ;;
            *)      line+="${C_DIM}${PHASE_NAMES[$i]}${C_RESET}" ;;
        esac

        (( i < TOTAL_PHASES - 1 )) && line+="  "
    done
    echo ""
    echo "  $line"
}

render_phase_tracker() {
    local mode="${1:-compact}"
    (( UI_ENABLED )) || return 0

    if [[ "$mode" == "compact" ]]; then
        render_phase_compact
        return 0
    fi

    local width
    width=$(get_term_width)

    local inner=$(( width - 6 ))  # Rahmen + Padding

    echo ""
    printf '  %s%s%s%s\n' "$C_DIM" "$BOX_TL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_TR$C_RESET"

    local i
    for (( i=0; i<TOTAL_PHASES; i++ )); do
        local icon color name detail
        name="${PHASE_NAMES[$i]}"

        case "${PHASE_STATUS[$i]}" in
            done)
                icon="${C_GREEN}${SYM_CHECK}${C_RESET}"
                color="$C_DIM"
                detail="${PHASE_DETAIL[$i]}"
                ;;
            active)
                icon="${C_CYAN}${SYM_ARROW}${C_RESET}"
                color="${C_BOLD}${C_WHITE}"
                detail="${PHASE_DETAIL[$i]}"
                ;;
            error)
                icon="${C_RED}${SYM_CROSS}${C_RESET}"
                color="$C_RED"
                detail="${PHASE_DETAIL[$i]}"
                ;;
            skipped)
                icon="${C_DIM}${SYM_DASH}${C_RESET}"
                color="$C_DIM"
                detail="skipped"
                ;;
            *)
                icon="${C_DIM}${SYM_CIRCLE}${C_RESET}"
                color="$C_DIM"
                detail=""
                ;;
        esac

        local name_col detail_col
        name_col=$(printf '%-20s' "$name")

        if [[ -n "$detail" ]]; then
            local avail=$(( inner - 20 - 6 ))  # 20 Name, 6 Icon+Spacing
            if (( ${#detail} > avail )); then
                detail="${detail:0:$((avail-1))}${SYM_ELLIPSIS}"
            fi
            detail_col="${C_DIM}${detail}${C_RESET}"
        else
            detail_col=""
        fi

        printf '  %s%s%s  %s  %s%s%s  %s' \
            "$C_DIM" "$BOX_V" "$C_RESET" \
            "$icon" \
            "$color" "$name_col" "$C_RESET" \
            "$detail_col"

        # Rechten Rand auffuellen (ANSI-Codes beim Messen ignorieren)
        local printed
        printed=$(printf '  %s  %s  %s  %s' "$BOX_V" "X" "$name_col" "$detail" | sed 's/\x1b\[[0-9;]*m//g')
        local pad=$(( width - 3 - ${#printed} ))
        (( pad < 0 )) && pad=0
        printf '%*s%s%s%s\n' "$pad" '' "$C_DIM" "$BOX_V" "$C_RESET"
    done

    printf '  %s%s%s%s\n' "$C_DIM" "$BOX_BL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_BR$C_RESET"
}

start_phase() {
    local detail="${1:-}"
    CURRENT_PHASE_IDX=$(( CURRENT_PHASE_IDX + 1 ))
    PHASE_STATUS[$CURRENT_PHASE_IDX]="active"
    PHASE_DETAIL[$CURRENT_PHASE_IDX]="$detail"
    render_phase_tracker "expanded"
}

end_phase() {
    local status="${1:-done}" detail="${2:-}"
    if (( CURRENT_PHASE_IDX >= 0 && CURRENT_PHASE_IDX < TOTAL_PHASES )); then
        PHASE_STATUS[$CURRENT_PHASE_IDX]="$status"
        [[ -n "$detail" ]] && PHASE_DETAIL[$CURRENT_PHASE_IDX]="$detail"
    fi
}

phase_start() {
    local detail="$1"
    if (( UI_ENABLED )); then
        start_phase "$detail"
    else
        CURRENT_PHASE=$(( CURRENT_PHASE + 1 ))
        echo ""
        echo -e "${C_BOLD}==> [${CURRENT_PHASE}/${TOTAL_PHASES}] ${detail}${C_RESET}"
    fi
}

phase_end() {
    local status="${1:-done}" detail="${2:-}"
    if (( UI_ENABLED )); then
        end_phase "$status" "$detail"
    fi
}

# --- Messages ---------------------------------------------------------------
msg_info() {
    if (( UI_ENABLED )); then
        printf '  %s %s%s%s\n' "${C_CYAN}${SYM_BULLET}${C_RESET}" "$C_RESET" "$*" "$C_RESET"
    else
        echo -e "${C_CYAN}[INFO]${C_RESET}    $*"
    fi
}

msg_ok() {
    if (( UI_ENABLED )); then
        printf '  %s %s%s\n' "${C_GREEN}${SYM_CHECK}${C_RESET}" "$*" "$C_RESET"
    else
        echo -e "${C_GREEN}[OK]${C_RESET}      $*"
    fi
}

msg_warn() {
    if (( UI_ENABLED )); then
        printf '  %s %s%s%s\n' "${C_YELLOW}${SYM_WARN}${C_RESET}" "${C_YELLOW}" "$*" "$C_RESET"
    else
        echo -e "${C_YELLOW}[WARN]${C_RESET}    $*"
    fi
}

msg_error() {
    if (( UI_ENABLED )); then
        printf '  %s %s%s%s\n' "${C_RED}${SYM_CROSS}${C_RESET}" "${C_RED}" "$*" "$C_RESET"
    else
        echo -e "${C_RED}[ERROR]${C_RESET}   $*"
    fi
}

msg_detail() {
    if (( UI_ENABLED )); then
        printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"
    else
        echo "  $*"
    fi
}

# --- Debug logging ----------------------------------------------------------
debug_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $1" >> "$DEBUG_LOG_FILE"
}

# --- Progress ---------------------------------------------------------------
draw_progress_bar() {
    local percent="${1:-0}" label="${2:-}" bar_width="${3:-30}"
    (( percent > 100 )) && percent=100
    (( percent < 0 )) && percent=0

    local filled=$(( percent * bar_width / 100 ))
    local remainder=$(( (percent * bar_width * 8 / 100) % 8 ))
    local empty=$(( bar_width - filled - (remainder > 0 ? 1 : 0) ))

    local bar_color="$C_CYAN"
    (( percent >= 100 )) && bar_color="$C_GREEN"

    local bar=""
    (( filled > 0 )) && bar+=$(printf '%*s' "$filled" '' | tr ' ' "$BAR_FULL")
    if (( remainder > 0 )); then
        case $remainder in
            1) bar+="$BAR_1" ;; 2) bar+="$BAR_2" ;; 3) bar+="$BAR_3" ;;
            4) bar+="$BAR_4" ;; 5) bar+="$BAR_5" ;; 6) bar+="$BAR_6" ;;
            7) bar+="$BAR_7" ;;
        esac
    fi
    (( empty > 0 )) && bar+=$(printf '%*s' "$empty" '' | tr ' ' "$BAR_EMPTY")

    printf '\r\033[K  %s%s%s  %s%3d%%%s' \
        "$bar_color" "$bar" "$C_RESET" \
        "$C_BOLD" "$percent" "$C_RESET"

    if [[ -n "$label" ]]; then
        printf '  %s%s%s' "$C_DIM" "$label" "$C_RESET"
    fi
}

draw_progress_bytes() {
    local current="${1:-0}" total="${2:-0}" label="${3:-}"
    local percent=0
    local current_mb total_mb

    current_mb=$(( current / 1048576 ))
    total_mb=$(( total / 1048576 ))
    if (( total > 0 )); then
        percent=$(( current * 100 / total ))
    fi

    local width bar_width=30
    width=$(get_term_width)
    (( width < 100 )) && bar_width=20
    (( width < 80 )) && bar_width=15

    draw_progress_bar "$percent" "" "$bar_width"

    if (( total > 0 )); then
        printf '  %s%s / %s MB%s' "$C_DIM" "$current_mb" "$total_mb" "$C_RESET"
    else
        printf '  %s%s MB%s' "$C_DIM" "$current_mb" "$C_RESET"
    fi

    [[ -n "$label" ]] && printf '  %s%s%s' "$C_DIM" "$label" "$C_RESET"
}

# --- Spinner ----------------------------------------------------------------
spinner_enhanced() {
    local pid=$1
    local label="${2:-Working...}"
    local frame=0
    local start_time=$SECONDS

    if (( ! UI_ENABLED )); then
        wait "$pid"
        return $?
    fi

    printf '\e[?25l'

    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( SECONDS - start_time ))
        local elapsed_str
        if (( elapsed >= 60 )); then
            elapsed_str="$(( elapsed / 60 ))m $(( elapsed % 60 ))s"
        else
            elapsed_str="${elapsed}s"
        fi

        printf '\r\033[K  %s%s%s %s  %s%s%s' \
            "$C_CYAN" "${SPINNER_FRAMES[$frame]}" "$C_RESET" \
            "$label" \
            "$C_DIM" "$elapsed_str" "$C_RESET"

        frame=$(( (frame + 1) % ${#SPINNER_FRAMES[@]} ))
        sleep 0.1
    done

    printf '\e[?25h'
    printf '\r\033[K'

    wait "$pid"
    return $?
}

spinner() {
    local pid=$1
    local label="${2:-Working...}"
    spinner_enhanced "$pid" "$label"
    return $?
}

# --- Confirmation / menus ---------------------------------------------------
confirm_dialog() {
    local title="$1"
    local message="$2"
    local default="${3:-n}"

    if (( AUTO_YES )); then
        debug_log "Auto-yes: confirm '${title}' -> yes"
        return 0
    fi

    if (( ! UI_ENABLED )); then
        local prompt
        if [[ "$default" == "y" ]]; then
            prompt="Continue? [Y/n]: "
        else
            prompt="Continue? [y/N]: "
        fi

        while true; do
            read -rp "$prompt" user_input || user_input=""
            case "${user_input:-$default}" in
                [Yy]) return 0 ;;
                [Nn]) return 1 ;;
                *) echo "Please enter 'y' or 'n'." ;;
            esac
        done
    fi

    local width inner
    width=$(get_term_width)
    inner=$(( width - 8 ))
    (( inner > 66 )) && inner=66

    echo ""
    printf '  %s%s%s%s\n' "$C_YELLOW" "$BOX_RTL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_RTR$C_RESET"
    printf '  %s%s%s  %s%s%s%*s%s%s\n' \
        "$C_YELLOW" "$BOX_V" "$C_RESET" \
        "${C_BOLD}${C_YELLOW}${SYM_WARN} " "$title" "$C_RESET" \
        $(( inner - ${#title} - 4 )) '' \
        "$C_YELLOW" "$BOX_V$C_RESET"

    # Word wrap message (rough, ASCII-focused)
    local words=($message)
    local line="" word
    local line_max=$(( inner - 4 ))
    printf '  %s%s%s  ' "$C_YELLOW" "$BOX_V" "$C_RESET"
    for word in "${words[@]}"; do
        if (( ${#line} + ${#word} + 1 > line_max )); then
            printf '%s%*s%s%s\n' "$line" $(( inner - ${#line} - 2 )) '' "$C_YELLOW" "$BOX_V$C_RESET"
            printf '  %s%s%s  ' "$C_YELLOW" "$BOX_V" "$C_RESET"
            line="$word"
        else
            [[ -n "$line" ]] && line+=" "
            line+="$word"
        fi
    done
    printf '%s%*s%s%s\n' "$line" $(( inner - ${#line} - 2 )) '' "$C_YELLOW" "$BOX_V$C_RESET"
    printf '  %s%s%s%s\n' "$C_YELLOW" "$BOX_RBL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_RBR$C_RESET"

    local prompt_text
    if [[ "$default" == "y" ]]; then
        prompt_text="  ${C_BOLD}Continue? [Y/n]:${C_RESET} "
    else
        prompt_text="  ${C_BOLD}Continue? [y/N]:${C_RESET} "
    fi

    while true; do
        printf '%b' "$prompt_text"
        read -r user_input || user_input=""
        case "${user_input:-$default}" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) printf '  %s\n' "Please enter 'y' or 'n'." ;;
        esac
    done
}

site_selection_menu() {
    local -a sites=("$@")
    local count=${#sites[@]}

    (( count > 0 )) || return 1

    local selected=-1

    # Print the UI to stderr so command substitution only captures the final choice.
    if (( UI_ENABLED )); then
        {
            local width inner
            width=$(get_term_width)
            inner=$(( width - 8 ))
            (( inner > 60 )) && inner=60

            echo ""
            printf '  %s%s%s%s\n' "$C_DIM" "$BOX_TL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_TR$C_RESET"
            printf '  %s%s%s  %s%s%s\n' \
                "$C_DIM" "$BOX_V" "$C_RESET" \
                "${C_BOLD}Select Checkmk Site${C_RESET}" \
                "$(printf '%*s' $(( inner - 21 )) '')" \
                "$C_DIM$BOX_V$C_RESET"
            printf '  %s%s%s%s\n' "$C_DIM" "$BOX_LT" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_RT$C_RESET"

            local i
            for (( i=0; i<count; i++ )); do
                local site_name="${sites[$i]}"
                local num=$(( i + 1 ))
                printf '  %s%s%s  %s%s%d%s  %s' \
                    "$C_DIM" "$BOX_V" "$C_RESET" \
                    "$C_CYAN" "$C_BOLD" "$num" "$C_RESET" \
                    "$site_name"
                local pad=$(( inner - ${#site_name} - 6 ))
                (( pad < 0 )) && pad=0
                printf '%*s%s%s\n' "$pad" '' "$C_DIM" "$BOX_V$C_RESET"
            done

            printf '  %s%s%s%s\n' "$C_DIM" "$BOX_BL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_BR$C_RESET"

            echo ""
            while (( selected < 1 || selected > count )); do
                printf '  %s%s%s ' "${C_BOLD}" "Enter number [1-${count}]:" "$C_RESET"
                read -r selected || selected=-1
                if ! [[ "$selected" =~ ^[0-9]+$ ]] || (( selected < 1 || selected > count )); then
                    msg_warn "Invalid selection. Please enter a number between 1 and ${count}."
                    selected=-1
                fi
            done
        } >&2
    else
        {
            echo ""
            echo "Multiple Checkmk sites found:"
            local i
            for (( i=0; i<count; i++ )); do
                printf '  %d) %s\n' $(( i + 1 )) "${sites[$i]}"
            done
            echo ""
            while (( selected < 1 || selected > count )); do
                printf 'Enter number [1-%d]: ' "$count"
                read -r selected || selected=-1
                if ! [[ "$selected" =~ ^[0-9]+$ ]] || (( selected < 1 || selected > count )); then
                    echo "Invalid selection. Please enter a number between 1 and ${count}."
                    selected=-1
                fi
            done
        } >&2
    fi

    echo "${sites[$(( selected - 1 ))]}"
}

print_update_summary() {
    local site="$1" current_ver="$2" target_ver="$3" backup_text="$4"

    if (( ! UI_ENABLED )); then
        echo ""
        echo -e "${C_BOLD}  Update Summary${C_RESET}"
        echo    "  ──────────────────────────────────────────"
        printf  "  %-22s %s\n" "Site:" "$site"
        printf  "  %-22s %s\n" "Current version:" "$current_ver"
        printf  "  %-22s %s\n" "Target version:" "$target_ver"
        printf  "  %-22s %s\n" "Backup:" "$backup_text"
        echo    "  ──────────────────────────────────────────"
        echo ""
        return 0
    fi

    local width inner
    width=$(get_term_width)
    inner=$(( width - 8 ))
    (( inner > 60 )) && inner=60

    echo ""
    printf '  %s%s%s%s\n' "$C_DIM" "$BOX_TL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_TR$C_RESET"
    printf '  %s%s%s  %s%s\n' \
        "$C_DIM" "$BOX_V" "$C_RESET" \
        "${C_BOLD}Update Summary${C_RESET}" \
        "$(printf '%*s' $(( inner - 16 )) '')$C_DIM$BOX_V$C_RESET"
    printf '  %s%s%s%s\n' "$C_DIM" "$BOX_LT" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_RT$C_RESET"

    local -a keys=("Site" "Current version" "Target version" "Backup")
    local -a vals=("$site" "$current_ver" "${C_GREEN}${target_ver}${C_RESET}" "$backup_text")
    local i
    for (( i=0; i<${#keys[@]}; i++ )); do
        local key="${keys[$i]}"
        local val="${vals[$i]}"
        local clean_val
        clean_val=$(echo -e "$val" | sed 's/\x1b\[[0-9;]*m//g')

        printf '  %s%s%s  %s%-18s%s %s' \
            "$C_DIM" "$BOX_V" "$C_RESET" \
            "$C_DIM" "$key" "$C_RESET" \
            "$val"

        local used=$(( 20 + ${#clean_val} ))
        local pad=$(( inner - used ))
        (( pad < 0 )) && pad=0
        printf '%*s%s%s\n' "$pad" '' "$C_DIM" "$BOX_V$C_RESET"
    done

    printf '  %s%s%s%s\n' "$C_DIM" "$BOX_BL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_BR$C_RESET"
    echo ""
}

print_completion() {
    local site="$1" old_ver="$2" new_ver="$3"
    local backup_path="${4:-none}" duration="${5:-0s}"
    local site_running="${6:-true}"

    if (( ! UI_ENABLED )); then
        echo ""
        echo -e "${C_BOLD}Update Complete${C_RESET}"
        printf '  %-20s %s\n' "Site:" "$site"
        printf '  %-20s %s -> %s\n' "Version:" "$old_ver" "$new_ver"
        printf '  %-20s %s\n' "Backup:" "$backup_path"
        printf '  %-20s %s\n' "Duration:" "$duration"
        printf '  %-20s %s\n' "Status:" "$site_running"
        echo ""
        return 0
    fi

    local width inner
    width=$(get_term_width)
    inner=$(( width - 6 ))
    (( inner > 64 )) && inner=64

    echo ""
    echo ""

    printf '  %s%s%s%s\n' "$C_GREEN" "$BOX_DTL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_DH")" "$BOX_DTR$C_RESET"

    local success_text="Update Complete"
    local success_pad=$(( (inner - ${#success_text}) / 2 ))
    printf '  %s%s%s%*s%s%s%s%*s%s%s\n' \
        "$C_GREEN" "$BOX_DV" "$C_RESET" \
        "$success_pad" '' \
        "${C_BOLD}${C_GREEN}" "$success_text" "$C_RESET" \
        $(( inner - success_pad - ${#success_text} )) '' \
        "$C_GREEN" "$BOX_DV$C_RESET"

    printf '  %s%s%s%s\n' "$C_GREEN" "$BOX_DBL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_DH")" "$BOX_DBR$C_RESET"
    echo ""

    local status_text
    if [[ "$site_running" == "true" ]]; then
        status_text="${C_GREEN}${SYM_CHECK}${C_RESET} ${C_GREEN}Running${C_RESET}"
    else
        status_text="${C_RED}${SYM_CROSS}${C_RESET} ${C_RED}NOT Running${C_RESET}"
    fi

    printf '  %-20s %s\n' "Site:" "$site"
    printf '  %-20s %s  %s  %s\n' "Version:" "$old_ver" "${C_DIM}${SYM_ARROW}${C_RESET}" "${C_GREEN}${C_BOLD}${new_ver}${C_RESET}"
    printf '  %-20s %b\n' "Status:" "$status_text"
    printf '  %-20s %s\n' "Duration:" "$duration"

    if [[ "$backup_path" != "none" ]]; then
        printf '  %-20s %s\n' "Backup:" "$backup_path"
        msg_detail "Restore: omd restore ${site} ${backup_path}"
    fi

    echo ""
    draw_line "$BOX_H" "$inner" "$C_DIM"
    echo ""
}

print_error_box() {
    local title="$1"
    local message="$2"
    local hint="${3:-}"

    if (( ! UI_ENABLED )); then
        msg_error "$title: $message"
        [[ -n "$hint" ]] && msg_info "$hint"
        return 0
    fi

    local width inner
    width=$(get_term_width)
    inner=$(( width - 8 ))
    (( inner > 66 )) && inner=66

    echo ""
    printf '  %s%s%s%s\n' "$C_RED" "$BOX_TL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_TR$C_RESET"
    printf '  %s%s  %s%s %s%*s%s\n' \
        "$C_RED" "$BOX_V" \
        "${C_BOLD}${C_RED}${SYM_CROSS} " "$title" "$C_RESET" \
        $(( inner - ${#title} - 4 )) '' \
        "$C_RED$BOX_V$C_RESET"
    printf '  %s%s%s%s\n' "$C_RED" "$BOX_LT" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_RT$C_RESET"
    printf '  %s%s%s  %s%*s%s%s\n' \
        "$C_RED" "$BOX_V" "$C_RESET" \
        "$message" \
        $(( inner - ${#message} - 2 )) '' \
        "$C_RED" "$BOX_V$C_RESET"
    if [[ -n "$hint" ]]; then
        printf '  %s%s%s  %s%s%s%*s%s%s\n' \
            "$C_RED" "$BOX_V" "$C_RESET" \
            "$C_DIM" "$hint" "$C_RESET" \
            $(( inner - ${#hint} - 2 )) '' \
            "$C_RED" "$BOX_V$C_RESET"
    fi
    printf '  %s%s%s%s\n' "$C_RED" "$BOX_BL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_H")" "$BOX_BR$C_RESET"
    echo ""
}

# --- Error handling ---------------------------------------------------------
ask_continue_on_error() {
    local error_msg="$1"
    local context="${2:-Continuing may lead to unexpected behavior.}"

    print_error_box "Error" "$error_msg" "$context"
    msg_detail "Debug log: ${DEBUG_LOG_FILE}"

    if (( AUTO_YES )); then
        debug_log "Auto-yes: continuing after error: ${error_msg}"
        return 0
    fi

    if confirm_dialog "Continue after error?" "${error_msg}  ${context}" "n"; then
        debug_log "User chose to continue after: ${error_msg}"
        return 0
    fi

    debug_log "User aborted after: ${error_msg}"
    msg_error "Aborted."
    exit 1
}

# ---------------------------------------------------------------------------
# Cleanup and trap handling
# ---------------------------------------------------------------------------
final_cleanup() {
    local exit_code=$?

    # Restart the site if we stopped it and it was running when the script began.
    if (( SITE_WAS_STOPPED )) && (( SITE_WAS_RUNNING_INITIAL )) && [[ -n "$CHECKMK_SITE" ]]; then
        if ! omd status "$CHECKMK_SITE" &>/dev/null; then
            msg_warn "Restarting site ${CHECKMK_SITE} (was stopped during update)..."
            omd start "$CHECKMK_SITE" &>> "$DEBUG_LOG_FILE" || true
        fi
    fi

    # Remove temp files but preserve the debug log (and keep the downloaded
    # package for dry-run so the user can inspect/reuse it).
    if [[ -d "$TMP_DIR" ]]; then
        local keep_args=()
        keep_args+=( ! -name "$(basename "$DEBUG_LOG_FILE")" )
        if (( DRY_RUN )) && [[ -n "${DOWNLOAD_PACKAGE_PATH:-}" ]] && [[ "$DOWNLOAD_PACKAGE_PATH" == "$TMP_DIR/"* ]]; then
            keep_args+=( ! -name "$(basename "$DOWNLOAD_PACKAGE_PATH")" )
        fi
        find "$TMP_DIR" -mindepth 1 -maxdepth 1 "${keep_args[@]}" -exec rm -rf {} + 2>/dev/null || true
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
${C_BOLD}cmkupdate${C_RESET} - Checkmk Raw Edition update helper (v${SCRIPT_VERSION})

${C_BOLD}Usage:${C_RESET}
  $0 [options]

${C_BOLD}Options:${C_RESET}
  -h, --help        Show this help text and exit
  -t, --self-test   Run dependency and syntax check without performing updates
  -d, --dry-run     Run checks and download package, but do NOT stop site, backup, install, or update
  -b, --no-backup   Skip the site backup (NOT recommended)
  -y, --yes         Skip interactive confirmations (use with caution)
  --no-ui           Disable the interactive UI for this run

${C_BOLD}Examples:${C_RESET}
  sudo $0              Run an interactive update
  $0 --dry-run         Run a dry-run (no changes)
  sudo $0 --no-backup  Run an update without creating a backup (NOT recommended)
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
            -d|-n|--dry-run)
                DRY_RUN=1
                ;;
            -b|--no-backup)
                SKIP_BACKUP=1
                ;;
            -y|--yes)
                AUTO_YES=1
                ;;
            --no-ui)
                UI_MODE="off"
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

    # Keep this list aligned with commands used throughout the script.
    # (Most basics come from coreutils; 'sed' and 'find' are separate on Debian/Ubuntu.)
    local required=(omd lsb_release curl dpkg awk grep df sort sed find du stat ps tee)
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

    local required_cmds=("lsb_release" "curl" "dpkg" "awk" "grep" "df" "sort" "sed" "find" "du" "stat" "ps" "tee")
    local missing_packages=()

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            debug_log "Missing command: $cmd"
            case "$cmd" in
                lsb_release) missing_packages+=("lsb-release") ;;
                curl)        missing_packages+=("curl") ;;
                dpkg)        missing_packages+=("dpkg") ;;
                awk)         missing_packages+=("gawk") ;;
                grep)        missing_packages+=("grep") ;;
                df|sort|du|stat|tee) missing_packages+=("coreutils") ;;
                sed)         missing_packages+=("sed") ;;
                find)        missing_packages+=("findutils") ;;
                ps)          missing_packages+=("procps") ;;
            esac
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        if (( DRY_RUN )); then
            msg_warn "Missing packages (dry-run will not install): ${missing_packages[*]}"
            debug_log "Dry-run: missing packages: ${missing_packages[*]}"
            return 0
        fi

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
    api_response=$(curl -s --fail --proto =https --max-time "$SCRIPT_UPDATE_TIMEOUT" "$GITHUB_API_URL" 2>>"$DEBUG_LOG_FILE")
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

    local latest_script_tag latest_script_version
    latest_script_tag=$(echo "$api_response" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    latest_script_version="${latest_script_tag#v}"

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

        local update_url
        update_url="https://raw.githubusercontent.com/${GITHUB_REPO}/${latest_script_tag}/cmkupdate.sh"
        debug_log "Self-update URL: ${update_url}"

        if confirm_dialog \
            "Self-update available" \
            "New script version available: ${SCRIPT_VERSION} -> ${latest_script_version}. Download and update the script now?" \
            "n"; then
            debug_log "User chose to update script to ${latest_script_version}."
            msg_info "Downloading new version..."
            local new_script="${TMP_DIR}/cmkupdate.sh.new"
            if ! curl --fail --proto =https --max-time "$SCRIPT_UPDATE_TIMEOUT" -o "$new_script" "$update_url" 2>>"$DEBUG_LOG_FILE"; then
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
            if ! grep -q "SCRIPT_VERSION=\"${latest_script_version}\"" "$new_script"; then
                msg_error "Downloaded file does not match the expected version ${latest_script_version}. Aborting update."
                debug_log "Self-update validation failed (version mismatch)."
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
        fi

        debug_log "User declined self-update."
        return
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

            if (( UI_ENABLED )); then
                local width bar_width=30
                width=$(get_term_width)
                (( width < 100 )) && bar_width=20
                (( width < 80 )) && bar_width=15
                draw_progress_bar "$pct" "Backup ${current_mb} MB / ~${site_size_mb} MB | elapsed $((elapsed/60))m $((elapsed%60))s" "$bar_width"
            else
                printf "\r\033[K  ${C_DIM}Backup: %s MB / ~%s MB (%s%%) | elapsed %dm %ds${C_RESET}" \
                    "$current_mb" "$site_size_mb" "$pct" $((elapsed/60)) $((elapsed%60))
            fi
        else
            printf "\r\033[K  ${C_DIM}Backup: %s MB | elapsed %dm %ds${C_RESET}" \
                "$current_mb" $((elapsed/60)) $((elapsed%60))
        fi
        sleep 2
    done
    printf "\r\033[K"
    (( UI_ENABLED )) && echo ""

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
        CHECKMK_SITE=$(site_selection_menu "${sites[@]}") || CHECKMK_SITE=""
        if [[ -z "$CHECKMK_SITE" ]]; then
            msg_info "No site selected. Exiting."
            exit 0
        fi
        debug_log "User selected site: ${CHECKMK_SITE}"
    fi

    CHECKMK_DIR="/opt/omd/sites/${CHECKMK_SITE}"
}

# ---------------------------------------------------------------------------
# Get installed version for the selected site
# ---------------------------------------------------------------------------
get_installed_version() {
    local raw_version
    raw_version=$(omd version "$CHECKMK_SITE" 2>/dev/null | awk '{print $NF}')
    INSTALLED_VERSION_RAW="$raw_version"
    INSTALLED_VERSION=$(strip_edition "$raw_version")
    if [[ "$raw_version" =~ \.(cre|cee|cce|cme)$ ]]; then
        INSTALLED_EDITION="${BASH_REMATCH[1]}"
    else
        INSTALLED_EDITION=""
    fi
    debug_log "Installed version for ${CHECKMK_SITE}: ${raw_version} (edition: ${INSTALLED_EDITION:-unknown}, stripped: ${INSTALLED_VERSION})"
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

    # Avoid grep -P (PCRE) for portability; extract then strip the prefix.
    LATEST_VERSION=$(
        grep -oE 'check-mk-raw-[0-9]+\.[0-9]+\.[0-9]+(p[0-9]+)?' "$tmp_file" \
            | sed -E 's/^check-mk-raw-//' \
            | sort -V \
            | tail -n 1
    )
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

    if ! [[ "${available_kb:-}" =~ ^[0-9]+$ ]]; then
        msg_warn "Could not determine available disk space on /opt/omd/."
        debug_log "Disk space check: df returned non-numeric value: '${available_kb:-}'"
        return 0
    fi

    if (( available_kb < REQUIRED_SPACE_MB * 1024 )); then
        ask_continue_on_error \
            "Low disk space on /opt/omd/: $((available_kb / 1024)) MB available, ${REQUIRED_SPACE_MB} MB recommended." \
            "The update may fail if there is not enough space."
    else
        msg_ok "Disk space: $((available_kb / 1024)) MB available."
    fi
}

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
check_apt_dpkg_locks() {
    debug_log "Checking for APT/DPKG locks / running package managers..."

    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/cache/apt/archives/lock"
        "/var/lib/apt/lists/lock"
    )

    local lock_holders=""
    local lock_check_method="unknown"
    local locks_busy=0

    # Prefer lslocks (util-linux) because it detects actual locks without extra packages.
    if command -v lslocks &>/dev/null; then
        lock_check_method="lslocks"
        local pid comm path
        while read -r pid comm path _; do
            [[ -n "${pid:-}" ]] || continue
            [[ -n "${path:-}" ]] || continue
            local f
            for f in "${lock_files[@]}"; do
                if [[ "$path" == "$f" ]]; then
                    locks_busy=1
                    lock_holders+="${f}: ${pid} (${comm})"$'\n'
                fi
            done
        done < <(lslocks -n -u -o PID,COMMAND,PATH 2>/dev/null || true)
    elif command -v lsof &>/dev/null; then
        lock_check_method="lsof"
        local f pids
        for f in "${lock_files[@]}"; do
            [[ -e "$f" ]] || continue
            pids=$(lsof -t "$f" 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')
            if [[ -n "$pids" ]]; then
                locks_busy=1
                lock_holders+="${f}: ${pids}"$'\n'
            fi
        done
    elif command -v fuser &>/dev/null; then
        lock_check_method="fuser"
        local f pids
        for f in "${lock_files[@]}"; do
            [[ -e "$f" ]] || continue
            pids=$(fuser "$f" 2>/dev/null | tr ' ' '\n' | awk 'NF{print}' | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')
            if [[ -n "$pids" ]]; then
                locks_busy=1
                lock_holders+="${f}: ${pids}"$'\n'
            fi
        done
    fi

    local proc_matches=""
    local proc_busy=0
    if command -v ps &>/dev/null; then
        proc_matches=$(
            ps -eo pid=,comm=,args= 2>/dev/null \
                | awk '
                    $2 ~ /^(ps|awk|sed)$/ { next }
                    $2 ~ /^(apt|apt-get|dpkg)$/ { print; next }
                    $0 ~ /apt\\.systemd\\.daily/ { print; next }
                    $0 ~ /\/usr\/share\/unattended-upgrades\/unattended-upgrade([^[:alnum:]_-]|$)/ { print; next }
                ' 2>>"$DEBUG_LOG_FILE" \
                | sed -n '1,10p'
        )
        [[ -n "$proc_matches" ]] && proc_busy=1
    fi

    if (( locks_busy )); then
        local context="APT/DPKG appears to be locked.\n\nRecommended action:\n  - Wait for package operations to finish\n  - Then re-run this script"
        context+="\n\nLock holders (method: ${lock_check_method}):\n${lock_holders}"
        if [[ -n "$proc_matches" ]]; then
            context+="\nRunning processes (sample):\n${proc_matches}"
        fi

        debug_log "APT/DPKG busy (method: ${lock_check_method}). Lock holders: ${lock_holders:-none}. Proc sample: ${proc_matches:-none}"

        if (( DRY_RUN )); then
            msg_warn "APT/DPKG appears to be busy (locks detected)."
            msg_detail "$(echo -e "$context")"
            msg_warn "Dry-run: continuing despite APT/DPKG activity."
            debug_log "Dry-run: not aborting on APT/DPKG locks."
            return 0
        fi

        msg_error "APT/DPKG appears to be busy (locks detected)."
        msg_detail "$(echo -e "$context")"

        # In automation, fail fast instead of hanging on dpkg/apt locks.
        if (( AUTO_YES )); then
            exit 1
        fi

        ask_continue_on_error \
            "Package manager is busy (APT/DPKG lock detected)." \
            "Continuing may fail or hang. Consider aborting and re-running once APT/DPKG is idle."
        return 0
    fi

    # No locks found.
    debug_log "No APT/DPKG locks detected (method: ${lock_check_method}). Proc sample: ${proc_matches:-none}"

    # If we could not check locks at all, fall back to process detection (conservative).
    if [[ "$lock_check_method" == "unknown" && $proc_busy -eq 1 ]]; then
        local context="Another package manager process appears to be running.\n\nRecommended action:\n  - Wait for it to finish\n  - Then re-run this script"
        context+="\n\nRunning processes (sample):\n${proc_matches}"

        debug_log "APT/DPKG may be busy (lock state unknown). Proc sample: ${proc_matches:-none}"

        if (( DRY_RUN )); then
            msg_warn "APT/DPKG may be busy (processes detected; lock state unknown)."
            msg_detail "$(echo -e "$context")"
            msg_warn "Dry-run: continuing despite APT/DPKG activity."
            debug_log "Dry-run: not aborting on unknown lock state."
            return 0
        fi

        msg_error "APT/DPKG may be busy (processes detected; lock state unknown)."
        msg_detail "$(echo -e "$context")"

        if (( AUTO_YES )); then
            exit 1
        fi

        ask_continue_on_error \
            "Package manager may be busy (processes detected; lock state unknown)." \
            "Continuing may fail or hang. Consider aborting and re-running once APT/DPKG is idle."
        return 0
    fi

    if (( proc_busy )); then
        msg_warn "APT/DPKG-related processes detected, but no locks were found (method: ${lock_check_method})."
        msg_detail "$(echo -e "If the update later fails due to locks, wait for those processes to finish and re-run.\n\nRunning processes (sample):\n${proc_matches}")"
    fi

    return 0
}

check_dpkg_health() {
    if ! command -v dpkg &>/dev/null; then
        msg_warn "Skipping dpkg health check: 'dpkg' is not available."
        debug_log "dpkg health check skipped: dpkg not found."
        return 0
    fi

    debug_log "Checking dpkg health (dpkg --audit)..."
    local audit
    audit=$(dpkg --audit 2>&1 || true)

    if [[ -z "$audit" ]]; then
        debug_log "dpkg audit: OK"
        return 0
    fi

    local excerpt
    excerpt=$(echo "$audit" | sed -n '1,12p')

    if (( DRY_RUN )); then
        msg_warn "dpkg reports a broken/unfinished state."
    else
        msg_error "dpkg reports a broken/unfinished state."
    fi
    msg_detail "Fix dpkg/apt before updating Checkmk. Suggested commands:"
    msg_detail "  sudo dpkg --configure -a"
    msg_detail "  sudo apt-get -f install"
    msg_detail "dpkg --audit output (first lines):"
    msg_detail "$(echo "$excerpt" | sed 's/^/  /')"
    debug_log "dpkg --audit output: ${audit}"

    if (( DRY_RUN )); then
        msg_warn "Dry-run: continuing, but a real update is likely to fail until dpkg/apt is fixed."
        debug_log "Dry-run: not aborting on dpkg health issues."
        return 0
    fi

    if (( AUTO_YES )); then
        exit 1
    fi

    ask_continue_on_error \
        "dpkg health check failed (pending/partial installs detected)." \
        "Continuing increases the risk of a broken system state."
}

record_initial_site_status() {
    if [[ -z "${CHECKMK_SITE:-}" ]]; then
        return 0
    fi

    if omd status "$CHECKMK_SITE" &>/dev/null; then
        SITE_WAS_RUNNING_INITIAL=1
        debug_log "Initial site status: running (${CHECKMK_SITE})"
    else
        SITE_WAS_RUNNING_INITIAL=0
        debug_log "Initial site status: stopped (${CHECKMK_SITE})"
    fi
}

edition_sanity_check() {
    if [[ "${INSTALLED_EDITION:-}" == "cre" ]]; then
        debug_log "Edition sanity: Raw (.cre) detected."
        return 0
    fi

    if [[ -n "${INSTALLED_EDITION:-}" ]] && [[ "${INSTALLED_EDITION}" != "cre" ]]; then
        msg_error "This site does not look like Checkmk Raw Edition (.cre). Detected: ${INSTALLED_VERSION_RAW:-unknown}"
        msg_detail "This script downloads and installs 'check-mk-raw-*' packages and is intended for Raw Edition sites."
        debug_log "Edition sanity failed. Version raw: ${INSTALLED_VERSION_RAW:-unknown}, edition: ${INSTALLED_EDITION:-unknown}"
        exit 1
    fi

    msg_warn "Could not determine edition from installed version: ${INSTALLED_VERSION_RAW:-unknown}"
    debug_log "Edition sanity: unknown edition (raw version: ${INSTALLED_VERSION_RAW:-unknown})."
    if (( AUTO_YES )); then
        exit 1
    fi
    ask_continue_on_error \
        "Edition could not be determined." \
        "Proceed only if you are sure this is a Raw Edition (.cre) site."
}

compute_download_url() {
    local distro arch
    distro=$(lsb_release -sc)
    arch=$(dpkg --print-architecture)

    UPDATE_PACKAGE="check-mk-raw-${LATEST_VERSION}_0.${distro}_${arch}.deb"
    DOWNLOAD_URL="https://download.checkmk.com/checkmk/${LATEST_VERSION}/${UPDATE_PACKAGE}"

    debug_log "Computed package: ${UPDATE_PACKAGE}"
    debug_log "Computed URL: ${DOWNLOAD_URL}"
}

precheck_download_url_and_tmp_space() {
    compute_download_url

    # NOTE: We intentionally do NOT perform an HTTP/HEAD URL precheck here.
    # Some environments (proxies, firewalls, CDNs) can return empty headers for HEAD requests,
    # which caused false negatives. The actual download step uses curl --fail and will error
    # out cleanly if the package cannot be fetched.

    msg_info "Pre-check: checking temp free space for download..."
    local avail_kb avail_mb
    avail_kb=$(df --output=avail "$TMP_DIR" 2>/dev/null | tail -n 1 | tr -d ' ')

    if ! [[ "${avail_kb:-}" =~ ^[0-9]+$ ]]; then
        msg_warn "Could not determine free space for temp directory ${TMP_DIR}."
        debug_log "Temp space precheck: df returned non-numeric value: '${avail_kb:-}'"
        return 0
    fi

    avail_mb=$(( avail_kb / 1024 ))
    debug_log "Temp space: available ${avail_kb} KB (${avail_mb} MB) on ${TMP_DIR}"

    # Conservative thresholds (we don't know the exact package size without an HTTP request).
    if (( avail_mb < 256 )); then
        msg_error "Not enough free space in temp directory filesystem for download."
        msg_detail "Available: ${avail_mb} MB (temp dir: ${TMP_DIR})"
        debug_log "Temp space precheck failed (available ${avail_mb} MB < 256 MB)."
        if (( AUTO_YES )); then
            exit 1
        fi
        ask_continue_on_error \
            "Low free space in temp directory (${avail_mb} MB)." \
            "The download will likely fail. Consider freeing space and re-running."
        return 0
    fi

    if (( avail_mb < 1024 )); then
        msg_warn "Low free space in temp directory filesystem (${avail_mb} MB available)."
        msg_detail "Download may fail if there is not enough space. Temp dir: ${TMP_DIR}"
        debug_log "Temp space precheck warning (available ${avail_mb} MB < 1024 MB)."
        return 0
    fi

    msg_ok "Temp space: ${avail_mb} MB available."
}

precheck_backup_destination() {
    (( DRY_RUN )) && return 0
    (( SKIP_BACKUP )) && return 0

    debug_log "Pre-check: backup destination ${BACKUP_DIR}..."
    if ! mkdir -p "$BACKUP_DIR" 2>>"$DEBUG_LOG_FILE"; then
        msg_error "Failed to create backup directory ${BACKUP_DIR}."
        msg_detail "Choose a writable location or run with --no-backup (NOT recommended)."
        debug_log "Backup precheck failed: mkdir -p ${BACKUP_DIR}"
        if (( AUTO_YES )); then
            exit 1
        fi
        ask_continue_on_error \
            "Backup directory is not writable." \
            "Continuing means NO backup will be created."
        return 0
    fi
    chmod 750 "$BACKUP_DIR" 2>/dev/null || true

    local site_size_kb available_kb site_size_mb
    site_size_kb=$(du -sk "$CHECKMK_DIR" 2>>"$DEBUG_LOG_FILE" | awk '{print $1}')
    available_kb=$(df --output=avail "$BACKUP_DIR" 2>/dev/null | tail -n 1 | tr -d ' ')

    if [[ -n "$site_size_kb" ]]; then
        site_size_mb=$(awk -v kb="$site_size_kb" 'BEGIN { printf "%.0f", kb/1024 }')
    else
        site_size_mb="unknown"
    fi

    debug_log "Backup precheck: site size ~${site_size_kb:-unknown} KB; available in ${BACKUP_DIR}: ${available_kb:-unknown} KB"

    if [[ -n "$site_size_kb" && -n "$available_kb" ]] && [[ "$site_size_kb" =~ ^[0-9]+$ ]] && [[ "$available_kb" =~ ^[0-9]+$ ]]; then
        if (( available_kb < site_size_kb )); then
            ask_continue_on_error \
                "Potentially insufficient space for backup in ${BACKUP_DIR}." \
                "Available: $((available_kb / 1024)) MB, site size: ${site_size_mb} MB (uncompressed). Continuing may result in a partial backup."
        fi
    else
        msg_warn "Could not fully verify backup free space in ${BACKUP_DIR}."
    fi
}

check_omd_update_compatibility() {
    (( DRY_RUN )) && return 0

    debug_log "Checking 'omd update' flag compatibility..."
    # Do not rely on 'omd --help' listing global options. Some distributions accept
    # global flags like --force/-V but do not show them in help output.
    # Instead, test whether omd *parses* the flags by running help through the
    # real subcommand path (harmless; does not update anything).

    local missing=()

    # Check that 'omd update' supports --conflict (needed for non-interactive conflict handling).
    local update_help
    update_help=$(omd update --help 2>&1 || true)
    if [[ -z "$update_help" ]] || [[ "$update_help" == *"Unknown option"* ]]; then
        update_help=$(omd update -h 2>&1 || true)
    fi
    if [[ -z "$update_help" ]]; then
        update_help=$(omd help update 2>&1 || true)
    fi
    if [[ -n "$update_help" ]]; then
        echo "$update_help" | grep -q -- '--conflict' || missing+=("--conflict")
    else
        msg_warn "Could not verify 'omd update' options (no help output)."
        debug_log "omd update help output unavailable; skipping --conflict check."
    fi

    # Check that omd accepts --force as a global flag (best effort).
    local test_out
    test_out=$(omd --force update --help 2>&1)
    if echo "$test_out" | grep -qiE 'unknown option|unrecognized option|illegal option'; then
        missing+=("--force")
    fi

    # Check that omd accepts -V as a global flag. Use the installed site version to
    # avoid failing on a not-yet-installed target version.
    if [[ -n "${INSTALLED_VERSION_RAW:-}" ]]; then
        test_out=$(omd -V "${INSTALLED_VERSION_RAW}" update --help 2>&1)
        if echo "$test_out" | grep -qiE 'unknown option|unrecognized option|illegal option'; then
            missing+=("-V")
        fi
    else
        debug_log "Skipping -V parse test (INSTALLED_VERSION_RAW not available)."
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_error "'omd' does not appear to support required flags: ${missing[*]}"
        msg_detail "This script uses:"
        msg_detail "  omd --force -V \"<LATEST_VERSION>.cre\" update --conflict=install \"<SITE>\""
        msg_detail "Please update your Checkmk/OMD installation or adjust the script."
        debug_log "omd flag parse test failed. Missing: ${missing[*]}"
        exit 1
    fi

    debug_log "omd update flag compatibility: OK"
}

maybe_offer_start_site_if_initially_stopped() {
    if (( SITE_WAS_RUNNING_INITIAL )); then
        return 0
    fi
    [[ -n "${CHECKMK_SITE:-}" ]] || return 0

    if omd status "$CHECKMK_SITE" &>/dev/null; then
        debug_log "Site is running at end though it was initially stopped."
        return 0
    fi

    msg_warn "Site ${CHECKMK_SITE} was stopped before the update and is still stopped."

    # In automation, keep the original stopped state.
    if (( AUTO_YES )); then
        msg_detail "Auto-yes: leaving site stopped (it was stopped initially)."
        debug_log "Auto-yes: not starting site that was initially stopped."
        return 0
    fi

    if (( UI_ENABLED )); then
        if confirm_dialog "Start site?" "The site '${CHECKMK_SITE}' was stopped before the update.\n\nStart it now?" "n"; then
            msg_info "Starting site ${CHECKMK_SITE}..."
            omd start "$CHECKMK_SITE" &>> "$DEBUG_LOG_FILE" &
            local pid=$!
            spinner "$pid" "Starting site..."
            local start_exit=$?
            debug_log "omd start (prompted) -> Exit code: ${start_exit}"
            if [[ $start_exit -ne 0 ]]; then
                ask_continue_on_error \
                    "Failed to start site (exit code: ${start_exit})." \
                    "Try starting manually: omd start ${CHECKMK_SITE}"
            else
                msg_ok "Site started."
            fi
        else
            msg_detail "Leaving site stopped."
            debug_log "User chose to keep site stopped (initially stopped)."
        fi
        return 0
    fi

    while true; do
        read -rp "Site was stopped before the update. Start it now? [y/N]: " ans
        case "${ans:-N}" in
            [Yy])
                msg_info "Starting site ${CHECKMK_SITE}..."
                omd start "$CHECKMK_SITE" &>> "$DEBUG_LOG_FILE" &
                local pid=$!
                spinner "$pid" "Starting site..."
                local start_exit=$?
                debug_log "omd start (prompted) -> Exit code: ${start_exit}"
                if [[ $start_exit -ne 0 ]]; then
                    ask_continue_on_error \
                        "Failed to start site (exit code: ${start_exit})." \
                        "Try starting manually: omd start ${CHECKMK_SITE}"
                else
                    msg_ok "Site started."
                fi
                break
                ;;
            [Nn]|"")
                msg_detail "Leaving site stopped."
                debug_log "User chose to keep site stopped (initially stopped)."
                break
                ;;
            *) echo "Please enter 'y' or 'n'." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Download update package
# ---------------------------------------------------------------------------
download_update() {
    compute_download_url
    local update_package="${UPDATE_PACKAGE}"
    local download_url="${DOWNLOAD_URL}"

    debug_log "Package: ${update_package}"
    debug_log "URL: ${download_url}"

    # Get expected file size
    local content_length
    content_length="${DOWNLOAD_CONTENT_LENGTH:-}"
    if ! [[ "$content_length" =~ ^[0-9]+$ ]]; then
        content_length=$(curl -sI --proto =https --max-time 20 "$download_url" 2>>"$DEBUG_LOG_FILE" \
            | awk '/[Cc]ontent-[Ll]ength/ {print $2}' | tr -d '\r')
    fi

    if [[ -n "$content_length" ]]; then
        msg_info "Expected download size: $(( content_length / 1048576 )) MB"
        debug_log "Expected size: ${content_length} bytes"
    fi

    msg_info "Downloading ${update_package}..."
    DOWNLOAD_PACKAGE_PATH="${TMP_DIR}/${update_package}"
    local curl_exit=0

    if (( UI_ENABLED )); then
        if [[ "${content_length:-}" =~ ^[0-9]+$ ]] && (( content_length > 0 )); then
            curl --fail --location --proto =https --silent --show-error \
                -o "$DOWNLOAD_PACKAGE_PATH" "$download_url" 2>>"$DEBUG_LOG_FILE" &
            local curl_pid=$!

            while kill -0 "$curl_pid" 2>/dev/null; do
                local current_bytes
                current_bytes=$(stat -c%s "$DOWNLOAD_PACKAGE_PATH" 2>/dev/null || echo 0)
                draw_progress_bytes "$current_bytes" "$content_length" "Downloading ${update_package}"
                sleep 0.2
            done
            echo ""

            wait "$curl_pid"
            curl_exit=$?
        else
            curl --fail --location --proto =https --silent --show-error \
                -o "$DOWNLOAD_PACKAGE_PATH" "$download_url" 2>>"$DEBUG_LOG_FILE" &
            local curl_pid=$!
            spinner "$curl_pid" "Downloading ${update_package}..."
            curl_exit=$?
        fi
    else
        curl --fail --location --proto =https --progress-bar \
            -o "$DOWNLOAD_PACKAGE_PATH" "$download_url" 2>&1
        curl_exit=$?
    fi

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

    # Note: SHA256 verification is intentionally not performed.
    msg_warn "Checksum verification disabled."
    debug_log "Checksum verification disabled."

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
    if (( UI_ENABLED )); then
        print_header "$SCRIPT_VERSION"
        msg_detail "Debug log: ${DEBUG_LOG_FILE}"
    else
        msg_info "Checkmk Update Script v${SCRIPT_VERSION}"
        msg_info "Debug log: ${DEBUG_LOG_FILE}"
    fi
}

# ---------------------------------------------------------------------------
# Print pre-update confirmation
# ---------------------------------------------------------------------------
confirm_update() {
    local backup_text
    if (( DRY_RUN )); then
        backup_text="skipped (dry-run)"
    elif (( SKIP_BACKUP )); then
        backup_text="skipped (--no-backup)"
    else
        backup_text="$BACKUP_DIR"
    fi

    print_update_summary "$CHECKMK_SITE" "$INSTALLED_VERSION" "$LATEST_VERSION" "$backup_text"

    if (( DRY_RUN )); then
        msg_info "Dry-run: no changes will be made. The site will NOT be stopped."
    elif (( ! SITE_WAS_RUNNING_INITIAL )); then
        msg_info "Site is currently stopped. It will remain stopped after the update unless you choose to start it at the end."
    elif (( SKIP_BACKUP )); then
        msg_warn "Backup will be SKIPPED (--no-backup). This is NOT recommended."
        msg_warn "The site will be STOPPED during the update."
    else
        msg_warn "The site will be STOPPED during the update."
    fi

    if (( AUTO_YES )); then
        debug_log "Auto-yes: proceeding with update."
        return 0
    fi

    local prompt_title prompt_msg
    if (( DRY_RUN )); then
        prompt_title="Proceed with dry-run?"
        prompt_msg="Continue with dry-run (no changes)?"
    else
        prompt_title="Proceed with update?"
        prompt_msg="Continue with update now?"
    fi

    if confirm_dialog "$prompt_title" "$prompt_msg" "n"; then
        debug_log "User confirmed update."
        return 0
    fi

    msg_info "Update cancelled."
    exit 0
}

# ---------------------------------------------------------------------------
# Print completion summary
# ---------------------------------------------------------------------------
print_summary() {
    local new_version elapsed_s elapsed_m elapsed_sec duration site_running backup_path
    new_version=$(omd version "$CHECKMK_SITE" 2>/dev/null | awk '{print $NF}')
    elapsed_s=$(( SECONDS - START_SECONDS ))
    elapsed_m=$(( elapsed_s / 60 ))
    elapsed_sec=$(( elapsed_s % 60 ))
    duration="${elapsed_m}m ${elapsed_sec}s"

    if omd status "$CHECKMK_SITE" &>/dev/null; then
        site_running="true"
    else
        site_running="false"
    fi

    if [[ -n "${BACKUP_FILE_PATH:-}" && -f "$BACKUP_FILE_PATH" ]]; then
        backup_path="$BACKUP_FILE_PATH"
    else
        backup_path="none"
    fi

    print_completion "$CHECKMK_SITE" "$INSTALLED_VERSION" "${new_version:-unknown}" "$backup_path" "$duration" "$site_running"
    msg_detail "Debug log: ${DEBUG_LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Dry-run completion summary
# ---------------------------------------------------------------------------
print_dry_run_summary() {
    local elapsed_s elapsed_m elapsed_sec duration
    elapsed_s=$(( SECONDS - START_SECONDS ))
    elapsed_m=$(( elapsed_s / 60 ))
    elapsed_sec=$(( elapsed_s % 60 ))
    duration="${elapsed_m}m ${elapsed_sec}s"

    if (( ! UI_ENABLED )); then
        echo ""
        echo -e "${C_BOLD}Dry-run Complete${C_RESET}"
        printf  "  %-22s %s\n" "Site:" "$CHECKMK_SITE"
        printf  "  %-22s %s\n" "Installed version:" "$INSTALLED_VERSION"
        printf  "  %-22s %s\n" "Available version:" "$LATEST_VERSION"
        if [[ -n "${DOWNLOAD_PACKAGE_PATH:-}" && -s "$DOWNLOAD_PACKAGE_PATH" ]]; then
            local downloaded_mb
            downloaded_mb=$(( $(stat -c%s "$DOWNLOAD_PACKAGE_PATH" 2>/dev/null || echo 0) / 1048576 ))
            printf  "  %-22s %s (%s MB)\n" "Downloaded package:" "$DOWNLOAD_PACKAGE_PATH" "$downloaded_mb"
        else
            printf  "  %-22s %s\n" "Downloaded package:" "none"
        fi
        printf  "  %-22s %s\n" "Duration:" "$duration"
        printf  "  %-22s %s\n" "Debug log:" "$DEBUG_LOG_FILE"
        echo ""
        return 0
    fi

    local width inner
    width=$(get_term_width)
    inner=$(( width - 6 ))
    (( inner > 64 )) && inner=64

    echo ""
    echo ""
    printf '  %s%s%s%s\n' "$C_CYAN" "$BOX_DTL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_DH")" "$BOX_DTR$C_RESET"

    local title="Dry-run Complete"
    local pad=$(( (inner - ${#title}) / 2 ))
    printf '  %s%s%s%*s%s%s%s%*s%s%s\n' \
        "$C_CYAN" "$BOX_DV" "$C_RESET" \
        "$pad" '' \
        "${C_BOLD}${C_CYAN}" "$title" "$C_RESET" \
        $(( inner - pad - ${#title} )) '' \
        "$C_CYAN" "$BOX_DV$C_RESET"

    printf '  %s%s%s%s\n' "$C_CYAN" "$BOX_DBL" "$(printf '%*s' "$inner" '' | tr ' ' "$BOX_DH")" "$BOX_DBR$C_RESET"
    echo ""

    printf '  %-20s %s\n' "Site:" "$CHECKMK_SITE"
    printf '  %-20s %s\n' "Installed:" "$INSTALLED_VERSION"
    printf '  %-20s %s\n' "Available:" "$LATEST_VERSION"

    if [[ -n "${DOWNLOAD_PACKAGE_PATH:-}" && -s "$DOWNLOAD_PACKAGE_PATH" ]]; then
        local downloaded_mb
        downloaded_mb=$(( $(stat -c%s "$DOWNLOAD_PACKAGE_PATH" 2>/dev/null || echo 0) / 1048576 ))
        printf '  %-20s %s (%s MB)\n' "Package:" "$DOWNLOAD_PACKAGE_PATH" "$downloaded_mb"
    else
        printf '  %-20s %s\n' "Package:" "none"
    fi

    printf '  %-20s %s\n' "Duration:" "$duration"
    msg_detail "Debug log: ${DEBUG_LOG_FILE}"
    echo ""
}

# ===========================================================================
# MAIN
# ===========================================================================

debug_log "Script start (v${SCRIPT_VERSION})"
parse_args "$@"
ui_init

# Self-test exits early
if (( SELF_TEST )); then
    run_self_test
fi

# --- Root check (before anything else that modifies system state) ----------
if (( EUID != 0 )) && (( ! DRY_RUN )); then
    msg_error "This script must be run as root. Current user: $(whoami)"
    msg_info "Run with: sudo $0"
    exit 1
fi
if (( EUID != 0 )) && (( DRY_RUN )); then
    msg_warn "Dry-run as non-root: will not install packages or modify the system."
fi

# --- Banner ----------------------------------------------------------------
print_banner
init_phases

# --- Phase 1: Prerequisites -----------------------------------------------
phase_start "Checking prerequisites"
ensure_omd_available
check_apt_dpkg_locks
check_and_install_packages
check_dpkg_health
phase_end "done" "OK"

# --- Phase 2: Script update check -----------------------------------------
phase_start "Checking for script updates"
check_for_new_script_version
phase_end "done" "OK"

# --- Phase 3: Site detection and version check -----------------------------
phase_start "Detecting Checkmk site"
detect_site
get_installed_version
edition_sanity_check
record_initial_site_status
check_disk_space

# Fetch latest version
fetch_latest_version

msg_info "Installed: ${INSTALLED_VERSION}"
msg_info "Available: ${LATEST_VERSION}"

if [[ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]]; then
    phase_end "done" "Up to date"
    msg_ok "Checkmk is already up to date."
    debug_log "Already up to date."
    exit 0
fi

# Additional pre-checks before stopping the site / creating backups.
precheck_download_url_and_tmp_space
precheck_backup_destination
check_omd_update_compatibility
phase_end "done" "OK"

# --- Confirmation ----------------------------------------------------------
confirm_update

# --- Phase 4: Backup (optional) -------------------------------------------
if (( DRY_RUN )); then
    phase_start "Dry-run: skipping backup"
    msg_info "Dry-run: not stopping site and not creating a backup."
    phase_end "skipped" "dry-run"
else
    phase_start "Backup"

    if (( SITE_WAS_RUNNING_INITIAL )); then
        # We only auto-restart the site if it was running when the script began.
        SITE_WAS_STOPPED=1

        msg_info "Stopping site ${CHECKMK_SITE}..."
        omd stop "$CHECKMK_SITE" &>> "$DEBUG_LOG_FILE" &
        local_pid=$!
        spinner "$local_pid" "Stopping site..."
        stop_exit=$?
        debug_log "omd stop -> Exit code: ${stop_exit}"

        if [[ $stop_exit -ne 0 ]]; then
            ask_continue_on_error \
                "Failed to stop site (exit code: ${stop_exit})." \
                "Continuing may lead to unexpected behavior."
        else
            msg_ok "Site stopped."
        fi
    else
        SITE_WAS_STOPPED=0
        msg_warn "Site ${CHECKMK_SITE} is already stopped (it was stopped before the update)."
        debug_log "Site was initially stopped; skipping omd stop."
    fi

    if (( SKIP_BACKUP )); then
        msg_warn "Skipping backup (--no-backup)."
        BACKUP_FILE_PATH=""
        phase_end "skipped" "--no-backup"
    else
        create_site_backup
        if [[ -n "${BACKUP_FILE_PATH:-}" ]]; then
            phase_end "done" "Backup created"
        else
            phase_end "error" "Backup failed"
        fi
    fi
fi

# --- Phase 5: Download ----------------------------------------------------
phase_start "Downloading update"
download_update
download_exit=$?

if [[ $download_exit -ne 0 || -z "$DOWNLOAD_PACKAGE_PATH" || ! -s "$DOWNLOAD_PACKAGE_PATH" ]]; then
    phase_end "error" "Download failed"
    ask_continue_on_error \
        "No valid package available for installation." \
        "The update cannot proceed without a valid package."
    exit 1
fi
phase_end "done" "Downloaded"

# --- Dry-run finish (no install/update) -----------------------------------
if (( DRY_RUN )); then
    phase_start "Dry-run: skipping install"
    phase_end "skipped" "dry-run"
    phase_start "Dry-run: skipping verification"
    phase_end "skipped" "dry-run"

    msg_ok "Dry-run completed. No changes were made."
    msg_info "Downloaded package kept at: ${DOWNLOAD_PACKAGE_PATH}"
    print_dry_run_summary
    exit 0
fi

# --- Phase 6: Install and update ------------------------------------------
phase_start "Installing update"
install_package "$DOWNLOAD_PACKAGE_PATH"

msg_info "Running omd update for ${CHECKMK_SITE}..."
debug_log "omd update command: omd --force -V '${LATEST_VERSION}.cre' update --conflict=install '${CHECKMK_SITE}'"
omd --force -V "${LATEST_VERSION}.cre" update --conflict=install "$CHECKMK_SITE" 2>&1 | tee -a "$DEBUG_LOG_FILE"
update_exit=${PIPESTATUS[0]}

if [[ $update_exit -ne 0 ]]; then
    ask_continue_on_error \
        "omd update failed (exit code: ${update_exit})." \
        "Check the debug log. You may need to rerun: omd --force -V ${LATEST_VERSION}.cre update --conflict=install ${CHECKMK_SITE}"
    phase_end "error" "omd update failed"
else
    msg_ok "omd update completed."
    phase_end "done" "OK"
fi

# --- Phase 7: Verification ------------------------------------------------
phase_start "Verifying and starting site"

if (( SITE_WAS_RUNNING_INITIAL )); then
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
        phase_end "error" "start failed"
    else
        SITE_WAS_STOPPED=0
        msg_ok "Site started."
        phase_end "done" "OK"
    fi
else
    maybe_offer_start_site_if_initially_stopped
    if omd status "$CHECKMK_SITE" &>/dev/null; then
        phase_end "done" "Running"
    else
        phase_end "done" "Stopped (as before)"
    fi
fi

msg_info "Running omd cleanup..."
omd cleanup &>> "$DEBUG_LOG_FILE" || true

# --- Summary ---------------------------------------------------------------
print_summary
exit 0
