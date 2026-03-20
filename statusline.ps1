# Single line: CWD@branch | tokens | %used | %remain | 5h bar in Xh | 7d bar in Xd
# Windows-only PowerShell version of statusline.sh

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'

$Version = "1.0.0"

if ($args -contains '--update') {
    $oldVersion = $Version
    try {
        $tmp = [System.IO.Path]::GetTempFileName()
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/tacoo/ClaudeCodeStatusLine/main/statusline.ps1" -OutFile $tmp
        $newVersion = (Select-String -Path $tmp -Pattern '^\$Version\s*=\s*"(.+)"' | Select-Object -First 1).Matches.Groups[1].Value
        Copy-Item $tmp $PSCommandPath -Force
        Remove-Item $tmp -Force
        "Updated: $PSCommandPath ($oldVersion -> $(if ($newVersion) { $newVersion } else { 'unknown' }))"
    } catch {
        if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force }
        "Update failed: $_" | Write-Error
        exit 1
    }
    exit 0
}

$jsonInput = [Console]::In.ReadToEnd().Trim()

if (-not $jsonInput) {
    "Claude"
    exit 0
}

$data = $jsonInput | ConvertFrom-Json

# ANSI colors matching oh-my-posh theme
$e       = [char]0x1b
$orange  = "$e[38;2;255;176;85m"
$green   = "$e[38;2;0;160;0m"
$cyan    = "$e[38;2;46;149;153m"
$red     = "$e[38;2;255;85;85m"
$yellow  = "$e[38;2;230;200;0m"
$white   = "$e[38;2;220;220;220m"
$dim     = "$e[2m"
$reset   = "$e[0m"

function Format-Tokens([long]$num) {
    if ($num -ge 1000000) { return "{0:F1}m" -f ($num / 1000000) }
    if ($num -ge 1000)    { return "{0:F0}k" -f ($num / 1000) }
    return "$num"
}

function Build-Bar([int]$pct, [int]$width) {
    if ($pct -lt 0)   { $pct = 0 }
    if ($pct -gt 100)  { $pct = 100 }

    $filled = [math]::Floor($pct * $width / 100)
    $empty  = $width - $filled

    $barColor = if ($pct -ge 90) { $red }
                elseif ($pct -ge 70) { $yellow }
                elseif ($pct -ge 50) { $orange }
                else { $green }

    $filledStr = ([char]0x25CF).ToString() * $filled   # ●
    $emptyStr  = ([char]0x25CB).ToString() * $empty    # ○

    return "${barColor}${filledStr}${dim}${emptyStr}${reset}"
}

function Format-Remaining([long]$resetEpoch) {
    if ($resetEpoch -le 0) { return $null }

    $nowEpoch = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $diff = $resetEpoch - $nowEpoch

    if ($diff -le 0) { return "0m" }

    $days  = [int][math]::Floor($diff / 86400)
    $hours = [int][math]::Floor(($diff % 86400) / 3600)
    $mins  = [int][math]::Floor(($diff % 3600) / 60)

    if ($days -gt 0)  { return "{0}d{1}h" -f $days, $hours }
    if ($hours -gt 0) { return "{0}h{1}m" -f $hours, $mins }
    return "{0}m" -f $mins
}

# ===== Extract data from JSON =====

$size = if ($data.context_window.context_window_size) { [long]$data.context_window.context_window_size } else { 200000 }
if ($size -eq 0) { $size = 200000 }

$inputTokens = if ($data.context_window.current_usage.input_tokens) { [long]$data.context_window.current_usage.input_tokens } else { 0 }
$cacheCreate = if ($data.context_window.current_usage.cache_creation_input_tokens) { [long]$data.context_window.current_usage.cache_creation_input_tokens } else { 0 }
$cacheRead   = if ($data.context_window.current_usage.cache_read_input_tokens) { [long]$data.context_window.current_usage.cache_read_input_tokens } else { 0 }
$current = $inputTokens + $cacheCreate + $cacheRead

$usedTokens  = Format-Tokens $current
$totalTokens = Format-Tokens $size

$pctUsed   = if ($data.context_window.used_percentage) { [int]$data.context_window.used_percentage } else { 0 }
$pctRemain = if ($data.context_window.remaining_percentage) { [int]$data.context_window.remaining_percentage } else { 100 }

# ===== Build single-line output =====
$out = ""

# Current working directory
$cwd = $data.cwd
if ($cwd) {
    $displayDir = Split-Path -Leaf $cwd
    $gitBranch = & git -C $cwd rev-parse --abbrev-ref HEAD 2>$null
    $out += "${cyan}${displayDir}${reset}"
    if ($gitBranch) {
        $out += "${dim}@${reset}${green}${gitBranch}${reset}"
    }
}

$sep = " ${dim}|${reset} "

$out += $sep
$out += "${orange}${usedTokens}/${totalTokens}${reset}"
$out += $sep
$out += "${green}${pctUsed}%${reset} ${dim}used${reset}"
$out += $sep
$out += "${cyan}${pctRemain}%${reset} ${dim}remain${reset}"

# ===== Rate limits from status line JSON =====
$barWidth = 6

# 5-hour limit
$fiveHourPct = $data.rate_limits.five_hour.used_percentage
if ($null -ne $fiveHourPct) {
    $fiveHourPct = [int]$fiveHourPct
    $fiveHourReset = if ($data.rate_limits.five_hour.resets_at) { [long]$data.rate_limits.five_hour.resets_at } else { 0 }
    $fiveHourRemaining = Format-Remaining $fiveHourReset
    $fiveHourBar = Build-Bar $fiveHourPct $barWidth

    $out += "${sep} ${fiveHourBar} ${cyan}${fiveHourPct}%${reset}"
    if ($fiveHourRemaining) { $out += " ${dim}in ${fiveHourRemaining}${reset}" }
}

# 7-day limit
$sevenDayPct = $data.rate_limits.seven_day.used_percentage
if ($null -ne $sevenDayPct) {
    $sevenDayPct = [int]$sevenDayPct
    $sevenDayReset = if ($data.rate_limits.seven_day.resets_at) { [long]$data.rate_limits.seven_day.resets_at } else { 0 }
    $sevenDayRemaining = Format-Remaining $sevenDayReset
    $sevenDayBar = Build-Bar $sevenDayPct $barWidth

    $out += "${sep} ${sevenDayBar} ${cyan}${sevenDayPct}%${reset}"
    if ($sevenDayRemaining) { $out += " ${dim}in ${sevenDayRemaining}${reset}" }
}

# Off-peak indicator (peak = Mon-Fri 8:00-13:59 ET, until 2026-03-27)
try {
    $etZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $etNow  = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $etZone)
    $etDow  = [int]$etNow.DayOfWeek  # 0=Sun..6=Sat
    $etHour = $etNow.Hour
    $etDate = [int]$etNow.ToString("yyyyMMdd")

    if ($etDate -le 20260327) {
        $isWeekend = ($etDow -eq 0 -or $etDow -eq 6)
        $isOffHours = ($etHour -lt 8 -or $etHour -ge 14)
        if ($isWeekend -or $isOffHours) {
            $out += "${sep}${green}off-peak${reset}"
        }
    }
} catch {}

# Version
$version = $data.version
if ($version) {
    $out += "${sep}${dim}v${version}${reset}"
}

# Output single line
$out

exit 0
