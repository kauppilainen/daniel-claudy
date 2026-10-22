# daniel-claudy

Read Claude Code sessions in Emacs and send prompts to them through tmux.

> **Not maintained.** Some colleagues liked this, so I'm making it public for
> anyone who wants it. I don't have time to maintain it: no support, no fixes,
> no reviewed PRs. Fork it, use it and change it as you like (MIT). Adapting it
> to your setup is easy these days: fork it and ask an AI to do it.

Put `daniel-claudy.el` in `~/.emacs.d/daniel-claudy/`, then:

```elisp
(use-package markdown-mode :ensure t)
(use-package daniel-claudy
  :load-path "~/.emacs.d/daniel-claudy"
  :config
  (daniel-claudy-modeline-mode 1)
  (add-to-list 'global-mode-string '("" daniel-claudy-modeline-string) t))
```

Then `M-x daniel-claudy-view`, pick a session, type a prompt under the
transcript, `C-c C-c`.

## Requirements

1. Linux (a session counts as live while `/proc/PID` exists).
2. Emacs 29.1+.
3. `markdown-mode` 2.5+.
4. `tmux`, with Claude running inside it - needed to send, focus, start and
   resume sessions. Viewing transcripts works without it.
5. The `claude` CLI on `PATH`.

## Install

Without `use-package`, the same thing:

```elisp
(add-to-list 'load-path "~/.emacs.d/daniel-claudy")
(require 'daniel-claudy)
```

Loading the file only defines things: no mode, timer, hook or process starts
until you turn it on.

## Minimal config

```elisp
;; session statuses (❗ waiting, ⏳ busy, 🐚 shell, ✅ idle) in the mode line,
;; and claudy buffers that follow their session
(daniel-claudy-modeline-mode 1)
(add-to-list 'global-mode-string '("" daniel-claudy-modeline-string) t)

;; global keys - pick your own
(global-set-key (kbd "C-c a v") #'daniel-claudy-view)            ; C-u: every recent session
(global-set-key (kbd "C-c a s") #'daniel-claudy-tmux-send-selection)
(global-set-key (kbd "C-c a n") #'daniel-claudy-new-session)
(global-set-key (kbd "C-c a r") #'daniel-claudy-resume-new-window) ; C-u: every repo

;; optional: usage limits in the mode line of claudy buffers, hourly
(run-at-time 0 3600 #'daniel-claudy-usage)
```

Using a custom `mode-line-format` instead of `global-mode-string`? Put the
symbol `daniel-claudy-modeline-string` in it.

## Keys in a transcript buffer (`daniel-claudy-mode-map`)

| Key       | Command                               | Does                                          |
|-----------|---------------------------------------|-----------------------------------------------|
| `C-c C-c` | `daniel-claudy-tmux-send-rest`        | send the selection, or this line to end of buffer |
| `C-c C-l` | `daniel-claudy-tmux-send-current-line`| send the current line (or selection)          |
| `C-c C-a` | `daniel-claudy-refresh`               | re-render, park on Claude's latest answer     |
| `C-c C-j` | `daniel-claudy-jump-to-question`      | re-render, park on your latest prompt         |
| `C-c C-t` | `daniel-claudy-toggle-tool-lines`     | show/hide `[tool: ...]` lines                 |
| `C-c C-o` | `daniel-claudy-tmux-focus-pane`       | switch tmux to the session's pane             |
| `C-c C-r` | `daniel-claudy-resume`                | `/resume` another session in this pane (C-u: every repo) |
| `C-c C-u` | `daniel-claudy-usage`                 | fetch usage limits via `claude -p /usage`     |
| `C-c C-k` | `daniel-claudy-exit-this-session`     | `/exit` the session (asks first)              |

`revert-buffer` re-renders too. These shadow the markdown-mode keys on the
same chords; the buffer is a transcript, not a document you edit.

Also available: `daniel-claudy-direct-prompt` - one-off `claude -p` question
on the selection, answer pops in a buffer.

## Optional: auto-refresh when Claude finishes

A send arms the buffer; this Stop hook in `~/.claude/settings.json` tells Emacs
the turn ended, so the transcript re-renders on its own:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "jq -r .transcript_path | xargs -I{} emacsclient --eval '(daniel-claudy-notify-finished \"{}\")' >/dev/null 2>&1 || true"
          }
        ]
      }
    ]
  }
}
```

Needs `jq` and a running Emacs server (`M-x server-start`).

## Optional: status glyphs in tmux window names

`claude-tmux-rename.sh` (sent along with this file) names each tmux window after its Claude session, prefixed with the same
status glyph. Wire it in `~/.tmux.conf`:

```
set -g status-right "#(/path/to/claude-tmux-rename.sh)"
```

## Settings

`M-x customize-group RET daniel-claudy`: projects dir, sessions dir, max
sessions offered, modeline poll interval, `claude -p` directory, long-send
confirmation limits.
