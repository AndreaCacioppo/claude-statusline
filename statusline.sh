#!/usr/bin/env bash
# Claude Code status line. Reads the JSON Claude Code pipes on stdin and prints
# two lines: model, context and git; then the rate limits (5-hour, 7-day and
# any model-scoped week such as Opus or Fable).
#
# The model-scoped week is not in that JSON. It comes from the usage snapshot
# in ~/.claude.json, which the bottom of this file refreshes in the background.
# The same snapshot replaces the 5-hour and 7-day numbers when its reading is
# newer.
#
# Written for bash 3.2 (the /bin/bash of macOS): no associative arrays, no
# ${var,,}, no mapfile.

input=$(cat)

# NOW can be pinned by the tests so that "resets in 4h38m" is reproducible.
NOW=${CLAUDE_STATUSLINE_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac

CACHE_DIR="$HOME/.claude/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null

# One jq call. Fields are joined with the unit separator (0x1f): with a tab
# as IFS, `read` collapses empty fields.
US=$'\x1f'
IFS="$US" read -r MODEL EFFORT CTX_PCT CTX_USED CTX_SIZE FIVE_PCT FIVE_RESET SEVEN_PCT SEVEN_RESET <<EOF
$(printf '%s' "$input" | jq -r '
    def pct: if . == null then "" else floor end;
    [
        (.model.display_name // "Claude"),
        (.effort.level // ""),
        (.context_window.used_percentage | pct),
        ((.context_window.current_usage // {})
            | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)),
        (.context_window.context_window_size // 200000),
        (.rate_limits.five_hour.used_percentage | pct),
        (.rate_limits.five_hour.resets_at // ""),
        (.rate_limits.seven_day.used_percentage | pct),
        (.rate_limits.seven_day.resets_at // "")
    ] | map(tostring) | join("\u001f")' 2>/dev/null)
EOF

# Empty or non-JSON stdin leaves every field above empty.
[ -z "$MODEL" ] && MODEL="Claude"
case "$CTX_USED" in ''|*[!0-9]*) CTX_USED=0 ;; esac
case "$CTX_SIZE" in ''|*[!0-9]*|0) CTX_SIZE=200000 ;; esac
case "$CTX_PCT" in ''|*[!0-9]*) CTX_PCT=$(( CTX_USED * 100 / CTX_SIZE )) ;; esac
case "$FIVE_PCT" in *[!0-9]*) FIVE_PCT="" ;; esac
case "$SEVEN_PCT" in *[!0-9]*) SEVEN_PCT="" ;; esac

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'

colour_for() {
    if   [ "${1:-0}" -ge 80 ]; then printf '%s' "$RED"
    elif [ "${1:-0}" -ge 60 ]; then printf '%s' "$YELLOW"
    else                           printf '%s' "$GREEN"
    fi
}

# gauge <label> <percent>: "label 20%" with the number coloured by threshold.
gauge() {
    printf '%s%s%s %s%s%d%%%s' "$DIM" "$1" "$RESET" "$(colour_for "$2")" "$BOLD" "${2:-0}" "$RESET"
}

# until_text <epoch>: "2h05m", "3d4h", "12m" or "now". Empty if not a number
# or 0, which is how a missing reset time is stored.
until_text() {
    local at="${1%%.*}" diff d h m
    case "$at" in ''|0|*[!0-9]*) return ;; esac
    diff=$(( at - NOW ))
    if [ "$diff" -le 0 ]; then printf 'now'; return; fi
    d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
    if   [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
    else                      printf '%dm' "$m"
    fi
}

# mtime_of <path>: modification time as epoch seconds. GNU stat first: on
# Linux `stat -f %m` succeeds too, printing the mount point.
mtime_of() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# snapshot_is_newer <percent> <resets_at> <snapshot percent> <snapshot resets_at>
# Succeeds when the snapshot reading is newer than the other one. A reset time
# more than ten minutes later means a later window. Inside one window usage
# only goes up, so the higher percent is the newer reading.
snapshot_is_newer() {
    local reset="${2%%.*}"
    [ -z "$3" ] && return 1
    [ -z "$1" ] && return 0
    case "$reset" in ''|*[!0-9]*) reset=0 ;; esac
    [ "$4" -gt $(( reset + 600 )) ] && return 0
    [ "$4" -lt $(( reset - 600 )) ] && return 1
    [ "$3" -gt "$1" ]
}

SEP="  ${DIM}│${RESET}  "

# ---------------------------------------------------------------------------
# Line 1: model, effort, context, git
# ---------------------------------------------------------------------------
[ -z "$EFFORT" ] && EFFORT=$(jq -r '.effortLevel // ""' "$HOME/.claude/settings.json" 2>/dev/null)
MODEL_TEXT="${BOLD}${MODEL}${RESET}"
[ -n "$EFFORT" ] && MODEL_TEXT="${MODEL_TEXT} ${DIM}${EFFORT}${RESET}"

if [ "$CTX_SIZE" -ge 1000000 ]; then SIZE_TEXT="$(( CTX_SIZE / 1000000 ))M"; else SIZE_TEXT="$(( CTX_SIZE / 1000 ))k"; fi
CTX_TEXT="$(gauge ctx "$CTX_PCT") ${DIM}$(( CTX_USED / 1000 ))k/${SIZE_TEXT}${RESET}"

GIT_TEXT=""
branch=$(git branch --show-current 2>/dev/null)
if [ -n "$branch" ]; then
    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        GIT_TEXT="${RED}${branch}${RESET}"
    else
        GIT_TEXT="${CYAN}${branch}${RESET}"
    fi
    stats=$(git diff HEAD --shortstat 2>/dev/null)
    re_add='([0-9]+) insertion'; re_del='([0-9]+) deletion'
    added=0; removed=0
    [[ $stats =~ $re_add ]] && added=${BASH_REMATCH[1]}
    [[ $stats =~ $re_del ]] && removed=${BASH_REMATCH[1]}
    if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
        GIT_TEXT="${GIT_TEXT} ${GREEN}+${added}${RESET} ${RED}−${removed}${RESET}"
    fi
fi

LINE1="${MODEL_TEXT}${SEP}${CTX_TEXT}"
[ -n "$GIT_TEXT" ] && LINE1="${LINE1}${SEP}${GIT_TEXT}"
printf '%s\n' "$LINE1"

# ---------------------------------------------------------------------------
# Usage snapshot. ~/.claude.json keeps the last account-wide usage reading the
# app fetched; the bottom of this file keeps it fresh. Its .limits list has
# one entry per window: kind session is the 5-hour window, weekly_all the
# 7-day one, and each weekly_scoped entry a per-model week (Opus, Fable...).
# Dates have fractional seconds and a +00:00 offset, which fromdateiso8601
# rejects, so both are stripped. A missing entry reads as "-1 0", which keeps
# the field count fixed.
#
# jq prints a first line with the fixed fields, then one line per scoped
# window: "label percent resets_at". The label is the model name in lower
# case with spaces removed. The first `read` takes line one, the loop the
# rest of the same heredoc.
# ---------------------------------------------------------------------------
REFRESH_SECONDS=${CLAUDE_STATUSLINE_REFRESH_SECONDS:-330}
case "$REFRESH_SECONDS" in ''|*[!0-9]*) REFRESH_SECONDS=330 ;; esac

