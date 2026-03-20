#!/bin/bash
# Single line: CWD@branch | tokens | %used | %remain | 5h bar in Xh | 7d bar in Xd

set -f  # disable globbing

VERSION="1.0.0"

if [ "$1" = "--update" ]; then
    old_version="$VERSION"
    tmp=$(mktemp)
    if curl -fsSL https://raw.githubusercontent.com/tacoo/ClaudeCodeStatusLine/main/statusline.sh -o "$tmp"; then
        new_version=$(grep '^VERSION=' "$tmp" | head -1 | cut -d'"' -f2)
        cp "$tmp" "$0" && chmod +x "$0"
        rm -f "$tmp"
        echo "Updated: $0 ($old_version -> ${new_version:-unknown})"
        exit 0
    fi
    rm -f "$tmp"
    echo "Update failed." >&2
    exit 1
fi

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ANSI colors matching oh-my-posh theme
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
dim='\033[2m'
reset='\033[0m'

# Format token counts (e.g., 50k / 200k)
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

# Build a colored progress bar
# Usage: build_bar <pct> <width>
build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))

    # Color based on usage level
    local bar_color
    if [ "$pct" -ge 90 ]; then bar_color="$red"
    elif [ "$pct" -ge 70 ]; then bar_color="$yellow"
    elif [ "$pct" -ge 50 ]; then bar_color="$orange"
    else bar_color="$green"
    fi

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

# Format remaining time from epoch seconds
format_remaining() {
    local reset_epoch=$1
    [ -z "$reset_epoch" ] || [ "$reset_epoch" = "0" ] || [ "$reset_epoch" = "null" ] && return

    local now_epoch diff
    now_epoch=$(date +%s)
    diff=$(( reset_epoch - now_epoch ))

    if [ "$diff" -le 0 ]; then
        printf "0m"
        return
    fi

    local days=$(( diff / 86400 ))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))

    if [ "$days" -gt 0 ]; then
        printf "%dd%dh" "$days" "$hours"
    elif [ "$hours" -gt 0 ]; then
        printf "%dh%dm" "$hours" "$mins"
    else
        printf "%dm" "$mins"
    fi
}

# ===== Extract data from JSON =====

# Context window
size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

# Pre-computed percentages
pct_used=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
pct_remain=$(echo "$input" | jq -r '.context_window.remaining_percentage // 100')

# Token counts for display
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

# ===== Build single-line output =====
out=""

# Current working directory
cwd=$(echo "$input" | jq -r '.cwd // empty')
if [ -n "$cwd" ]; then
    display_dir="${cwd##*/}"
    git_branch=$(git -C "${cwd}" rev-parse --abbrev-ref HEAD 2>/dev/null)
    out+="${cyan}${display_dir}${reset}"
    if [ -n "$git_branch" ]; then
        out+="${dim}@${reset}${green}${git_branch}${reset}"
    fi
fi

out+=" ${dim}|${reset} "
out+="${orange}${used_tokens}/${total_tokens}${reset}"
out+=" ${dim}|${reset} "
out+="${green}${pct_used}%${reset} ${dim}used${reset}"
out+=" ${dim}|${reset} "
out+="${cyan}${pct_remain}%${reset} ${dim}remain${reset}"

# ===== Rate limits from status line JSON =====
sep=" ${dim}|${reset} "
bar_width=6

# 5-hour limit
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$five_hour_pct" ]; then
    five_hour_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // 0')
    five_hour_remaining=$(format_remaining "$five_hour_reset")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")

    out+="${sep} ${five_hour_bar} ${cyan}${five_hour_pct}%${reset}"
    [ -n "$five_hour_remaining" ] && out+=" ${dim}in ${five_hour_remaining}${reset}"
fi

# 7-day limit
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
if [ -n "$seven_day_pct" ]; then
    seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // 0')
    seven_day_remaining=$(format_remaining "$seven_day_reset")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")

    out+="${sep} ${seven_day_bar} ${cyan}${seven_day_pct}%${reset}"
    [ -n "$seven_day_remaining" ] && out+=" ${dim}in ${seven_day_remaining}${reset}"
fi

# Off-peak indicator (peak = Mon-Fri 8:00-13:59 ET, until 2026-03-27)
et_date=$(TZ=America/New_York date +"%u %H %Y%m%d")
et_dow=${et_date%% *}          # 1=Mon..7=Sun
et_rest=${et_date#* }
et_hour=${et_rest%% *}          # 00-23
et_ymd=${et_rest#* }            # YYYYMMDD
et_hour=${et_hour#0}            # strip leading zero

if [ "$et_ymd" -le 20260327 ]; then
    if [ "$et_dow" -ge 6 ] || [ "$et_hour" -lt 8 ] || [ "$et_hour" -ge 14 ]; then
        out+="${sep}${green}off-peak${reset}"
    fi
fi

# Version
version=$(echo "$input" | jq -r '.version // empty')
if [ -n "$version" ]; then
    out+="${sep}${dim}v${version}${reset}"
fi

# Output single line
printf "%b" "$out"

exit 0
