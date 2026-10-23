;;; daniel-claudy.el --- View and drive Claude Code sessions from Emacs -*- lexical-binding: t; -*-

;; Author: Daniel Habib Vieira da Silva
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (markdown-mode "2.5"))
;; Keywords: tools, processes

;;; Commentary:

;; A viewer for Claude Code sessions, plus a loop to talk to them through herdr.
;; Claude stores every session as a newline-delimited JSON file under
;; `daniel-claudy-projects-dir'.  `daniel-claudy-view' picks a session and
;; renders it as markdown in its own `*claudy: PROJECT - TITLE*' buffer
;; (`daniel-claudy-mode').  Type a prompt under the transcript and
;; `daniel-claudy-send-rest' pastes it into the herdr pane running that
;; session.
;;
;; Loading this file only defines things.  Opt in to the modeline segment with
;; `(daniel-claudy-modeline-mode 1)' and add `daniel-claudy-modeline-string' to
;; `global-mode-string' or `mode-line-format'.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'seq)
(require 'filenotify)
(require 'project)
(require 'markdown-mode)

(declare-function evil-visual-state-p "evil-states")
(declare-function evil-visual-range "evil-common")
(declare-function evil-range-beginning "evil-common")
(declare-function evil-range-end "evil-common")
(declare-function evil-exit-visual-state "evil-states")
(declare-function evil-normal-state "evil-states")
(declare-function evil-insert-state "evil-states")

(defgroup daniel-claudy nil
  "View and drive Claude Code sessions."
  :group 'tools)

(defcustom daniel-claudy-projects-dir "~/.claude/projects/"
  "Directory where Claude Code stores per-project session files."
  :type 'directory)

(defcustom daniel-claudy-max-sessions 20
  "Maximum number of sessions to offer in `daniel-claudy-view' with a prefix."
  :type 'integer)

(defcustom daniel-claudy-sessions-dir "~/.claude/sessions/"
  "Directory where Claude Code records one JSON file per running session."
  :type 'directory)

(defcustom daniel-claudy-direct-prompt-directory temporary-file-directory
  "Directory `daniel-claudy-direct-prompt' runs `claude -p' in.
Somewhere outside any project: a one-off question should not drag in a
project's CLAUDE.md and files."
  :type 'directory)

(defcustom daniel-claudy-long-send-lines 15
  "A send with more lines than this asks for confirmation first."
  :type 'integer)

(defcustom daniel-claudy-long-send-chars 1000
  "A send with more characters than this asks for confirmation first."
  :type 'integer)

(defcustom daniel-claudy-landed-timeout 10
  "Seconds a send waits for its prompt to show up in the transcript."
  :type 'number)

(defcustom daniel-claudy-new-session-timeout 300
  "Seconds to wait for a new session to come up before giving up on it.
Generous on purpose: claude blocks on a trust prompt the first time it runs in
a directory, and nobody is watching the clock while you answer it."
  :type 'number)

(defcustom daniel-claudy-new-session-poll 2
  "Seconds between checks for a new session's transcript.
Each check rescans `daniel-claudy-projects-dir', so this is not free."
  :type 'number)

(defcustom daniel-claudy-modeline-interval 60
  "Seconds between fallback refreshes of `daniel-claudy-modeline-string'."
  :type 'number)

(defface daniel-claudy-waiting
  '((t :foreground "#FF5555"))
  "Face for a session waiting on you.")

(defface daniel-claudy-header-claude
  '((((background dark)) :foreground "#90a0dc" :weight normal
     :background "#2a3644" :overline "#969faf" :extend t)
    (t :foreground "#4f5d8a" :weight normal
       :background "#dde3ec" :overline "#8a93a5" :extend t))
  "Face for the band behind a `#### Claude' header.")

(defface daniel-claudy-header-you
  '((((background dark)) :inherit daniel-claudy-header-claude
     :foreground "#65d5a8" :background "#1d3a33")
    (t :inherit daniel-claudy-header-claude
       :foreground "#1f6f5a" :background "#d8efe6"))
  "Face for the band behind a `#### You' header.")

(defface daniel-claudy-header-session
  '((t :inherit (bold mode-line) :box nil :extend t))
  "Face for the band behind the `### session:' line.")

(defface daniel-claudy-usage
  '((t :inherit bold))
  "Face for the usage limits shown in the mode line of a claudy buffer.")

(defvar-local daniel-claudy--current-file nil
  "Session file backing this claudy buffer, for refreshing.")

(defvar-local daniel-claudy--pane nil
  "herdr pane id running the Claude session shown in this claudy buffer.")

(defvar-local daniel-claudy--status-shown nil
  "Status symbol last appended at the bottom of this claudy buffer.
Re-rendering erases the buffer and kills this, so it is deliberately not a
permanent local.")

(defvar-local daniel-claudy-hide-tool-lines t
  "Non-nil to drop `[tool: ...]' lines when rendering this buffer.
Toggled by `daniel-claudy-toggle-tool-lines'.")

(defvar-local daniel-claudy--pending-pane nil
  "herdr pane of the session this buffer waits on, before it has a transcript.")

(defvar-local daniel-claudy--queued nil
  "Prompt a send took before the session was up, sent once it is.")

(defvar-local daniel-claudy--pending-file nil
  "Transcript of the session this buffer waits on, once it is up.
Held back from `daniel-claudy--current-file' until the first send: that is
what lets renders and status glyphs reach the buffer, and you are still
typing.")

(defvar-local daniel-claudy--awaiting nil
  "Non-nil when a send from this buffer awaits Claude finishing.
Armed by `daniel-claudy-send-rest' and cleared by
`daniel-claudy-notify-finished', which the Claude Code Stop hook calls.")

;; Re-rendering a session calls `daniel-claudy-mode', which kills buffer-local
;; variables; the per-session state must survive that.
(dolist (var '(daniel-claudy--current-file
               daniel-claudy--pane
               daniel-claudy--awaiting
               daniel-claudy-hide-tool-lines))
  (put var 'permanent-local t))

;;;; Parsing -------------------------------------------------------------------

(defun daniel-claudy--parse-bytes (file start)
  "Return (OBJECTS . NEXT) for the whole lines of session FILE from byte START.
OBJECTS are the JSON objects on those lines, in file order, each an alist (keys
are symbols); lines that fail to parse are skipped.  A last line with no
newline yet is still being written: it is left out, and NEXT, the byte after
the last newline, is where to read from next time.  A FILE not written yet - a
fresh session before its first prompt - has no objects."
  (let (objects (next start))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (when (file-exists-p file)
        (insert-file-contents-literally file nil start))
      (goto-char (point-max))
      (when (search-backward "\n" nil t)
        (delete-region (1+ (point)) (point-max))
        (setq next (+ start (buffer-size)))
        ;; Decoded by hand: a crash can leave NULs in the file, and detection
        ;; would then read it as binary and every non-ASCII line would fail to
        ;; parse.
        (dolist (line (split-string
                       (decode-coding-string (buffer-string) 'utf-8) "\n" t))
          (unless (string-blank-p line)
            (let ((obj (ignore-errors
                         (json-parse-string line
                                            :object-type 'alist
                                            :array-type 'list
                                            :null-object nil
                                            :false-object nil))))
              (when obj (push obj objects)))))))
    (cons (nreverse objects) next)))

(defun daniel-claudy--parse-file (file)
  "Return the JSON objects in session FILE as a list, in file order.
See `daniel-claudy--parse-bytes'."
  (car (daniel-claudy--parse-bytes file 0)))

(defun daniel-claudy--fold-file (cache file init fold)
  "Return FOLD reduced over the objects of session FILE, starting from INIT.
CACHE maps FILE to (SIZE NEXT STATE) from the last call.  Transcripts only
grow, so a same-size FILE is not read again and a grown one is read only from
NEXT, its new objects folded into the cached STATE.  A shrunk FILE was
rewritten: it is read again from INIT.  FOLD takes STATE and an object and
returns the new STATE."
  (let* ((key (expand-file-name file))
         (size (or (file-attribute-size (file-attributes key)) 0))
         (cached (gethash key cache))
         (cached (and cached (<= (nth 0 cached) size) cached)))
    (if (and cached (= (nth 0 cached) size))
        (nth 2 cached)
      (let* ((read (daniel-claudy--parse-bytes key (if cached (nth 1 cached) 0)))
             (state (seq-reduce fold (car read) (if cached (nth 2 cached) init))))
        (puthash key (list size (cdr read) state) cache)
        state))))

(defvar daniel-claudy--transcript-cache (make-hash-table :test #'equal)
  "`daniel-claudy--fold-file' cache of rendered sections, newest first.")

(defun daniel-claudy--tool-summary (input)
  "Return a short one-line summary of a tool_use INPUT alist."
  (let ((val (or (alist-get 'command input)
                 (alist-get 'file_path input)
                 (alist-get 'pattern input)
                 (alist-get 'description input)
                 (alist-get 'path input)
                 (alist-get 'url input))))
    (when (stringp val)
      (car (split-string val "\n" t)))))

(defun daniel-claudy--render-assistant (msg)
  "Return the rendered text for an assistant MSG alist, or nil if empty.
MSG is the `message' sub-alist of an assistant line."
  (let ((parts nil))
    (dolist (block (alist-get 'content msg))
      (let ((btype (alist-get 'type block)))
        (cond
         ((equal btype "text")
          (let ((text (alist-get 'text block)))
            (when (and (stringp text) (not (string-blank-p text)))
              (push text parts))))
         ((and (equal btype "tool_use") (not daniel-claudy-hide-tool-lines))
          (let* ((name (alist-get 'name block))
                 (summary (daniel-claudy--tool-summary (alist-get 'input block))))
            (push (format "  [tool: %s%s]"
                          name (if summary (concat " " summary) ""))
                  parts))))))
    (when parts
      (concat "#### Claude\n\n" (string-join (nreverse parts) "\n\n")))))

(defun daniel-claudy--transcript-section (obj)
  "Return the markdown section for transcript object OBJ, or nil for none."
  (let ((type (alist-get 'type obj))
        (msg (alist-get 'message obj)))
    (cond
     ;; `isMeta' is Claude Code talking to itself - the reminder it injects
     ;; after a `/rename', say - not anything you typed.
     ((and (equal type "user") (not (alist-get 'isMeta obj)))
      (let ((content (alist-get 'content msg)))
        ;; A plain string is a typed prompt; an array is tool results (skip).
        (when (and (stringp content) (not (string-blank-p content)))
          (concat "#### You\n\n" content))))
     ((equal type "assistant")
      (daniel-claudy--render-assistant msg)))))

(defun daniel-claudy--transcript-string (file)
  "Return the full transcript of session FILE as a markdown string."
  ;; the cache outlives a tool-lines toggle, so it keeps each section both ways
  (let* ((pairs (daniel-claudy--fold-file
                 daniel-claudy--transcript-cache file nil
                 (lambda (pairs obj)
                   (let ((hidden (let ((daniel-claudy-hide-tool-lines t))
                                   (daniel-claudy--transcript-section obj)))
                         (shown (let ((daniel-claudy-hide-tool-lines nil))
                                  (daniel-claudy--transcript-section obj))))
                     (if (or hidden shown) (cons (cons hidden shown) pairs) pairs)))))
         (sections (delq nil (mapcar (if daniel-claudy-hide-tool-lines #'car #'cdr)
                                     pairs))))
    (concat (string-join (reverse sections) "\n\n") "\n")))

;;;; Session discovery / picker ------------------------------------------------

(defun daniel-claudy--newest-first (files)
  "Return FILES sorted by modification time, newest first."
  (let ((file-name-handler-alist nil))
    (mapcar #'cdr
            (sort (mapcar (lambda (f)
                            (cons (file-attribute-modification-time
                                   (file-attributes f))
                                  f))
                          files)
                  (lambda (a b) (time-less-p (car b) (car a)))))))

(defun daniel-claudy--all-session-files ()
  "Return every session file, newest first."
  (let* ((file-name-handler-alist nil)
         (dir (expand-file-name daniel-claudy-projects-dir))
         (files (when (file-directory-p dir)
                  (directory-files-recursively dir "\\.jsonl\\'"))))
    (daniel-claudy--newest-first
     (seq-remove (lambda (f) (string-match-p "/subagents/" f)) files))))

(defun daniel-claudy--session-ids-files (ids)
  "Return the transcript files of session IDS, newest first."
  (let ((file-name-handler-alist nil)
        (dir (expand-file-name daniel-claudy-projects-dir)))
    (daniel-claudy--newest-first
     (mapcan (lambda (id)
               (file-expand-wildcards
                (expand-file-name (concat "*/" id ".jsonl") dir) t))
             ids))))

(defun daniel-claudy--session-files ()
  "Return recent session files, newest first.
At most `daniel-claudy-max-sessions' files are returned."
  (seq-take (daniel-claudy--all-session-files) daniel-claudy-max-sessions))

(defun daniel-claudy--live-session-records ()
  "Return the PID.json contents of the Claude Code processes running right now.
Claude writes PID.json into `daniel-claudy-sessions-dir' while a session lives
and deletes it on exit; the pid is re-checked so a file left behind by a crash
does not count as live."
  (let ((dir (expand-file-name daniel-claudy-sessions-dir)))
    (when (file-directory-p dir)
      (delq nil
            (mapcar
             (lambda (f)
               (let* ((json (ignore-errors
                              (with-temp-buffer
                                (insert-file-contents f)
                                (json-parse-buffer :object-type 'alist
                                                   :array-type 'list
                                                   :null-object nil
                                                   :false-object nil))))
                      (pid (alist-get 'pid json)))
                 (and (numberp pid)
                      (process-attributes pid)
                      json)))
             (directory-files dir t "\\.json\\'"))))))

(defun daniel-claudy--live-session-ids ()
  "Return the session ids of the Claude Code processes running right now."
  (delq nil (mapcar (lambda (json) (alist-get 'sessionId json))
                    (daniel-claudy--live-session-records))))

(defconst daniel-claudy--states
  '(("waiting" "❗" daniel-claudy-waiting)
    ("busy"    "⏳" shadow)
    ("shell"   "🐚" shadow)
    ("idle"    "✅" shadow))
  "Symbol and face per session status, most attention-worthy first.")

(defun daniel-claudy--status-symbol (status)
  "Return the symbol for session STATUS.
A session that is not running has no status; it gets blanks so the columns after
it still line up."
  (or (nth 1 (assoc status daniel-claudy--states)) "  "))

(defun daniel-claudy--live-session-statuses ()
  "Return an alist of (SESSION-ID . STATUS) for the sessions running right now."
  (delq nil (mapcar (lambda (json)
                      (let ((id (alist-get 'sessionId json)))
                        (when id
                          (cons id (or (alist-get 'status json) "idle")))))
                    (daniel-claudy--live-session-records))))

(defun daniel-claudy--live-session-files ()
  "Return the session files of Claude sessions running right now, newest first.
`daniel-claudy-max-sessions' does not apply: there are only ever a handful, and
a long-running one would otherwise fall off the end of the recent list."
  (daniel-claudy--session-ids-files (daniel-claudy--live-session-ids)))

(defun daniel-claudy--typed-prompt (obj)
  "Return the first line of the prompt typed by the user in entry OBJ, or nil.
Tool results, injected reminders and the XML wrappers Claude Code writes for
slash commands and caveats are not prompts, so they are skipped."
  (and (equal (alist-get 'type obj) "user")
       (not (alist-get 'isMeta obj))
       (not (alist-get 'isSidechain obj))
       (let* ((content (alist-get 'content (alist-get 'message obj)))
              (text (cond
                     ((stringp content) content)
                     ;; An array is tool results plus, for a prompt with an
                     ;; attachment, one text part: that part is what was typed.
                     ((listp content)
                      (alist-get 'text
                                 (seq-find (lambda (part)
                                             (equal (alist-get 'type part) "text"))
                                           content))))))
         (when (stringp text)
           ;; Claude Code wraps a bracketed paste - every send - in this tag.
           (let ((line (car (split-string
                             (replace-regexp-in-string
                              "\\`[ \t\n]*<pasted_content[^>]*>" "" text)
                             "\n" t))))
             (and line (not (string-prefix-p "<" line)) line))))))

(defvar daniel-claudy--meta-cache (make-hash-table :test #'equal)
  "`daniel-claudy--fold-file' cache of session meta, the untruncated
\(CWD PROJECT NAME SUMMARY FIRST-PROMPT LAST-PROMPT).")

(defun daniel-claudy--session-meta (file)
  "Return a plist describing session FILE.
:cwd is the directory the session started in, :project its basename, :name
the `/rename' session name
\(`customTitle\'), :summary the auto session summary (`aiTitle\', the line
Claude Code shows at the bottom of its TUI), :first-prompt the first typed
prompt and :last-prompt the most recent one.  Every key but :project may be nil."
  (pcase-let
      ((`(,cwd ,project ,name ,summary ,first-prompt ,last-prompt)
        ;; No early-out: the latest prompt is only known once the file is
        ;; exhausted.
        (daniel-claudy--fold-file
         daniel-claudy--meta-cache file nil
         (lambda (state obj)
           (pcase-let ((`(,cwd ,project ,name ,summary ,first-prompt ,last-prompt)
                        state)
                       (type (alist-get 'type obj)))
             (unless cwd
               (let ((dir (alist-get 'cwd obj)))
                 (when (stringp dir)
                   (setq cwd dir
                         project (file-name-nondirectory (directory-file-name dir))))))
             (when (equal type "custom-title")
               (setq name (alist-get 'customTitle obj)))
             (when (equal type "ai-title")
               (setq summary (alist-get 'aiTitle obj)))
             (let ((prompt (daniel-claudy--typed-prompt obj)))
               (when prompt
                 (unless first-prompt (setq first-prompt prompt))
                 (setq last-prompt prompt)))
             (list cwd project name summary first-prompt last-prompt))))))
    (list :cwd cwd
          :project (or project "?")
          :name name
          :summary summary
          :first-prompt (and first-prompt
                             (truncate-string-to-width first-prompt 60 nil nil "…"))
          :last-prompt (and last-prompt
                            (truncate-string-to-width last-prompt 60 nil nil "…")))))

(defun daniel-claudy--meta-label (meta file)
  "Return the best single-line name for META of FILE.
The `/rename' name wins over the auto summary, which wins over the first prompt."
  (or (plist-get meta :name)
      (plist-get meta :summary)
      (plist-get meta :first-prompt)
      (file-name-base file)))

(defun daniel-claudy--repo (dir)
  "Return the root of the git repo DIR is in, a worktree counting as its repo.
DIR itself when it is in no repo.  The worktree is cut off by its path, not
asked of git: a removed worktree no longer exists to ask."
  (let ((dir (expand-file-name dir)))
    (when (string-match "\\`\\(.*?\\)/\\.claude/worktrees/" dir)
      (setq dir (match-string 1 dir)))
    (file-name-as-directory (or (locate-dominating-file dir ".git") dir))))

(defun daniel-claudy--candidates (&optional all repo)
  "Return an alist of (LABEL . FILE) for the session picker.
Waiting sessions come first, then idle ones, then busy and shell ones, each
group newest first.
Only sessions running right now, or every recent session when ALL is non-nil.
With REPO, only the sessions started inside that `daniel-claudy--repo'.
Each label leads with the session's status symbol."
  (let* ((statuses (daniel-claudy--live-session-statuses))
         (rows
          (delq
           nil
           (mapcar
            (lambda (file)
              (let* ((meta (daniel-claudy--session-meta file))
                     (cwd (plist-get meta :cwd))
                     (mtime (file-attribute-modification-time (file-attributes file))))
                (when (or (not repo)
                          (and cwd (equal (daniel-claudy--repo cwd) repo)))
                  (list file
                        (daniel-claudy--status-symbol
                         (cdr (assoc (file-name-base file) statuses)))
                        (truncate-string-to-width
                         (plist-get meta :project) 24 nil nil "…")
                        (truncate-string-to-width
                         (or (plist-get meta :name) "-") 30 nil nil "…")
                        (or (plist-get meta :last-prompt) "(no prompt yet)")
                        (format-time-string "%Y-%m-%d %H:%M" mtime)))))
            (if all (daniel-claudy--session-files) (daniel-claudy--live-session-files)))))
         ;; Busy and shell sessions need nothing from you, so they sink.
         ;; `sort' is stable, so each group stays newest first.
         (rank (lambda (r)
                 (cond ((equal (nth 1 r) (daniel-claudy--status-symbol "waiting")) 0)
                       ((member (nth 1 r) (mapcar #'daniel-claudy--status-symbol
                                                  '("busy" "shell")))
                        2)
                       (t 1))))
         (rows (sort rows (lambda (a b) (< (funcall rank a) (funcall rank b)))))
         (widest (lambda (n) (apply #'max 0 (mapcar (lambda (r) (string-width (nth n r))) rows))))
         (pw (funcall widest 2))
         (nw (funcall widest 3))
         ;; The prompt gets what the frame has left once the date is pinned right.
         (qw (max 20 (- (frame-width) 2 pw 2 nw 2 2 17))))
    (mapcar (lambda (r)
              (cons (concat (format (format "%%s %%-%ds  %%-%ds  " pw nw)
                                    (nth 1 r) (nth 2 r) (nth 3 r))
                            (truncate-string-to-width (nth 4 r) qw nil nil "…")
                            (propertize " " 'display '(space :align-to (- right 17)))
                            (nth 5 r))
                    (nth 0 r)))
            rows)))

;;;; Rendering + mode ----------------------------------------------------------

(defun daniel-claudy--live-record (id &optional records)
  "Return the live PID.json record of session ID, or nil when it is not running.
RECORDS defaults to `daniel-claudy--live-session-records'; pass it in when
looping over several buffers."
  (seq-find (lambda (r) (equal (alist-get 'sessionId r) id))
            (or records (daniel-claudy--live-session-records))))

(defun daniel-claudy--session-cwd (file)
  "Return the working directory of session FILE, or nil.
A running session reports its current one, which `EnterWorktree' moves; the
transcript only has the directory it started in."
  (let ((live (alist-get 'cwd (daniel-claudy--live-record (file-name-base file)))))
    (if (stringp live)
        (file-name-as-directory live)
      (let ((cwd (plist-get (daniel-claudy--session-meta file) :cwd)))
        (and cwd (file-name-as-directory cwd))))))

(defun daniel-claudy--buffer-for-file (file)
  "Return the claudy buffer showing session FILE, or nil.
Matched by session id, not path: `EnterWorktree' moves the transcript to the
worktree's project dir."
  (let ((id (file-name-base file)))
    (seq-find (lambda (buf)
                (with-current-buffer buf
                  (and (derived-mode-p 'daniel-claudy-mode)
                       daniel-claudy--current-file
                       (equal (file-name-base daniel-claudy--current-file) id))))
              (buffer-list))))

(defun daniel-claudy--display (buffer)
  "Select BUFFER as the only window in the frame.
A transcript is a wall of text; sharing the frame makes it unreadable.
Re-rendering the buffer you are reading is not a jump; coming from elsewhere
pushes the mark there."
  (unless (eq buffer (current-buffer))
    (push-mark nil t))
  ;; Re-rendering erases the buffer, which collapses the point marker Emacs
  ;; saved in `window-prev-buffers'; let the buffer's own point win instead.
  (let ((switch-to-buffer-preserve-window-point nil))
    (switch-to-buffer buffer))
  (delete-other-windows)
  buffer)

(defun daniel-claudy--recenter (line)
  "Scroll so point is on window LINE, when the selected window shows this buffer.
A background render has no window to scroll."
  (when (eq (window-buffer) (current-buffer))
    (recenter line)))

(defun daniel-claudy--session-status (file &optional statuses)
  "Return the live status of session FILE, or nil when it is not running.
STATUSES defaults to `daniel-claudy--live-session-statuses', which re-reads the
session files; pass it in when looping over several buffers."
  (cdr (assoc (file-name-base file)
              (or statuses (daniel-claudy--live-session-statuses)))))

(defun daniel-claudy--file-status-symbol (file &optional statuses)
  "Return the live status symbol for session FILE, or nil when it is not running."
  (let ((status (daniel-claudy--session-status file statuses)))
    (and status (nth 1 (assoc status daniel-claudy--states)))))

(defun daniel-claudy--append-status (symbol)
  "Append SYMBOL at the bottom of the current claudy buffer.
A session that is not running has no SYMBOL and gets nothing appended."
  (when symbol
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert symbol "\n"))))
  (setq daniel-claudy--status-shown symbol))

(defun daniel-claudy--buffer-name (file)
  "Return a `*claudy: PROJECT - TITLE*' buffer name for session FILE."
  (let ((meta (daniel-claudy--session-meta file)))
    (format "*claudy: %s - %s*"
            (plist-get meta :project)
            (truncate-string-to-width
             (daniel-claudy--meta-label meta file) 24 nil nil "…"))))

(defun daniel-claudy--band-headers ()
  "Band the session line and every `#### You' and `#### Claude' line.
Overlays, because markdown font-lock owns the `face' property here."
  (remove-overlays (point-min) (point-max) 'daniel-claudy-header t)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward
            "^\\(?:#### \\(You\\|Claude\\)\\|### \\(?:new \\)?session: .*\\)$" nil t)
      (let ((ov (make-overlay (line-beginning-position)
                              (min (point-max) (1+ (line-end-position)))))
            (who (match-string 1)))
        (overlay-put ov 'daniel-claudy-header t)
        (overlay-put ov 'face (cond ((null who) 'daniel-claudy-header-session)
                                    ((equal who "You") 'daniel-claudy-header-you)
                                    (t 'daniel-claudy-header-claude)))))))

(defun daniel-claudy--render (file &optional background)
  "Render session FILE into its own buffer and display it.
The session's buffer is reused when it is already open.  With BACKGROUND
non-nil, render without displaying or selecting the buffer."
  (let* ((existing (daniel-claudy--buffer-for-file file))
         (buf (or existing (generate-new-buffer (daniel-claudy--buffer-name file)))))
    (with-current-buffer buf
      ;; Re-rendering erases the buffer, so remember where the reader was.
      (let ((opoint (and existing (point))))
        (read-only-mode -1)
        (erase-buffer)
        (insert (format "### session: %s\n\n" (file-name-base file)))
        (insert (daniel-claudy--transcript-string file))
        (daniel-claudy-mode)
        (daniel-claudy--band-headers)
        (daniel-claudy--append-status (daniel-claudy--file-status-symbol file))
        ;; `goto-char' clamps, so a shrunken transcript lands at its end.
        (goto-char (or opoint (point-min)))
        (let ((cwd (daniel-claudy--session-cwd file)))
          (when (and cwd (file-directory-p cwd))
            (setq default-directory cwd)))
        (setq daniel-claudy--current-file file)
        ;; The session title changes once the auto `aiTitle' arrives; follow it.
        (let ((name (daniel-claudy--buffer-name file)))
          (unless (or (equal name (buffer-name)) (get-buffer name))
            (rename-buffer name)))))
    (unless background (daniel-claudy--display buf))
    buf))

;;;###autoload
(defun daniel-claudy-view (&optional all)
  "Pick a running Claude session and view its transcript.
With a prefix argument, ALL, pick from every recent session instead.
Typing text no session matches starts a new session named after it."
  (interactive "P")
  (let* ((candidates (daniel-claudy--candidates all))
         ;; Preserve newest-first order in the completion UI.
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (category . daniel-claudy-session)
                                 (display-sort-function . identity))
                    (complete-with-action action candidates string pred))))
         ;; No `require-match': a miss is the way in to a new session, not a
         ;; dead end.
         (choice (and candidates
                      (completing-read
                       (if all "Claude session: "
                         "Live Claude session (C-u for all): ")
                       table nil nil)))
         (file (cdr (assoc choice candidates))))
    (cond
     ;; What you typed named nothing, so let it name the new session.  The
     ;; directory picker is the only confirmation needed: `C-g' there costs
     ;; nothing.
     ((null file) (daniel-claudy-new-session choice))
     ;; A session waiting on an answer wants the terminal, not the transcript:
     ;; render it out of sight and hand the frame straight to herdr.
     ((equal (daniel-claudy--session-status file) "waiting")
      (with-current-buffer (daniel-claudy--render file 'background)
        (daniel-claudy-focus-pane)))
     (t
      ;; Always re-render: a live session has grown since it was last opened.
      ;; A buffer you already read keeps its point; only a fresh one parks on
      ;; Claude's latest answer.
      (let ((existing (daniel-claudy--buffer-for-file file)))
        (with-current-buffer (daniel-claudy--render file)
          (unless existing
            (daniel-claudy--park-on-answer))))))))

(defconst daniel-claudy--tool-line-re "^[ \t]*\\[tool: .*\\]$"
  "Matches a rendered `[tool: ...]' line.")

(defun daniel-claudy--answer-start ()
  "Return the start of Claude's latest answer, or nil when there is none.
A `#### Claude' section holding only `[tool: ...]' lines is Claude working, not
answering, so it is skipped."
  (save-excursion
    (goto-char (point-max))
    (catch 'found
      (while (re-search-backward "^#### Claude$" nil t)
        (let ((start (point))
              (end (save-excursion
                     (forward-line 1)
                     (if (re-search-forward "^#### \\(?:You\\|Claude\\)$" nil t)
                         (match-beginning 0)
                       (point-max)))))
          (save-excursion
            (forward-line 1)
            (while (< (point) end)
              (let ((line (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position))))
                (when (and (not (string-blank-p line))
                           (not (string-match-p daniel-claudy--tool-line-re line)))
                  (throw 'found start)))
              (forward-line 1))))))))

(defun daniel-claudy--park-on-answer ()
  "Park the selected window on the `#### Claude' header of the latest answer.
Without an answer to show, fall back to the end of the buffer."
  (let ((start (daniel-claudy--answer-start)))
    (if start
        (progn
          (goto-char start)
          (daniel-claudy--recenter 1))
      (goto-char (point-max))
      (daniel-claudy--recenter -2))))

(defun daniel-claudy--park-at-end ()
  "Put point at the end of the buffer and recenter.
A brand new session has no answer to park on and nothing above worth reading:
the only useful spot is the bottom, ready for the first send.  Under evil the
state is forced to normal: the buffer is displayed from a timer, which can
hand it over in whatever state was current when it fired."
  (goto-char (point-max))
  (when (bound-and-true-p evil-local-mode) (evil-normal-state))
  (daniel-claudy--recenter -2))

(defun daniel-claudy-refresh ()
  "Re-render the session shown in the current claudy buffer."
  (interactive)
  (if daniel-claudy--current-file
      ;; Park on Claude's latest answer (handy for a live session).
      (with-current-buffer (daniel-claudy--render daniel-claudy--current-file)
        (daniel-claudy--park-on-answer))
    (user-error "No Claude session associated with this buffer")))

(defun daniel-claudy-jump-to-question ()
  "Re-render the current claudy buffer and park on your latest question."
  (interactive)
  (daniel-claudy-refresh)
  (goto-char (point-max))
  (when (re-search-backward "^#### You$" nil t)
    (daniel-claudy--recenter 1)))

(defun daniel-claudy-toggle-tool-lines ()
  "Toggle the `[tool: ...]' lines in the session shown in this buffer."
  (interactive)
  (unless daniel-claudy--current-file
    (user-error "No Claude session associated with this buffer"))
  (setq daniel-claudy-hide-tool-lines (not daniel-claudy-hide-tool-lines))
  (daniel-claudy--render daniel-claudy--current-file)
  (message "Tool lines %s" (if daniel-claudy-hide-tool-lines "hidden" "shown")))

;;;; herdr integration ---------------------------------------------------------
;;
;; A Claude session always runs inside a herdr pane, in the session's cwd.
;; These commands let you type in the claudy buffer and shoot lines straight
;; into that pane.  herdr's Claude integration reports each session id to the
;; pane hosting it, so the pane is looked up by session id and remembered
;; buffer-locally; you are only prompted when the session is not running (or
;; has since moved).

(defun daniel-claudy--herdr (&rest args)
  "Run `herdr ARGS' and return its output.
Signal a `user-error' carrying herdr's error JSON when it fails."
  (with-temp-buffer
    (let ((status (apply #'call-process "herdr" nil t nil args)))
      (if (eq status 0)
          (buffer-string)
        (user-error "herdr %s: %s" (string-join args " ")
                    (string-trim (buffer-string)))))))

(defun daniel-claudy--herdr-result (&rest args)
  "Return the `result' of `herdr ARGS', a JSON-printing command, as an alist."
  (alist-get 'result
             (json-parse-string (apply #'daniel-claudy--herdr args)
                                :object-type 'alist :array-type 'list
                                :null-object nil :false-object nil)))

(defun daniel-claudy--agents ()
  "Return the herdr agent records of the panes running Claude Code.
Each is an alist: `pane_id' is the pane, `agent_status' herdr's view of it
\(idle, working, blocked, done) and `agent_session' holds the Claude session id."
  (seq-filter (lambda (a) (equal (alist-get 'agent a) "claude"))
              (alist-get 'agents (daniel-claudy--herdr-result "agent" "list"))))

(defun daniel-claudy--agent-session-id (agent)
  "Return the Claude session id of herdr AGENT, or nil."
  (alist-get 'value (alist-get 'agent_session agent)))

(defun daniel-claudy--pane-agent (pane &optional agents)
  "Return the Claude agent record hosted by herdr PANE, or nil.
AGENTS defaults to `daniel-claudy--agents'."
  (seq-find (lambda (a) (equal (alist-get 'pane_id a) pane))
            (or agents (daniel-claudy--agents))))

(defun daniel-claudy--pane-live-p (pane)
  "Return non-nil if herdr PANE still exists."
  (and (ignore-errors (daniel-claudy--herdr "pane" "get" pane)) t))

(defun daniel-claudy--pane-choices (agents)
  "Return a (LABEL . PANE-ID) alist for AGENTS, labelled by session name and path.
The session name is what tells two sessions in one directory apart; pane ids
do not."
  (let ((records (daniel-claudy--live-session-records)))
    (mapcar (lambda (a)
              (cons (format "%-24s  %s"
                            (or (alist-get 'name
                                           (daniel-claudy--live-record
                                            (daniel-claudy--agent-session-id a)
                                            records))
                                (alist-get 'pane_id a))
                            (alist-get 'cwd a))
                    (alist-get 'pane_id a)))
            agents)))

(defun daniel-claudy--session-pane (file)
  "Return the herdr pane id hosting session FILE, or nil when it is not running."
  (let ((id (file-name-base file)))
    (alist-get 'pane_id
               (seq-find (lambda (a) (equal (daniel-claudy--agent-session-id a) id))
                         (daniel-claudy--agents)))))

(defun daniel-claudy--select-pane ()
  "Return the herdr pane id for this session, auto-detecting or prompting.
Claude panes whose cwd matches the session cwd are preferred; a unique match is
used without asking."
  (let* ((agents (daniel-claudy--agents))
         (cwd (and daniel-claudy--current-file
                   (daniel-claudy--session-cwd daniel-claudy--current-file)))
         (cwd (and cwd (directory-file-name (expand-file-name cwd))))
         (matches (and cwd
                       (seq-filter
                        (lambda (a)
                          (equal (directory-file-name
                                  (expand-file-name (alist-get 'cwd a)))
                                 cwd))
                        agents))))
    (cond
     ((null agents) (user-error "No herdr pane runs Claude (is herdr running?)"))
     ((= (length matches) 1) (alist-get 'pane_id (car matches)))
     (t (let* ((table (daniel-claudy--pane-choices (or matches agents)))
               (choice (completing-read "herdr pane for this session: "
                                        table nil t)))
          (cdr (assoc choice table)))))))

(defun daniel-claudy--pane ()
  "Return this buffer's herdr pane id, (re)discovering it when needed.
herdr's own record wins over the cache: a cached pane can be alive and still
wrong, once that session exited and another claude took its pane."
  (setq daniel-claudy--pane
        (or (and daniel-claudy--current-file
                 (daniel-claudy--session-pane daniel-claudy--current-file))
            (and daniel-claudy--pane
                 (daniel-claudy--pane-live-p daniel-claudy--pane)
                 daniel-claudy--pane)
            (daniel-claudy--select-pane))))

(defun daniel-claudy-focus-pane ()
  "Focus the session's herdr workspace, tab and pane.
Switches the herdr client; bringing the terminal itself to the front is up to
your window manager."
  (interactive)
  (daniel-claudy--herdr "agent" "focus" (daniel-claudy--pane)))

(defun daniel-claudy--send-text (pane text &optional quiet)
  "Submit TEXT to the Claude session in herdr PANE.
`herdr agent prompt' pastes it bracketed, so embedded newlines stay in Claude's
prompt instead of submitting at the first one, and follows with Enter.  A
session blocked on a question refuses a prompt; the answer is typed there raw,
as you would.  With QUIET, say nothing: a send you did not type does not belong
in the echo area."
  (setq text (string-trim text))
  (when (string-empty-p text)
    (user-error "Nothing to send"))
  ;; ponytail: text and Enter go as one submission, so an `@image.png' Claude is
  ;; still reading when the Enter lands may drop it; split into `pane send-text'
  ;; plus a delayed `send-keys enter' if that bites
  (condition-case err
      ;; a prompt ending in `@path' leaves Claude's file picker open, and it
      ;; eats the Enter; the trailing space closes the picker and Claude trims it
      (daniel-claudy--herdr "agent" "prompt" pane (concat text " "))
    (user-error
     (unless (string-match-p "agent_blocked" (cadr err))
       (signal (car err) (cdr err)))
     (daniel-claudy--herdr "pane" "send-text" pane text)
     (daniel-claudy--herdr "pane" "send-keys" pane "enter")))
  (unless quiet
    (message "Sent to herdr %s:\n%s" pane text)))

(defun daniel-claudy--selection-text ()
  "Return the selected text, or nil when nothing is selected.
Under evil the plain region lags the visual selection: it drops the character
under point in charwise mode and ignores the linewise expansion of `V'.
Evil's own range has both right.  Sending exits visual state, like every other
evil visual command."
  (cond ((and (bound-and-true-p evil-local-mode) (evil-visual-state-p))
         (let ((range (evil-visual-range)))
           (prog1 (buffer-substring-no-properties (evil-range-beginning range)
                                                  (evil-range-end range))
             (evil-exit-visual-state))))
        ((use-region-p)
         (buffer-substring-no-properties (region-beginning) (region-end)))))

(defun daniel-claudy-send-current-line ()
  "Send the current line (or the selection) to the session's herdr pane."
  (interactive)
  (daniel-claudy--send-text
   (daniel-claudy--pane)
   (or (daniel-claudy--selection-text)
       (buffer-substring-no-properties
        (line-beginning-position) (line-end-position)))))

(defconst daniel-claudy--status-trail-re
  (concat "\\(?:\\`\\|\n\\)\\(?:[ \t]*\\(?:"
          (regexp-opt (mapcar (lambda (state) (nth 1 state)) daniel-claudy--states))
          "\\)[ \t]*\n?\\)+\\'")
  "Matches the run of status glyphs parked below the transcript.
A run, not one line: `daniel-claudy--refresh-status-marks' appends a glyph per
state change without erasing, so the bottom collects a trail like `⏳ 🐚 ⏳'.")

(defun daniel-claudy--strip-status (text)
  "TEXT without the status glyphs the renderer parks below the transcript.
A send reaches point-max, and that trail is the buffer talking, not you.  Only
a line that is nothing but a glyph goes; a glyph you typed inside a line of
your own stays."
  (replace-regexp-in-string daniel-claudy--status-trail-re "" text))

(defun daniel-claudy-send-rest ()
  "Send the selection, or everything from point down, to the session's herdr pane.
A prompt written over several paragraphs goes in one send, not one paragraph at
a time.  Arms `daniel-claudy--awaiting' so the buffer auto-refreshes once
Claude's Stop hook reports the turn finished (see
`daniel-claudy-notify-finished')."
  (interactive)
  (daniel-claudy--send
   (or (daniel-claudy--selection-text)
       (daniel-claudy--strip-status
        (buffer-substring-no-properties (line-beginning-position) (point-max))))))

(defun daniel-claudy--long-send-p (text)
  "Non-nil when TEXT is over `daniel-claudy-long-send-lines' lines or
`daniel-claudy-long-send-chars' characters."
  (or (> (length text) daniel-claudy-long-send-chars)
      (> (length (split-string text "\n")) daniel-claudy-long-send-lines)))

(defun daniel-claudy--long-send-prompt (text)
  "The confirmation prompt for TEXT: its first and last 8 words."
  (let* ((words (split-string (string-trim text) "[ \t\n\r\f]+" t))
         (n (length words)))
    (format "ARE YOU SURE YOU WANT TO SEND THIS LONG MESSAGE (%s)? "
            (if (<= n 16)
                (string-join words " ")
              (concat (string-join (seq-take words 8) " ") " ... "
                      (string-join (last words 8) " "))))))

(defun daniel-claudy--send (text)
  "Send TEXT to the session's herdr pane, as `daniel-claudy-send-rest' does.
Queues it while a new session starts; otherwise sends it and arms
`daniel-claudy--awaiting' (a queued prompt is armed once
`daniel-claudy--adopt-new-session' sends it).
A long TEXT (see `daniel-claudy--long-send-p') asks for confirmation first."
  (when (and (daniel-claudy--long-send-p text)
             (not (y-or-n-p (daniel-claudy--long-send-prompt text))))
    (user-error "Not sent"))
  (if (and daniel-claudy--pending-pane (not daniel-claudy--pending-file))
      (progn
        (when (string-blank-p text) (user-error "Nothing to send"))
        (setq daniel-claudy--queued (string-trim text))
        (message "Queued: sends once claude is up"))
    (let ((pane (or daniel-claudy--pending-pane (daniel-claudy--pane))))
      (when daniel-claudy--pending-file
        (setq daniel-claudy--current-file daniel-claudy--pending-file
              daniel-claudy--pending-file nil
              daniel-claudy--pending-pane nil))
      (daniel-claudy--refresh-when-landed (current-buffer) text)
      (daniel-claudy--send-text pane text))
    (setq daniel-claudy--awaiting t)))

(defun daniel-claudy--prompt-count (file line)
  "How many prompts typed in session FILE start with LINE."
  (seq-count (lambda (obj) (equal (daniel-claudy--typed-prompt obj) line))
             (daniel-claudy--parse-file file)))

(defun daniel-claudy--refresh-to-bottom (buf)
  "Re-render BUF in the background and park each of its windows at the bottom.
Windows stay as they are: you may be typing the next prompt."
  (with-current-buffer buf
    ;; the render's `daniel-claudy-mode' wipes it, and the refresh at turn end
    ;; with it
    (let ((awaiting daniel-claudy--awaiting))
      (daniel-claudy--render daniel-claudy--current-file t)
      (setq daniel-claudy--awaiting awaiting))
    (goto-char (point-max))
    (dolist (win (get-buffer-window-list buf nil t))
      (with-selected-window win
        (goto-char (point-max))
        (daniel-claudy--recenter -2)))))

(defun daniel-claudy--refresh-when-landed (buf text)
  "Re-render BUF once the prompt TEXT shows up in its transcript.
Call it before sending: it counts the matching prompts already there, so
sending the same prompt twice still waits for the new one.  Claude writes the
prompt a moment after herdr hands it over, and a render before that proves
nothing.  Slash commands are not stored as prompts, so they are not watched."
  (when-let* ((line (car (split-string (string-trim text) "\n" t)))
              ((not (string-prefix-p "/" line)))
              (file (buffer-local-value 'daniel-claudy--current-file buf)))
    (let ((before (daniel-claudy--prompt-count file line))
          (waited 0)
          timer)
      (setq timer
            (run-with-timer
             0.5 0.5
             (lambda ()
               (setq waited (+ waited 0.5))
               (cond
                ((not (buffer-live-p buf)) (cancel-timer timer))
                ((> (daniel-claudy--prompt-count file line) before)
                 (cancel-timer timer)
                 (daniel-claudy--refresh-to-bottom buf))
                ((>= waited daniel-claudy-landed-timeout)
                 (cancel-timer timer)
                 (message "Claude: prompt not in the transcript after %ss"
                          daniel-claudy-landed-timeout)))))))))

;;;###autoload
(defun daniel-claudy-send-selection ()
  "Send the selection to a herdr pane running Claude, chosen by session name.
The global counterpart of `daniel-claudy-send-rest': it works in any buffer, so
there is no session cwd to match a pane against and you always pick the target
yourself."
  (interactive)
  ;; text first: reading the selection exits visual state, and the prompt below
  ;; would otherwise leave the region unusable if you abort it
  (let* ((text (or (daniel-claudy--selection-text)
                   (user-error "No selection to send")))
         (table (append (daniel-claudy--pane-choices (daniel-claudy--agents))
                        '(("+ new session" . new-session))))
         (target (cdr (assoc (completing-read "herdr claude pane: " table nil t)
                             table))))
    (pcase target
      ('new-session (daniel-claudy-new-session nil text))
      (_ (daniel-claudy--send-text target text)))))

;;;###autoload
(defun daniel-claudy-direct-prompt (text model)
  "Ask `claude -p' TEXT with MODEL in the background and pop its answer.
TEXT is the selection, or read when nothing is selected; MODEL is a `--model'
alias, haiku by default.  Runs in `daniel-claudy-direct-prompt-directory'."
  (interactive (list (or (daniel-claudy--selection-text)
                         (read-string "Prompt: "))
                     (completing-read "claude -p model: "
                                      '("haiku" "sonnet" "opus")
                                      nil t nil nil "haiku")))
  (let ((default-directory (file-name-as-directory
                            (expand-file-name daniel-claudy-direct-prompt-directory)))
        (name (format "*claudy -p: %s*"
                      (truncate-string-to-width
                       (car (split-string (string-trim text) "\n")) 50))))
    ;; EOF on stdin, or claude waits 3s for piped input and warns in the answer
    (process-send-eof
     (make-process
      :name "claudy-direct-prompt"
      :buffer (generate-new-buffer " *claudy-direct-prompt*")
      :command (list "claude" "-p" "--model" model text)
      ;; on a pty claude appends terminal escapes (cursor show) to the answer
      :connection-type 'pipe
      :noquery t
      :sentinel
      (lambda (proc _event)
        (unless (process-live-p proc)
          (let ((out (with-current-buffer (process-buffer proc) (buffer-string)))
                (buf (generate-new-buffer name)))
            (kill-buffer (process-buffer proc))
            (with-current-buffer buf
              (insert out)
              (gfm-mode)
              (goto-char (point-min)))
            (pop-to-buffer buf)
            (unless (zerop (process-exit-status proc))
              (message "claude -p exited with %d" (process-exit-status proc))))))))
    (message "claude -p: waiting...")))

;;;; Starting a new session -----------------------------------------------------

;; The picker can only show sessions that exist.  When the one you want does not,
;; the miss becomes the way to create it: pick a project, get a herdr workspace
;; running claude there, and open its transcript once it registers.

(defun daniel-claudy--read-project-dir ()
  "Read the directory a new session starts in.
Offers the projects `project' knows about; with none known, any directory."
  (let ((roots (project-known-project-roots)))
    (if roots
        (expand-file-name (completing-read "New Claude session in: " roots))
      (read-directory-name "New Claude session in: "))))

(defun daniel-claudy--read-session-name ()
  "Read the name for a new session.
No default: the name is what tells two sessions in one project apart, and a
directory basename is the one thing it never needs to say.  Read before the
herdr workspace exists, so refusing an empty one leaves nothing behind."
  (let ((name (string-trim (read-string "Session name: "))))
    (if (string-empty-p name)
        (user-error "A session needs a name")
      name)))

(defun daniel-claudy--new-claude-pane (dir label &rest args)
  "Open a herdr workspace in DIR, run claude ARGS in it, return its pane id.
One workspace per session, labelled LABEL when given.  `workspace create' hands
back the root pane, which is what lets `daniel-claudy--await-new-session' find
the session it starts."
  (let ((pane (alist-get 'pane_id
                         (alist-get 'root_pane
                                    (apply #'daniel-claudy--herdr-result
                                           "workspace" "create" "--focus"
                                           "--cwd" (expand-file-name dir)
                                           (and label (list "--label" label)))))))
    (daniel-claudy--herdr "pane" "run" pane
                          (combine-and-quote-strings (cons "claude" args)))
    pane))

(defun daniel-claudy--session-id-file (id)
  "Return the transcript file of session ID, or nil when it has none yet."
  (and id (car (daniel-claudy--session-ids-files (list id)))))

(defun daniel-claudy--pending-buffer (pane name display)
  "Open a buffer to type the first prompt of NAME in while claude starts.
PANE is the herdr pane it starts in.  Waiting for the transcript before
showing anything leaves you staring at nothing through the whole boot.
DISPLAY nil keeps the buffer in the background."
  (let ((buf (generate-new-buffer (format "*claudy: new - %s*" name))))
    (with-current-buffer buf
      (daniel-claudy-mode)
      (insert (format "### new session: %s (starting in herdr %s)\n\n" name pane))
      (daniel-claudy--band-headers)
      (setq daniel-claudy--pending-pane pane))
    (when display
      (daniel-claudy--display buf)
      (when (bound-and-true-p evil-local-mode) (evil-insert-state)))
    buf))

(defun daniel-claudy--adopt-new-session (buf file pane)
  "Turn BUF, typed in while the session started, into FILE's claudy buffer.
A prompt queued there goes to herdr PANE now.  BUF keeps its windows: you
may be mid-sentence.  With nothing queued BUF is left alone until your first
send."
  (cond
   ((not (buffer-live-p buf))
    (with-current-buffer (daniel-claudy--render file)
      (daniel-claudy--park-at-end)))
   ((not (buffer-local-value 'daniel-claudy--queued buf))
    (with-current-buffer buf
      (setq daniel-claudy--pending-file file)))
   (t
    (with-current-buffer buf
      (let ((queued daniel-claudy--queued))
        ;; lets `daniel-claudy--render' find BUF
        (setq daniel-claudy--current-file file)
        (daniel-claudy--refresh-when-landed buf queued)
        (daniel-claudy--send-text pane queued)
        (setq daniel-claudy--awaiting t)
        (daniel-claudy--refresh-to-bottom buf))))))

(defun daniel-claudy--await-new-session (pane name buf)
  "Name the session starting in herdr PANE, then turn BUF into its transcript.
Naming it is what makes the transcript exist: claude writes nothing under
`daniel-claudy-projects-dir' until something happens in the session, and
`/rename' is the cheapest something there is - no model call, and the name it
leaves behind is what the picker shows."
  (let ((waited 0) (named nil) timer)
    (setq timer
          (run-with-timer
           daniel-claudy-new-session-poll daniel-claudy-new-session-poll
           (lambda ()
             (setq waited (+ waited daniel-claudy-new-session-poll))
             (let* ((agent (daniel-claudy--pane-agent pane))
                    ;; Only worth the recursive scan once the rename is in.
                    (file (and named
                               (daniel-claudy--session-id-file
                                (daniel-claudy--agent-session-id agent)))))
               (cond
                (file (cancel-timer timer)
                      (daniel-claudy--adopt-new-session buf file pane))
                ((not (daniel-claudy--pane-live-p pane))
                 (cancel-timer timer)
                 (message "herdr pane %s closed before its session started" pane))
                ;; `idle' means the TUI is up and past any trust prompt; sending
                ;; earlier would answer that prompt instead of naming the session.
                ((and (not named) (equal (alist-get 'agent_status agent) "idle"))
                 (setq named t)
                 (daniel-claudy--send-text pane (concat "/rename " name) t))
                ((>= waited daniel-claudy-new-session-timeout)
                 (cancel-timer timer)
                 (message "herdr pane %s never came up; answer what it is asking there"
                          pane)))))))))

;;;###autoload
(defun daniel-claudy-new-session (&optional name prompt dir)
  "Start claude in a new herdr workspace and open its transcript buffer.
NAME names the session; you are asked for one when it is missing or blank.
`daniel-claudy-view' passes the text that matched no session, so the search
that found nothing is already the name you meant to give it.
PROMPT, when given, is queued as the first prompt and sent once claude is up,
and the buffer opens in the background.
DIR, when given, is where claude starts; otherwise you pick a project.
Return the new buffer."
  (interactive)
  (let* ((name (or (and name (not (string-blank-p name)) (string-trim name))
                   (daniel-claudy--read-session-name)))
         (dir (or dir (daniel-claudy--read-project-dir)))
         (pane (daniel-claudy--new-claude-pane dir name))
         ;; a queued prompt comes from a selection you are still working on
         (buf (daniel-claudy--pending-buffer pane name (not prompt))))
    (when prompt
      (with-current-buffer buf
        (insert (string-trim prompt))
        (setq daniel-claudy--queued (string-trim prompt))))
    (daniel-claudy--await-new-session pane name buf)
    (message "Started claude \"%s\" in herdr %s (%s)" name pane dir)
    buf))

(defun daniel-claudy--exit (pane &optional tries)
  "Send `/exit' to herdr PANE and answer the worktree dialog with Remove.
Claude asks keep-or-remove when the session sits in a worktree and has no
setting to skip that; the dialog shows a moment after `/exit', so poll the pane
for it.  TRIES counts the polls left."
  (if (null tries)
      (progn (daniel-claudy--send-text pane "/exit")
             (run-with-timer 0.3 nil #'daniel-claudy--exit pane 20))
    ;; a gone pane means the session ended without asking: no worktree
    (let ((screen (ignore-errors
                    (daniel-claudy--herdr "pane" "read" pane "--source" "visible"))))
      (cond ((null screen))
            ((string-match-p "Exiting worktree session" screen)
             (daniel-claudy--herdr "pane" "send-keys" pane "2"))
            ((> tries 1)
             (run-with-timer 0.3 nil #'daniel-claudy--exit pane (1- tries)))))))

(defun daniel-claudy-exit-this-session ()
  "Send `/exit' to this buffer's herdr pane, ending the Claude session.
Asks first: the session is gone for good."
  (interactive)
  (when (y-or-n-p "Exit this Claude session? ")
    (daniel-claudy--exit (daniel-claudy--pane))
    (kill-current-buffer)))

(defun daniel-claudy-resume (&optional all)
  "Send `/resume' to this buffer's herdr pane and show the session it picks up.
Offers the recent sessions of this git repo, its subdirs and worktrees
included, or of every repo when ALL is non-nil.  No `/clear' first: `/resume'
leaves the current conversation saved and listed, and `/clear' would only start
one more empty session."
  (interactive "P")
  (let* ((pane (daniel-claudy--pane))
         (current daniel-claudy--current-file)
         (repo (unless all
                 (daniel-claudy--repo (or (and current
                                               (daniel-claudy--session-cwd current))
                                          default-directory))))
         (table (seq-remove (lambda (c) (equal (cdr c) current))
                            (daniel-claudy--candidates t repo)))
         (file (cdr (assoc (completing-read "Resume session: " table nil t)
                           table))))
    (daniel-claudy--send-text pane (concat "/resume " (file-name-base file)) t)
    (kill-current-buffer)
    (let ((buf (daniel-claudy--render file)))
      ;; the resumed session's record names this pane only once claude has
      ;; switched, so until then the pane lookup would have to ask
      (with-current-buffer buf
        (setq daniel-claudy--pane pane))
      (daniel-claudy--display buf))))

;;;###autoload
(defun daniel-claudy-resume-new-workspace (&optional all)
  "Resume a recent session of this git repo in a new herdr workspace and show it.
`daniel-claudy-resume' from any buffer: the same picker, or every repo's
sessions when ALL is non-nil.  The workspace starts in the session's own
directory, the only place `claude --resume' finds it."
  (interactive "P")
  (let* ((table (daniel-claudy--candidates
                 t (unless all (daniel-claudy--repo default-directory))))
         (file (cdr (assoc (completing-read "Resume session: " table nil t)
                           table)))
         (pane (daniel-claudy--new-claude-pane
                (daniel-claudy--session-cwd file) nil
                "--resume" (file-name-base file)))
         (buf (daniel-claudy--render file)))
    (with-current-buffer buf
      (setq daniel-claudy--pane pane))
    (daniel-claudy--display buf)))

(defun daniel-claudy--refresh-to-end (buf)
  "Re-render BUF's session in the background, parked on Claude's latest answer."
  (with-current-buffer buf
    (daniel-claudy--render daniel-claudy--current-file t)
    (goto-char (or (daniel-claudy--answer-start) (point-max)))
    (dolist (win (get-buffer-window-list buf nil t))
      ;; Park per window: recentering acts on the selected one, and this refresh
      ;; must not steal the selection.
      (with-selected-window win
        (daniel-claudy--park-on-answer)))))

;;;###autoload
(defun daniel-claudy-notify-finished (&optional file)
  "Refresh the claudy buffer showing session FILE when a turn finishes.
The Claude Code Stop hook calls this via emacsclient with the transcript path;
only the matching buffer refreshes, and only if `daniel-claudy-send-rest'
armed it, so unrelated sessions do not trigger anything.  Without FILE, every
awaiting claudy buffer refreshes.  Refreshing happens in the background so a
finished session never steals the selected window."
  (dolist (buf (if file
                   (let ((buf (daniel-claudy--buffer-for-file file)))
                     (when buf (list buf)))
                 (seq-filter
                  (lambda (b) (buffer-local-value 'daniel-claudy--awaiting b))
                  (buffer-list))))
    (with-current-buffer buf
      (when (and daniel-claudy--awaiting daniel-claudy--current-file)
        (setq daniel-claudy--awaiting nil)
        (daniel-claudy--refresh-to-end buf)))))

;;;; Usage ---------------------------------------------------------------------

;; `/usage' lives inside a session, but `claude -p' runs it headless and prints
;; the same block.  Parsing that beats scraping the herdr pane.

(defconst daniel-claudy--usage-line-re
  (concat "^Current \\([a-z]+\\)\\(?: ([^)]*)\\)?: +\\([0-9]+\\)% used"
          "[^0-9]*resets \\(?:\\([A-Z][a-z]+ [0-9]+\\), \\)?"
          "\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\([ap]m\\)")
  "Matches one limit line of `claude -p /usage' output.")

(defun daniel-claudy--usage-rows (output)
  "Return (LABEL PERCENT RESETS) rows parsed from OUTPUT of `claude -p /usage'.
Times become 24h rounded to the hour, 17:50 as 18h, and the timezone goes; a
reset landing today drops its date."
  (let ((today (let ((system-time-locale "C")) (format-time-string "%b %-d")))
        rows)
    (with-temp-buffer
      (insert output)
      (goto-char (point-min))
      (while (re-search-forward daniel-claudy--usage-line-re nil t)
        (let ((date (match-string 3))
              (hour (string-to-number (match-string 4)))
              (pm (equal (match-string 6) "pm")))
          (push (list (concat "Current " (match-string 1))
                      (concat (match-string 2) "%")
                      (concat (if (and date (not (equal date today)))
                                  (concat date " ")
                                "")
                              ;; 11:59pm rounds to 24h, keeping its date right
                              (format "%dh"
                                      (+ (mod hour 12) (if pm 12 0)
                                         (if (>= (string-to-number
                                                  (or (match-string 5) "0"))
                                                 30)
                                             1 0)))))
                rows))))
    (nreverse rows)))

(defvar daniel-claudy--usage-title nil
  "Usage limits shown in the mode line of every claudy buffer.
Global: all sessions share one subscription.")

(defvar daniel-claudy--usage-account nil
  "Account shown after the usage limits in every claudy buffer.")

(defun daniel-claudy--usage-format (rows)
  "Return the mode line text for usage ROWS from `daniel-claudy--usage-rows'."
  (mapconcat (lambda (row)
               (format " - %s %s" (nth 1 row) (nth 2 row)))
             rows ""))

(defun daniel-claudy--account ()
  "Account Claude Code is logged in with: its email before the @, no digits.
Read on every fetch, since `/login' can switch it."
  (when-let* ((email (ignore-errors
                       (with-temp-buffer
                         (insert-file-contents "~/.claude.json")
                         (gethash "emailAddress"
                                  (gethash "oauthAccount" (json-parse-buffer)))))))
    (replace-regexp-in-string "[0-9]*@.*" "" email)))

(defun daniel-claudy--usage-set (output)
  "Show the limits parsed from OUTPUT in the mode line of every claudy buffer."
  (let ((rows (daniel-claudy--usage-rows output)))
    (if (null rows)
        (message "claudy: no limits found in `claude -p /usage' output")
      (setq daniel-claudy--usage-title (daniel-claudy--usage-format rows)
            daniel-claudy--usage-account (daniel-claudy--account))
      (force-mode-line-update t))))

(defun daniel-claudy--usage-segment ()
  "Usage limits and account for the mode line, or nil before the first fetch."
  (when daniel-claudy--usage-title
    (propertize (string-replace     ; an :eval result is a mode-line construct
                 "%" "%%"
                 (concat daniel-claudy--usage-title
                         (if daniel-claudy--usage-account
                             (concat " - " daniel-claudy--usage-account)
                           "")))
                'face 'daniel-claudy-usage)))

;;;###autoload
(defun daniel-claudy-usage ()
  "Refresh the usage limits shown in the mode line of every claudy buffer.
Asynchronous: `claude -p /usage' takes a few seconds and blocking Emacs on it
is worse than the mode line updating late."
  (interactive)
  (make-process
   :name "claudy-usage"
   :buffer (generate-new-buffer " *claudy-usage*")
   :command '("claude" "-p" "/usage")
   :noquery t
   :sentinel
   (lambda (proc _event)
     (unless (process-live-p proc)
       (let ((out (with-current-buffer (process-buffer proc) (buffer-string))))
         (kill-buffer (process-buffer proc))
         (daniel-claudy--usage-set out)))))
  (when (called-interactively-p 'interactive)
    (message "claudy: fetching usage...")))

;;;; Mode ----------------------------------------------------------------------

(defun daniel-claudy--dir-title ()
  "Frame title naming the session's worktree and directory."
  (let* ((dir (abbreviate-file-name (directory-file-name default-directory)))
         (worktree (and (string-match "/\\.claude/worktrees/\\([^/]+\\)" dir)
                        (match-string 1 dir))))
    (concat (if worktree (format "⎇ %s  " worktree) "") dir)))

(defvar-keymap daniel-claudy-mode-map
  :doc "Keymap for `daniel-claudy-mode'."
  "C-c C-c" #'daniel-claudy-send-rest
  "C-c C-l" #'daniel-claudy-send-current-line
  "C-c C-a" #'daniel-claudy-refresh
  "C-c C-j" #'daniel-claudy-jump-to-question
  "C-c C-t" #'daniel-claudy-toggle-tool-lines
  "C-c C-o" #'daniel-claudy-focus-pane
  "C-c C-r" #'daniel-claudy-resume
  "C-c C-u" #'daniel-claudy-usage
  "C-c C-k" #'daniel-claudy-exit-this-session)

(define-derived-mode daniel-claudy-mode gfm-mode "Claudy"
  "Major mode for viewing (and typing prompts in) a Claude Code transcript.
The buffer is editable; refreshing re-renders it, which discards anything
typed and not sent.

\\{daniel-claudy-mode-map}"
  (setq-local revert-buffer-function
              (lambda (&rest _) (daniel-claudy-refresh)))
  (setq-local mode-line-process '(:eval (daniel-claudy--usage-segment)))
  ;; the usual title's %f is empty here: a transcript buffer visits no file
  (setq-local frame-title-format '("%& " (:eval (daniel-claudy--dir-title)))))

;;;; Modeline ------------------------------------------------------------------

;; A session blocked on you is easy to miss when Emacs covers the terminal, so
;; mirror the session statuses into the Emacs modeline.

(defvar daniel-claudy-modeline-string ""
  "Modeline segment describing the running Claude sessions.
Kept up to date by `daniel-claudy-modeline-mode'.  Add the symbol to
`global-mode-string' or `mode-line-format' to show it.")
;; the segment must show in every buffer, whatever its major mode
(put 'daniel-claudy-modeline-string 'risky-local-variable t)

;; Claude rewrites PID.json on every status change, so a file watch drives the
;; refresh.  The timer only catches a crashed session: its leftover file never
;; changes again, so no event says it is gone.
(defvar daniel-claudy--modeline-timer nil
  "Timer refreshing `daniel-claudy-modeline-string'.")

(defvar daniel-claudy--sessions-watch nil
  "File watch on `daniel-claudy-sessions-dir'.")

(defun daniel-claudy--live-sessions ()
  "Return an alist of (NAME . STATUS) for the Claude sessions running now."
  (mapcar (lambda (json)
            (cons (or (alist-get 'name json) "?")
                  (or (alist-get 'status json) "idle")))
          (daniel-claudy--live-session-records)))

(defun daniel-claudy--modeline-format (sessions)
  "Return the modeline segment for SESSIONS, an alist of (NAME . STATUS).
One SYMBOL+COUNT group per status, states nobody is in are left out, and a
waiting session shows in `daniel-claudy-waiting' - it is the one blocking you."
  (let* ((groups
          (delq nil
                (mapcar
                 (lambda (state)
                   (let ((n (seq-count (lambda (s) (equal (cdr s) (car state)))
                                       sessions)))
                     (when (> n 0)
                       (propertize (format "%s%d" (nth 1 state) n)
                                   'face (nth 2 state)))))
                 daniel-claudy--states)))
         (help (mapconcat (lambda (s) (format "%s: %s" (car s) (cdr s)))
                          sessions "\n")))
    (if (null groups)
        ""
      (propertize (concat " " (string-join groups " ") " ")
                  'help-echo (concat help "\nmouse-1: pick a Claude session")
                  'mouse-face 'mode-line-highlight
                  'local-map (let ((map (make-sparse-keymap)))
                               (define-key map [mode-line mouse-1]
                                           #'daniel-claudy-view)
                               map)))))

(defun daniel-claudy--work-finished-p (shown symbol)
  "Return non-nil when SYMBOL is idle or waiting and SHOWN was another state.
Coming to rest on ✅ is the turn ending, and landing on ❗ is Claude asking you
something: the moments the transcript is worth re-reading.  A buffer showing
nothing yet (SHOWN nil) was just rendered and has nothing to catch up on."
  (and shown (member symbol (list (daniel-claudy--status-symbol "idle")
                                  (daniel-claudy--status-symbol "waiting")))))

(defun daniel-claudy--follow-session (records)
  "Point this claudy buffer at its session's current directory and transcript.
`EnterWorktree' changes the session's cwd in its live record, one of RECORDS,
and moves the transcript to the worktree's project dir."
  (when-let* ((file (or daniel-claudy--current-file daniel-claudy--pending-file))
              (id (file-name-base file)))
    (let ((cwd (alist-get 'cwd (daniel-claudy--live-record id records))))
      (when (and (stringp cwd) (file-directory-p cwd)
                 (not (equal (file-name-as-directory cwd) default-directory)))
        (setq default-directory (file-name-as-directory cwd))
        (force-mode-line-update)))
    (unless (file-exists-p file)
      (when-let* ((moved (daniel-claudy--session-id-file id)))
        (if daniel-claudy--current-file
            (setq daniel-claudy--current-file moved)
          (setq daniel-claudy--pending-file moved))))))

(defun daniel-claudy-rehome-buffers ()
  "Move buffers out of removed worktrees, to the same spot in the main checkout.
Buffers made from a claudy buffer inherit its worktree dir, and once the
worktree is removed that missing dir breaks `make-process'.  A worktree dir is
<repo>/.claude/worktrees/<name>/<rest>, so the spot is <repo>/<rest>, or <repo>/
when that is missing too.  Return the number of buffers moved."
  (let ((moved 0))
    (dolist (buf (buffer-list) moved)
      (with-current-buffer buf
        (when (and (stringp default-directory)
                   (string-match "\\`\\(.*/\\)\\.claude/worktrees/[^/]+/\\(.*\\)\\'"
                                 default-directory))
          (let* ((repo (match-string 1 default-directory))
                 (dir (concat repo (match-string 2 default-directory))))
            (unless (file-directory-p default-directory)
              (setq default-directory (if (file-directory-p dir) dir repo))
              (setq moved (1+ moved)))))))))

(defun daniel-claudy--refresh-status-marks ()
  "Track the live status symbol at the bottom of every claudy buffer that changed.
Normally only the symbol is appended, so the bottom of the buffer keeps a trail
of the states the session went through.  The turn ending is the exception: the
buffer is re-rendered instead, which trades that trail for the new output."
  (let ((statuses (daniel-claudy--live-session-statuses))
        (records (daniel-claudy--live-session-records)))
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'daniel-claudy-mode)
          (daniel-claudy--follow-session records))
        ;; A file still missing after the follow has no transcript to render;
        ;; rendering it would abort the modeline refresh for every session.
        (when (and (derived-mode-p 'daniel-claudy-mode) daniel-claudy--current-file
                   (file-exists-p daniel-claudy--current-file))
          (let ((symbol (daniel-claudy--file-status-symbol
                         daniel-claudy--current-file statuses)))
            (unless (equal symbol daniel-claudy--status-shown)
              (if (daniel-claudy--work-finished-p daniel-claudy--status-shown
                                                  symbol)
                  (daniel-claudy--refresh-to-end buf)
                (daniel-claudy--append-status symbol)))))))))

(defun daniel-claudy--modeline-refresh ()
  "Recompute `daniel-claudy-modeline-string', redrawing only when it changed."
  (daniel-claudy-rehome-buffers)
  (daniel-claudy--refresh-status-marks)
  (let ((new (daniel-claudy--modeline-format (daniel-claudy--live-sessions))))
    (unless (equal new daniel-claudy-modeline-string)
      (setq daniel-claudy-modeline-string new)
      (force-mode-line-update t))))

(defun daniel-claudy--sessions-changed (_event)
  "Refresh the Claude status after a file in `daniel-claudy-sessions-dir' changed."
  (daniel-claudy--modeline-refresh))

;;;###autoload
(define-minor-mode daniel-claudy-modeline-mode
  "Keep `daniel-claudy-modeline-string' and open claudy buffers up to date.
Watches `daniel-claudy-sessions-dir' and polls every
`daniel-claudy-modeline-interval' seconds.  Add
`daniel-claudy-modeline-string' to `global-mode-string' to see it."
  :global t
  :init-value nil
  (when (timerp daniel-claudy--modeline-timer)
    (cancel-timer daniel-claudy--modeline-timer)
    (setq daniel-claudy--modeline-timer nil))
  (when daniel-claudy--sessions-watch
    (file-notify-rm-watch daniel-claudy--sessions-watch)
    (setq daniel-claudy--sessions-watch nil))
  (if daniel-claudy-modeline-mode
      (let ((dir (expand-file-name daniel-claudy-sessions-dir)))
        ;; Claude creates the dir on its first run; the timer covers until then
        (when (file-directory-p dir)
          (setq daniel-claudy--sessions-watch
                (file-notify-add-watch dir '(change)
                                       #'daniel-claudy--sessions-changed)))
        (setq daniel-claudy--modeline-timer
              (run-with-timer 0 daniel-claudy-modeline-interval
                              #'daniel-claudy--modeline-refresh)))
    (setq daniel-claudy-modeline-string "")
    (force-mode-line-update t)))

(provide 'daniel-claudy)
;;; daniel-claudy.el ends here