SCOPED_ROWS=""
{
    IFS=' ' read -r SNAP_TAKEN SNAP_FIVE_PCT SNAP_FIVE_RESET SNAP_SEVEN_PCT SNAP_SEVEN_RESET
    while IFS=' ' read -r label pct reset; do
        [ -n "$label" ] && SCOPED_ROWS="${SCOPED_ROWS}${label} ${pct} ${reset}"$'\n'
    done
} <<EOF
$(jq -r '
    def to_epoch:
        if . == null or . == "" then 0
        else (try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch 0)
        end;
    def reading($row):
        if $row == null then "-1 0"
        else "\($row.percent // 0 | floor) \($row.resets_at | to_epoch)" end;
    (.cachedUsageUtilization.fetchedAtMs // 0) as $taken
    | (.cachedUsageUtilization.utilization.limits // []) as $limits
    | ([
        ($taken / 1000 | floor | tostring),
        reading($limits | map(select(.kind == "session")) | first),
        reading($limits | map(select(.kind == "weekly_all")) | first)
      ] | join(" ")),
      ($limits[] | select(.kind == "weekly_scoped" and .scope.model.display_name != null)
        | "\(.scope.model.display_name | ascii_downcase | gsub(" "; "")) \(reading(.))")
    ' "$HOME/.claude.json" 2>/dev/null)
EOF

# Guard the numeric tests below: anything not a plain number means no reading.
case "$SNAP_TAKEN" in ''|*[!0-9]*) SNAP_TAKEN=0 ;; esac
case "$SNAP_FIVE_PCT" in ''|*[!0-9]*) SNAP_FIVE_PCT="" ;; esac
case "$SNAP_FIVE_RESET" in ''|*[!0-9]*) SNAP_FIVE_RESET=0 ;; esac
case "$SNAP_SEVEN_PCT" in ''|*[!0-9]*) SNAP_SEVEN_PCT="" ;; esac
case "$SNAP_SEVEN_RESET" in ''|*[!0-9]*) SNAP_SEVEN_RESET=0 ;; esac

