#!/usr/bin/env bash
# Name each tmux window after the Claude session running in it, prefixed with a
# status symbol, so a session blocked on you is visible from any window.
#
# Called from status-right, so tmux re-runs it every status-interval; it prints
# nothing and the renames are the side effect.  Claude records every live
# session in ~/.claude/sessions/PID.json with the tmux pane, name and status.

set -u

command -v tmux >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
tmux has-session >/dev/null 2>&1 || exit 0

sessions_dir="$HOME/.claude/sessions"
[ -d "$sessions_dir" ] || exit 0

symbol_for() {
  case "$1" in
    busy)    printf '%s ' '⏳' ;;
    shell)   printf '%s ' '🐚' ;;
    waiting) printf '%s ' '❗' ;;
    idle)    printf '%s ' '✅' ;;
  esac
}

# a window showing several sessions gets the one that most wants your attention
rank_for() {
  case "$1" in
    waiting) echo 3 ;;
    busy)    echo 2 ;;
    shell)   echo 1 ;;
    *)       echo 0 ;;
  esac
}

US=$'\x1f'

declare -A want rank

for f in "$sessions_dir"/*.json; do
  [ -f "$f" ] || continue
  line=$(jq -r '[(.pid // ""), (.tmux // ""), (.name // ""), (.status // "")] | join("\u001f")' "$f" 2>/dev/null) || continue
  IFS=$US read -r pid target name status <<<"$line"
  # a file left behind by a crash names a window nothing is running in
  [ -n "$pid" ] && [ -d "/proc/$pid" ] || continue
  [ -n "$target" ] && [ -n "$name" ] || continue
  win="${target%.*}"
  r=$(rank_for "$status")
  if [ -z "${want[$win]:-}" ] || [ "$r" -gt "${rank[$win]}" ]; then
    want[$win]="$(symbol_for "$status")$name"
    rank[$win]=$r
  fi
done

# every field after the key carries a "." prefix: tab is IFS whitespace, so an
# empty field would collapse into the next delimiter and shift the whole row
while IFS=$'\t' read -r win current owned basename; do
  current=${current#.} owned=${owned#.} basename=${basename#.}
  desired="${want[$win]:-}"
  if [ -n "$desired" ]; then
    [ "$current" = "$desired" ] && continue
    tmux rename-window -t "$win" "$desired"
    tmux set-window-option -t "$win" @claude_named 1
  elif [ -n "$owned" ]; then
    # rename first: rename-window is what turns automatic-rename off
    tmux rename-window -t "$win" "$basename"
    tmux set-window-option -t "$win" -u automatic-rename
    tmux set-window-option -t "$win" -u @claude_named
  fi
done < <(tmux list-windows -a -F \
  '#{session_name}:#{window_id}	.#{window_name}	.#{@claude_named}	.#{b:pane_current_path}')
