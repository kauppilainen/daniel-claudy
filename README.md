# daniel-claudy

Read Claude Code sessions in Emacs and send prompts to them through
[herdr](https://herdr.dev).

> A fork of [danielhvs/daniel-claudy](https://github.com/danielhvs/daniel-claudy)
> with the tmux layer swapped for herdr. The upstream is not maintained; neither
> is this. Fork it, use it and change it as you like (MIT).

See every feature in screenshots (tmux-era, same keys): [claudy-tour](https://danielhvs.github.io/daniel-claudy/daniel-claudy-tour.html).

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

1. Emacs 29.1+.
2. `markdown-mode` 2.5+.
3. `herdr` on `PATH` with its server running and the Claude integration
   installed (`herdr integration install claude`): that is what tells herdr
   which Claude session each pane hosts, and claudy looks panes up by session
   id. Needed to send, focus, start and resume sessions. Viewing transcripts
   works without it.
4. The `claude` CLI on `PATH`.

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
(global-set-key (kbd "C-c a s") #'daniel-claudy-send-selection)  ; C-u: pick the session again
(global-set-key (kbd "C-c a c") #'daniel-claudy-connect)
(global-set-key (kbd "C-c a n") #'daniel-claudy-new-session)
(global-set-key (kbd "C-c a r") #'daniel-claudy-resume-new-workspace) ; C-u: every repo

;; optional: usage limits in the mode line of claudy buffers, hourly
(run-at-time 0 3600 #'daniel-claudy-usage)
```

## Sending from any buffer

`daniel-claudy-send-selection` sends the selection to the Claude session
linked to the current project (the git root, as `project.el` sees it). The
first send from a project asks you to pick a running session and remembers
the choice in `daniel-claudy-project-sessions`; after that, every send from
any buffer in that project goes there without asking, like a CIDER REPL
linked to its project. It asks again only when that session is gone, or when
you call it with a prefix argument. `daniel-claudy-connect` re-links on
demand. With `savehist-mode` on, the links survive Emacs restarts.

`daniel-claudy-send-command-with-context` asks for a command or question in
the minibuffer and sends it with the selection below, headed by the file
(relative to the project root) and its line range:

```
Explain what this does.

daniel-claudy.el:120-134
` ` `
...the selected lines...
` ` `
```

Same project link, same prefix argument.

`daniel-claudy-focus-project-session` switches herdr to the project's session
and brings the terminal running the herdr client to the front (macOS, via
System Events by pid, so another window of the same terminal app is never
raised instead). `C-c C-o` in a transcript buffer does the same for that
session.

Using a custom `mode-line-format` instead of `global-mode-string`? Put the
symbol `daniel-claudy-modeline-string` in it.

## Keys in a transcript buffer (`daniel-claudy-mode-map`)

| Key       | Command                               | Does                                          |
|-----------|---------------------------------------|-----------------------------------------------|
| `C-c C-c` | `daniel-claudy-send-rest`             | send the selection, or this line to end of buffer |
| `C-c C-l` | `daniel-claudy-send-current-line`     | send the current line (or selection)          |
| `C-c C-a` | `daniel-claudy-refresh`               | re-render, park on Claude's latest answer     |
| `C-c C-j` | `daniel-claudy-jump-to-question`      | re-render, park on your latest prompt         |
| `C-c C-t` | `daniel-claudy-toggle-tool-lines`     | show/hide `[tool: ...]` lines                 |
| `C-c C-o` | `daniel-claudy-focus-pane`            | focus the session's pane in herdr             |
| `C-c C-r` | `daniel-claudy-resume`                | `/resume` another session in this pane (C-u: every repo) |
| `C-c C-u` | `daniel-claudy-usage`                 | fetch usage limits via `claude -p /usage`     |
| `C-c C-k` | `daniel-claudy-exit-this-session`     | `/exit` the session (asks first)              |

`revert-buffer` re-renders too. These shadow the markdown-mode keys on the
same chords; the buffer is a transcript, not a document you edit.

Also available: `daniel-claudy-direct-prompt` - one-off `claude -p` question
on the selection, answer pops in a buffer.

## How sending works

A send goes through `herdr agent prompt`, targeting the pane whose Claude
session id matches the transcript. That pastes bracketed, so a multi-paragraph
prompt arrives as one prompt. A session herdr reports as `blocked` (a
permission or question dialog) refuses a prompt; the text is then typed raw
into the pane with Enter, which is how you answer such a dialog anyway.

A new session (`daniel-claudy-new-session`, or typing an unknown name in
`daniel-claudy-view`) opens a new herdr workspace in the project you pick,
labelled with the session name, and runs `claude` in its root pane.

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

## Settings

`M-x customize-group RET daniel-claudy`: projects dir, sessions dir, max
sessions offered, modeline poll interval, `claude -p` directory, long-send
confirmation limits.