# ≈ marks a snapshot that outlived two refresh intervals, so the refresh is
# not getting through.
SNAP_STALE=""
[ "$(( NOW - SNAP_TAKEN ))" -gt "$(( REFRESH_SECONDS * 2 ))" ] && SNAP_STALE="${DIM}≈${RESET}"

# ---------------------------------------------------------------------------
# Line 2: rate limits. Claude Code only sends them after the first response
# of a session, so the last values seen are kept in a small cache file and
# shown, marked with ≈, until fresh ones arrive.
#
# Those values only change when this session gets a response, so while it
# sits idle they fall behind usage from other sessions. The newer of them and
# the snapshot is shown.
# ---------------------------------------------------------------------------
CACHE="$CACHE_DIR/statusline-limits"
FIVE_MARK=""
SEVEN_MARK=""
if [ -n "$FIVE_PCT" ] && [ -n "$SEVEN_PCT" ]; then
    # Missing reset times are written as 0 to keep four columns. Temp file
    # and rename, so a concurrent status line never reads a partial file.
    printf '%s %s %s %s\n' "$FIVE_PCT" "${FIVE_RESET:-0}" "$SEVEN_PCT" "${SEVEN_RESET:-0}" > "$CACHE.$$" 2>/dev/null \
        && mv -f "$CACHE.$$" "$CACHE" 2>/dev/null
    rm -f "$CACHE.$$" 2>/dev/null
elif [ -r "$CACHE" ]; then
    read -r FIVE_PCT FIVE_RESET SEVEN_PCT SEVEN_RESET < "$CACHE"
    case "$FIVE_PCT" in ''|*[!0-9]*) FIVE_PCT="" ;; esac
    case "$SEVEN_PCT" in ''|*[!0-9]*) SEVEN_PCT="" ;; esac
    FIVE_MARK="${DIM}≈${RESET}"
    SEVEN_MARK="${DIM}≈${RESET}"
fi

if snapshot_is_newer "$FIVE_PCT" "$FIVE_RESET" "$SNAP_FIVE_PCT" "$SNAP_FIVE_RESET"; then
    FIVE_PCT=$SNAP_FIVE_PCT
    FIVE_RESET=$SNAP_FIVE_RESET
    FIVE_MARK=$SNAP_STALE
fi
if snapshot_is_newer "$SEVEN_PCT" "$SEVEN_RESET" "$SNAP_SEVEN_PCT" "$SNAP_SEVEN_RESET"; then
    SEVEN_PCT=$SNAP_SEVEN_PCT
    SEVEN_RESET=$SNAP_SEVEN_RESET
    SEVEN_MARK=$SNAP_STALE
fi

# A fresh snapshot with the same value clears the ≈ of a cached one.
if [ -z "$SNAP_STALE" ] && [ "$FIVE_PCT" = "$SNAP_FIVE_PCT" ]; then FIVE_MARK=""; fi
if [ -z "$SNAP_STALE" ] && [ "$SEVEN_PCT" = "$SNAP_SEVEN_PCT" ]; then SEVEN_MARK=""; fi

LINE2=""
if [ -n "$FIVE_PCT" ] && [ -n "$SEVEN_PCT" ]; then
    five_in=$(until_text "$FIVE_RESET")
    seven_in=$(until_text "$SEVEN_RESET")
    LINE2="${FIVE_MARK}$(gauge 5h "$FIVE_PCT")"
    [ -n "$five_in" ] && LINE2="${LINE2} ${MAGENTA}↻${five_in}${RESET}"
    LINE2="${LINE2}${SEP}${SEVEN_MARK}$(gauge 7d "$SEVEN_PCT")"
    [ -n "$seven_in" ] && LINE2="${LINE2} ${MAGENTA}↻${seven_in}${RESET}"
fi

# Model-scoped weeks come only from the snapshot. Each is dropped once its
# window has rolled over. Heredoc, not pipe, so LINE2 survives the loop.
while IFS=' ' read -r label pct reset; do
    case "$pct" in ''|*[!0-9]*) continue ;; esac
    case "$reset" in ''|*[!0-9]*) continue ;; esac
    [ "$reset" -gt "$NOW" ] || continue
    scoped_text="${SNAP_STALE}$(gauge "$label" "$pct")"
    scoped_in=$(until_text "$reset")
    [ -n "$scoped_in" ] && scoped_text="${scoped_text} ${MAGENTA}↻${scoped_in}${RESET}"
    if [ -n "$LINE2" ]; then LINE2="${LINE2}${SEP}${scoped_text}"; else LINE2="$scoped_text"; fi
done <<EOF
$SCOPED_ROWS
EOF

[ -n "$LINE2" ] && printf '%s\n' "$LINE2"

# ---------------------------------------------------------------------------
# Keeping that snapshot fresh. The app rewrites it only when it fetches
# usage, so this asks it to: `claude -p /usage` refreshes ~/.claude.json and
# makes no model request. It runs detached, so drawing never waits for it -
# the value lands on a later render. It runs from $HOME because an untrusted
# project directory would stop it; CLAUDE_STATUSLINE_REFRESH marks the child
# so a status line drawn inside it cannot start another.
# --no-session-persistence keeps it from leaving a transcript on disk.
#
# Two files pace it. The lock directory holds concurrent status lines to one
# refresh at a time and is broken after LOCK_STALE_SECONDS. The state file
# holds "<last attempt> <retried>". Pacing goes by the attempt time, so a
# refresh that keeps failing (offline, signed out) still runs once per
# interval.
#
# Not every run lands: the app sometimes answers from its own cache and the
# snapshot keeps its old timestamp. Such a run is retried once, RETRY_SECONDS
# later, by moving the attempt time back; the retried flag allows one retry
# per interval.
#
# Set CLAUDE_STATUSLINE_REFRESH_SECONDS=0 to turn the refresh off.
# ---------------------------------------------------------------------------
RETRY_SECONDS=60
LOCK_STALE_SECONDS=600
LOCK="$CACHE_DIR/statusline-usage-refresh.lock"
STATE="$CACHE_DIR/statusline-usage-refresh.state"

if [ -d "$LOCK" ]; then
    lock_taken=$(mtime_of "$LOCK")
    case "$lock_taken" in ''|*[!0-9]*) lock_taken=$NOW ;; esac
    [ "$(( NOW - lock_taken ))" -gt "$LOCK_STALE_SECONDS" ] && rmdir "$LOCK" 2>/dev/null
fi

# The status line may be drawn with a PATH that never loaded the shell
# profile, so the install directory is tried when the name does not resolve.
CLAUDE_BIN=$(command -v claude 2>/dev/null)
[ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"

LAST_TRY=0
RETRIED=0
[ -r "$STATE" ] && read -r LAST_TRY RETRIED < "$STATE"
case "$LAST_TRY" in ''|*[!0-9]*) LAST_TRY=0 ;; esac
case "$RETRIED" in 1) ;; *) RETRIED=0 ;; esac

if [ -n "$CLAUDE_BIN" ] && [ -z "$CLAUDE_STATUSLINE_REFRESH" ] &&
   [ "$REFRESH_SECONDS" -gt 0 ] &&
   [ "$(( NOW - SNAP_TAKEN ))" -ge "$REFRESH_SECONDS" ] &&
   [ "$(( NOW - LAST_TRY ))" -ge "$REFRESH_SECONDS" ]; then
    if mkdir "$LOCK" 2>/dev/null; then
        printf '%s %s\n' "$NOW" "$RETRIED" > "$STATE" 2>/dev/null
        (
            cd "$HOME" || exit
            CLAUDE_STATUSLINE_REFRESH=1 "$CLAUDE_BIN" -p --no-session-persistence "/usage" >/dev/null 2>&1
            taken_after=$(jq -r '(.cachedUsageUtilization.fetchedAtMs // 0) / 1000 | floor' \
                "$HOME/.claude.json" 2>/dev/null)
            if [ "$taken_after" != "$SNAP_TAKEN" ] || [ "$RETRIED" -eq 1 ]; then
                printf '%s 0\n' "$NOW" > "$STATE" 2>/dev/null
            else
                printf '%s 1\n' "$(( NOW - REFRESH_SECONDS + RETRY_SECONDS ))" > "$STATE" 2>/dev/null
            fi
            rmdir "$LOCK" 2>/dev/null
        ) </dev/null >/dev/null 2>&1 &
    fi
fi

exit 0
