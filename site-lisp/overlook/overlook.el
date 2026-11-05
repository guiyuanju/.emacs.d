;;; overlook.el --- A dashboard over your perspectives, repos and agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
;; Maintainer: guiyuanju <guiyuanjune@outlook.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (perspective "2.22") (agent-shell "0.87.3") (circe "2.14") (simple-httpd "1.7"))
;; Keywords: tools, convenience
;; URL: https://github.com/guiyuanju/overlook
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Overlook is a side window listing every perspective (a project with its
;; buffers and window layout) and what lives in it: its repos, its AI
;; agents, and whatever else a module adds.
;;
;; The core only draws the dashboard.  Everything it shows comes from
;; modules:
;;
;; - A perspective backend sets the `overlook-perspective-*-function'
;;   variables; overlook-perspective.el provides one for perspective.el.
;; - Rows under each perspective come from
;;   `overlook-perspective-functions'; overlook-project.el lists repos and
;;   overlook-agent.el lists agents.
;; - Top level sections come from `overlook-sections'; the perspectives
;;   section sits at depth 0, overlook-usage.el adds one above it.
;;
;; Modules give data, not text: each returns rows made by `overlook-row',
;; holding what a row says as segments, what RET does, the rows under it
;; and the like.  `overlook-model' gathers them into the dashboard's
;; model, a list of sections, and views draw that model: the dashboard
;; buffer, and other views such as overlook-remote's web page.
;;
;; The dashboard is a `magit-section-mode' buffer: each section and row is
;; a section, so \\[magit-section-toggle] folds the rows under one and
;; Magit's section commands work.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'seq)
(require 'subr-x)

(defgroup overlook nil
  "A dashboard over perspectives, repos and agents."
  :group 'tools
  :prefix "overlook-")

(defcustom overlook-width 65
  "Width of the dashboard side window.
An integer is a number of columns; a float is a fraction of the frame width."
  :type '(choice (natnum :tag "Columns") (float :tag "Fraction of frame")))

(defcustom overlook-agent-icons nil
  "Icons shown in place of agents' names, keyed by name."
  :type '(alist :key-type string :value-type string))

(defcustom overlook-side 'right
  "Frame side the dashboard window is shown on."
  :type '(choice (const left) (const right)))

(defcustom overlook-perspective-order 'recent
  "Order of the perspectives on the dashboard.
`recent' puts the current one first, then the rest by how recently they
were switched to; `backend' keeps the backend's order."
  :type '(choice (const recent) (const backend)))

(defcustom overlook-perspective-annotation nil
  "Function of a perspective NAME returning a tag shown after its heading, or nil."
  :type '(choice (const :tag "None" nil) function))

(defcustom overlook-perspective-filter nil
  "Function of a perspective NAME returning nil to hide it, or nil to show all.
The current perspective, and one with a row needing your attention, are
shown regardless."
  :type '(choice (const :tag "Show all" nil) function))

(defcustom overlook-show-empty-perspectives nil
  "Non-nil to list a perspective with no rows and no mark after its heading.
The current one is listed either way."
  :type 'boolean)

(defcustom overlook-orphan-perspective nil
  "Perspective listing the rows that belong to no perspective, or nil.
Rows opened from there open in it.  Without it, they are listed under
the current perspective."
  :type '(choice (const :tag "The current perspective" nil) string))

(defcustom overlook-section-order nil
  "Functions of `overlook-sections' in the order the dashboard shows them.
Sections not listed follow, by hook depth."
  :type '(repeat function))

(defcustom overlook-account-labels nil
  "Short labels drawn in place of account names, keyed by name.
Like ((\"work\" . \"W\") (\"home\" . \"H\")).  An account with a label
shows it wherever the dashboard names the account, the first one too."
  :type '(alist :key-type string :value-type string))

(defun overlook-account-label (account)
  "The label `overlook-account-labels' gives ACCOUNT, or nil."
  (and account (alist-get account overlook-account-labels nil nil #'equal)))

(defcustom overlook-account-width 3
  "Characters of an account's name shown after @ on the dashboard; nil for all."
  :type '(choice (const :tag "All" nil) natnum))

(defun overlook-account-name (account)
  "ACCOUNT as the dashboard draws it: its label, else @ACCOUNT, dimmed.
The name is cut to `overlook-account-width' characters."
  (or (overlook-account-label account)
      (propertize (concat "@" (if overlook-account-width
                                  (truncate-string-to-width account overlook-account-width)
                                account))
                  'face 'shadow)))

(defcustom overlook-refresh-idle 0.5
  "Seconds input must pause before the dashboard redraws."
  :type 'number)

(defcustom overlook-refresh-gap 1
  "Fewest seconds between two redraws the dashboard asks for itself."
  :type 'number)

(defcustom overlook-refresh-max-wait 10
  "Most seconds a redraw waits for input to pause."
  :type 'number)

(defcustom overlook-tick-interval 5
  "Seconds between runs of `overlook-tick-hook' while the dashboard is live."
  :type 'number)

(defconst overlook-buffer-name " *overlook*"
  "The dashboard buffer.  A leading space keeps it out of buffer lists.")

;;; Perspective backend

(defvar overlook-perspectives-function #'ignore
  "Function returning the names of all perspectives, in display order.")

(defvar overlook-current-perspective-function #'ignore
  "Function returning the name of the current perspective, or nil.")

(defvar overlook-switch-perspective-function #'ignore
  "Function of a NAME switching to that perspective.")

(defvar overlook-perspective-buffers-function #'ignore
  "Function of a NAME returning that perspective's buffers.")

(defvar overlook-perspective-root-function #'ignore
  "Function of a NAME returning that perspective's project root, or nil.")

(defvar overlook-add-to-perspective-function #'ignore
  "Function of a NAME and a BUFFER adding BUFFER to that perspective.")

(defvar overlook-detach-function #'ignore
  "Function of a BUFFER removing it from every perspective.")

(defun overlook-perspectives ()
  "Names of all perspectives."
  (funcall overlook-perspectives-function))

(defun overlook-current-perspective ()
  "Name of the current perspective, or nil."
  (funcall overlook-current-perspective-function))

(defvar overlook--buffers-cache nil
  "Perspective buffers looked up during one render, keyed by name.")

(defun overlook-perspective-buffers (name)
  "Live buffers of perspective NAME."
  (let ((lookup (lambda ()
                  (seq-filter #'buffer-live-p
                              (funcall overlook-perspective-buffers-function name)))))
    (if overlook--buffers-cache
        (with-memoization (gethash name overlook--buffers-cache) (funcall lookup))
      (funcall lookup))))

(defvar overlook--roots-cache nil
  "Perspective roots looked up during one render, keyed by name, each in a list.")

(defun overlook-perspective-root (name)
  "Project root of perspective NAME, or nil."
  (if overlook--roots-cache
      (car (with-memoization (gethash name overlook--roots-cache)
             (list (funcall overlook-perspective-root-function name))))
    (funcall overlook-perspective-root-function name)))

(defun overlook-orphan-perspective ()
  "Name of `overlook-orphan-perspective' when it exists, else nil."
  (car (member overlook-orphan-perspective (overlook-perspectives))))

(defun overlook-orphans-perspective ()
  "Name of the perspective rows of no perspective go under.
That is `overlook-orphan-perspective', or else the current one."
  (or (overlook-orphan-perspective) (overlook-current-perspective)))

(defun overlook-add-to-perspective (name buffer)
  "Add BUFFER to perspective NAME."
  (funcall overlook-add-to-perspective-function name buffer))

(defvar-local overlook-detached nil
  "Non-nil in a buffer `overlook-detach' keeps out of every perspective.")
(put 'overlook-detached 'permanent-local t)

(defun overlook-detach (buffer)
  "Keep BUFFER out of every perspective, even once shown in one.
Opening it from the dashboard shows it in the current perspective."
  (with-current-buffer buffer
    (setq overlook-detached t)
    (add-hook 'window-buffer-change-functions #'overlook--detach-shown nil t))
  (funcall overlook-detach-function buffer))

(defun overlook--detach-shown (window)
  "Take the buffer WINDOW now shows back out of the perspectives."
  (funcall overlook-detach-function (window-buffer window)))
(put 'overlook--detach-shown 'permanent-local-hook t)

(defun overlook-buffer-perspective (buffer)
  "The perspective BUFFER belongs to, preferring the current one; or nil."
  (let ((current (overlook-current-perspective)))
    (if (and current (memq buffer (overlook-perspective-buffers current)))
        current
      (seq-find (lambda (name) (memq buffer (overlook-perspective-buffers name)))
                (overlook-perspectives)))))

(defun overlook-switch-perspective (name)
  "Switch to perspective NAME, keeping the dashboard shown if it was."
  (unless (equal name (overlook-current-perspective))
    (funcall overlook-switch-perspective-function name)
    (overlook-perspective-switched)))

(defvar overlook-perspective-switch-hook nil
  "Hook run after switching perspectives, in the new one.")

(defvar overlook-perspective-switch-times nil
  "Alist of perspective name to the time it was last switched to.
Add it to `savehist-additional-variables' to keep it across sessions.")

(defun overlook--record-switch ()
  "Record the time of a switch to the current perspective."
  (when-let* ((name (overlook-current-perspective)))
    (setf (alist-get name overlook-perspective-switch-times nil nil #'equal)
          (float-time))))

(defun overlook-ordered-perspectives ()
  "Names of all perspectives, in the order of `overlook-perspective-order'."
  (let ((names (overlook-perspectives))
        (current (overlook-current-perspective)))
    (if (not (eq overlook-perspective-order 'recent))
        names
      (let ((time (lambda (name)
                    (alist-get name overlook-perspective-switch-times 0 nil #'equal))))
        (append (and (member current names) (list current))
                (sort (remove current names)
                      (lambda (a b) (> (funcall time a) (funcall time b)))))))))

(defvar overlook--to-current nil
  "Non-nil when the next redraw moves point to the current perspective.")

(defun overlook-perspective-switched (&rest _)
  "Show the dashboard in the new perspective and redraw it on its heading.
Backends call this after any perspective switch, including ones not made
through overlook, since switching perspectives replaces the windows."
  (overlook--record-switch)
  (setq overlook--to-current t)
  (overlook--follow)
  (run-hooks 'overlook-perspective-switch-hook)
  (overlook-refresh))

;;; Hooks

(defvar overlook-sections nil
  "Functions giving the dashboard's top level sections, by hook depth.
Each is called with no arguments and returns a section, as made by
`overlook-section-row', or nil.  The perspectives section sits at
depth 0.")

(defvar overlook-perspective-functions nil
  "Functions giving the rows under a perspective's heading, by hook depth.
Each is called with the perspective's NAME and returns a list of rows,
as made by `overlook-row'.  The rows of what lies in a checkout come
from `overlook-worktree-functions' instead.  Under
`overlook-orphans-perspective' a function also gives its rows that
belong to no perspective.")

(defvar overlook-worktrees-functions nil
  "Functions of a perspective NAME returning the worktrees listed under it.
Each returns a list of folders, each ending in a slash.")

(defvar overlook-worktree-functions nil
  "Functions giving the rows of what lies in a checkout, by hook depth.
Each is called with the perspective's NAME and the worktree's folder
DIR, or nil for what lies in none of its worktrees, and returns a list
of rows.  Agents sit at depth 0 and changed repos at 50.  With DIR nil
they go right under the perspective's heading while it lists no
worktrees, else under the row of its main checkout, which a function of
`overlook-perspective-functions' gives with those of its worktrees.")

(defvar overlook--worktrees-cache nil
  "Worktrees looked up during one render, keyed by perspective name.")

(defun overlook-worktrees (name)
  "Folders of the worktrees listed under perspective NAME."
  (let ((lookup (lambda () (seq-mapcat (lambda (fn) (funcall fn name))
                                       overlook-worktrees-functions))))
    (if overlook--worktrees-cache
        (car (with-memoization (gethash name overlook--worktrees-cache)
               (list (funcall lookup))))
      (funcall lookup))))

(defun overlook-worktree-of (dir worktrees)
  "The folder among WORKTREES holding DIR, or nil."
  (when dir
    (let ((dir (file-name-as-directory (expand-file-name dir))))
      (seq-find (lambda (tree) (string-prefix-p tree dir)) worktrees))))

(defvar overlook-folder-contents-functions nil
  "Functions of a folder DIR returning what lies in it, before DIR goes.
Each returns a list of (DESCRIPTION . DELETE), DESCRIPTION naming one
thing, like \"agent claude\", and DELETE a function letting it go.")

(defun overlook-folder-contents (dir)
  "What lies in folder DIR, as `overlook-folder-contents-functions' tell."
  (seq-mapcat (lambda (fn) (funcall fn dir)) overlook-folder-contents-functions))

(defvar overlook-delete-functions nil
  "Functions of a row's id, as `overlook-item-at-point' gives, deleting it.
Each deletes what the row stands for.
Each returns non-nil when it handled the item.")

(defvar overlook-heading-mark-functions nil
  "Functions of a perspective NAME returning a mark put right after its heading.
Each returns a string, such as \"*\", or nil.")

(defvar overlook-mode-line-functions nil
  "Functions returning strings joined into the dashboard's mode line.")

(defvar overlook-before-render-hook nil
  "Hook run before `overlook-model' gathers the dashboard's rows.")

(defvar overlook-after-model-hook nil
  "Hook run once `overlook-model' has gathered the dashboard's rows afresh.
For views drawing the model `overlook-latest-model' gives.")

(defvar overlook-tick-hook nil
  "Hook run every `overlook-tick-interval' seconds while the dashboard is live.")

(defun overlook-toggle-hooks (on hooks)
  "Add HOOKS when ON is non-nil, else remove them; for modules' modes.
Each of HOOKS is (HOOK FUNCTION) or (HOOK FUNCTION DEPTH)."
  (pcase-dolist (`(,hook ,function ,depth) hooks)
    (if on (add-hook hook function depth) (remove-hook hook function))))

;;; Refresh

(defvar overlook--timer nil)
(defvar overlook--tick-timer nil)
(defvar overlook--shown nil
  "Non-nil while the dashboard is toggled on; every perspective then shows it.")

(defun overlook-live-p ()
  "Non-nil when the dashboard buffer exists."
  (and (get-buffer overlook-buffer-name) t))

(defvar overlook--rendered 0
  "When the dashboard was last redrawn.")

(defvar overlook-refresh-hook nil
  "Hook run by `overlook-refresh', whether or not the dashboard is live.
For other views of the dashboard; see `overlook-latest-model'.")

(defvar overlook--generation 0
  "Count of calls to `overlook-refresh', telling when a model is stale.")

(defun overlook-refresh ()
  "Redraw the dashboard soon, at most once per burst, and not while the user types.
Redraws are `overlook-refresh-gap' seconds apart at least."
  (setq overlook--generation (1+ overlook--generation))
  (run-hooks 'overlook-refresh-hook)
  (when (and (overlook-live-p) (not (timerp overlook--timer)))
    (setq overlook--timer
          (run-with-timer (max 0.1 (- (+ overlook--rendered overlook-refresh-gap) (float-time)))
                          nil #'overlook--render-when-idle (float-time)))))

(defun overlook--render-when-idle (asked)
  "Redraw once input has paused for `overlook-refresh-idle' seconds.
Waits no longer than `overlook-refresh-max-wait' seconds after time ASKED."
  (let ((idle (current-idle-time)))
    (if (and (or (null idle) (< (float-time idle) overlook-refresh-idle))
             (< (- (float-time) asked) overlook-refresh-max-wait))
        (setq overlook--timer (run-with-timer 0.2 nil #'overlook--render-when-idle asked))
      (setq overlook--timer nil
            overlook--rendered (float-time))
      (overlook--render))))

(defun overlook--tick ()
  "Run `overlook-tick-hook', or stop ticking once the dashboard is gone."
  (if (overlook-live-p)
      (run-hooks 'overlook-tick-hook)
    (cancel-timer overlook--tick-timer)
    (setq overlook--tick-timer nil)))

;;; Mode

(defvar-keymap overlook-mode-map)

(defvar overlook-keys nil
  "Dashboard bindings made by `overlook-define-key', as (KEY . COMMAND).
For modal editing setups to bind them in their own states too.")

(defun overlook-define-key (key command)
  "Bind KEY, in `keymap-set' syntax, to COMMAND on the dashboard.
The binding is recorded in `overlook-keys'."
  (keymap-set overlook-mode-map key command)
  (setf (alist-get key overlook-keys nil nil #'equal) command))

(pcase-dolist (`(,key . ,command)
               '(("RET" . overlook-visit)
                 ("o" . overlook-visit)
                 ("d d" . overlook-delete)
                 ("TAB" . magit-section-toggle)
                 ("C-j" . overlook-next-heading)
                 ("C-k" . overlook-previous-heading)
                 ("C-S-j" . overlook-next-attention)
                 ("C-S-k" . overlook-previous-attention)
                 ("] a" . overlook-next-attention)
                 ("[ a" . overlook-previous-attention)
                 ("q" . overlook)))
  (overlook-define-key key command))

(define-derived-mode overlook-mode magit-section-mode "Overlook"
  "Dashboard over perspectives and what lives in them."
  (setq-local revert-buffer-function (lambda (&rest _) (overlook--render))
              truncate-lines nil
              truncate-partial-width-windows nil
              word-wrap t
              word-wrap-by-category t
              left-margin-width 1
              right-margin-width 1
              mode-line-format '(:eval (overlook--mode-line)))
  ;; Magit highlights sections with `font-lock-face', which only shows with
  ;; font-lock on; font-lock would strip the rows' faces, so alias it instead.
  ;; Global font-lock is kept out too: in a buffer whose name starts with a
  ;; space it cannot turn on, and the attempt removes the alias.
  (setq-local char-property-alias-alist
              (cons '(face font-lock-face) char-property-alias-alist)
              font-lock-global-modes nil)
  ;; Rows fit themselves to the window, so redraw when it resizes.
  (add-hook 'window-size-change-functions (lambda (_) (overlook-refresh)) nil t)
  (add-hook 'post-command-hook #'overlook--remember-point nil t)
  (advice-add 'set-window-configuration :after #'overlook--restore-points)
  (when (fboundp 'display-line-numbers-mode) (display-line-numbers-mode -1)))

(defun overlook--mode-line ()
  "The dashboard's mode line: its name, then `overlook-mode-line-functions'."
  (string-replace
   "%" "%%"
   (string-join (cons (concat " " (propertize "Overlook" 'face 'mode-line-buffer-id))
                      (delq nil (mapcar #'funcall overlook-mode-line-functions)))
                "   ")))

;;; Faces

(defface overlook-section
  '((t :inherit (font-lock-keyword-face bold)))
  "Face of section titles.")

(defface overlook-tabular
  '((t))
  "Face of rows whose text lines up in columns.
Views in proportional fonts draw such rows in a fixed-pitch one.")

(defface overlook-heading
  '((t :inherit bold))
  "Face of perspective headings.")

(defface overlook-heading-current
  '((t :inherit (success bold)))
  "Face of the current perspective's heading.")

(defclass overlook-section (magit-section) ()
  "A section or row of the dashboard.")

(cl-defmethod magit-section-highlight ((section overlook-section))
  "Highlight SECTION, including the wrap prefixes of its rows.
Emacs draws a wrap prefix in the default face, which would leave a gap."
  (cl-call-next-method)
  (save-excursion
    (goto-char (oref section start))
    (while (< (point) (oref section end))
      (when-let* ((prefix (get-text-property (point) 'wrap-prefix)))
        (overlay-put (magit-section-highlight-range (point) (line-end-position))
                     'wrap-prefix (propertize prefix 'face 'magit-section-highlight)))
      (forward-line 1))))

;;; Rows

(cl-defstruct (overlook-row (:constructor overlook-row) (:copier nil))
  "A row of the dashboard, as data.
Make one with `overlook-row', giving each slot as a keyword argument.
ID identifies the row across redraws, like (agent . BUFFER); without
one, the row goes by its text.  `overlook-item-at-point' and
`overlook-delete-functions' get it.

CONTENT is what the row says: a segment, or a list of them, nested
lists and nils allowed.  A segment is
  a string, its text properties giving its look, like `face';
  (:right TEXT :columns N), TEXT ending N columns before the right
          edge, as `overlook-align-right' makes;
  (:cell GLYPH), GLYPH padded to three columns, as
          `overlook-glyph-cell' makes;
  (:fit TEXT :face FACE :before GAP :reserve N), TEXT in FACE after
          GAP, cut with an ellipsis to fit before the last N columns,
          or left out with GAP when hardly any fits;
  (:pad TEXT :like TEXTS), TEXT padded as wide as the widest of
          TEXTS, as each view measures them, so rows line up;
  (:wrap PIECES :gap N), strings N columns apart, those that do not
          fit going to lines below, which start where the first did.
A string's `overlook-alt' property is its text for views without the
fonts of icons.  CONTENT can also be a function of the columns the row
has, or nil when unbounded, returning segments.

HEADING and ATTENTION mark rows \\[overlook-next-heading] and
\\[overlook-next-attention] stop at.  CHILDREN are the rows under it, or
a function returning them once they show; FOLDED starts them folded.
NEST indents them a step more.  GAP puts a blank line after the row and
its children, folded with them.  DIM draws the row's line dimmed; FACE,
a face or list of faces, is added under its own faces, past its indent.

ACTION is what RET does, HELP its tooltip, WRAP what starts its
continuation lines after its indent, KEYMAP its keys.  CHOICES, a list
of (KEY LABEL . _), are the answers it offers, on a line under the row, and CHOOSE a function of a
KEY giving that answer."
  id content heading attention folded children nest gap dim face
  action help wrap keymap choices choose)

(defun overlook-row-attention-p (row)
  "Non-nil when ROW, or a row under it shown so far, needs attention."
  (or (overlook-row-attention row)
      (let ((children (overlook-row-children row)))
        (and (not (functionp children)) (seq-some #'overlook-row-attention-p children)))))

(defun overlook-row-rows (row)
  "The rows under ROW, gathering those put off until shown."
  (let ((children (overlook-row-children row)))
    (if (functionp children)
        (setf (overlook-row-children row) (funcall children))
      children)))

(defun overlook-gaps (rows)
  "ROWS, each but the last followed by a blank line."
  (dolist (row (butlast rows))
    (setf (overlook-row-gap row) t))
  rows)

(defun overlook-section-row (title rows &optional action)
  "A top level section TITLE over ROWS, or nil when ROWS is empty.
ACTION is what RET on the title does; by default it folds the section."
  (when rows
    (let ((title (copy-sequence title)))
      (add-face-text-property 0 (length title) 'overlook-section t title)
      (overlook-row :content title :heading t :action action :children rows :gap t))))

(defun overlook-rows (hook &rest args)
  "The rows the functions of HOOK return given ARGS, in hook order.
A function can return one row, or a list of them."
  (let (rows)
    (apply #'run-hook-wrapped hook
           (lambda (function &rest args)
             (push (ensure-list (apply function args)) rows)
             nil)
           args)
    (apply #'append (nreverse rows))))

(defun overlook-alt-text (string)
  "STRING as views without icon fonts show it, each `overlook-alt' in place."
  (let ((start 0) parts)
    (while (< start (length string))
      (let ((end (next-single-property-change start 'overlook-alt string (length string))))
        (push (or (get-text-property start 'overlook-alt string) (substring string start end))
              parts)
        (setq start end)))
    (apply #'concat (nreverse parts))))

(defun overlook-icon (name)
  "NAME's icon from `overlook-agent-icons', else NAME.
The icon takes NAME's properties, its faces over the icon's own, and
carries NAME as its `overlook-alt'."
  (if-let* ((plain (substring-no-properties name))
            (icon (alist-get plain overlook-agent-icons nil nil #'equal)))
      (let ((icon (copy-sequence icon))
            (face (get-text-property 0 'face name)))
        (cl-loop for (property value) on (text-properties-at 0 name) by #'cddr
                 unless (eq property 'face)
                 do (put-text-property 0 (length icon) property value icon))
        (when face (add-face-text-property 0 (length icon) face nil icon))
        (put-text-property 0 (length icon) 'overlook-alt plain icon)
        icon)
    name))

(defun overlook-align-right (text columns)
  "A segment of TEXT aligned to end COLUMNS before the window's right edge."
  (list :right text :columns columns))

(defun overlook-glyph-cell (glyph)
  "A segment of GLYPH padded to three columns, so the names after it line up.
Fonts draw glyphs like ◐ two columns wide but ⚠ or ⎇ one."
  (list :cell glyph))

;;; Drawing

(defun overlook-columns ()
  "Width of the dashboard window in columns, per `overlook-width'."
  (if (floatp overlook-width)
      (round (* overlook-width (frame-width)))
    overlook-width))

(defun overlook--window-width (&optional pixels)
  "Body width of the window showing the dashboard, in columns or PIXELS."
  (if-let* ((window (get-buffer-window (current-buffer) t)))
      (window-body-width window pixels)
    (* (overlook-columns) (if pixels (frame-char-width) 1))))

(defun overlook-window-pixels ()
  "Body width in pixels of the window showing the dashboard."
  (overlook--window-width t))

(defun overlook-pixel-width (string)
  "Width of STRING in pixels, as drawn in the current buffer.
Emacs 31 measures it with the buffer's face remappings; earlier versions
measure it in a temporary buffer."
  (if (>= (or (cdr-safe (func-arity #'string-pixel-width)) 0) 2)
      ;; The BUFFER argument is new in Emacs 31; earlier ones never get here.
      (with-no-warnings (string-pixel-width string (current-buffer)))
    (string-pixel-width string)))

(defun overlook-fit (text pixels &optional face)
  "TEXT in FACE cut with an ellipsis to fit PIXELS, or nil when hardly any fit.
Measured in pixels, as fonts draw glyphs like … wider than `string-width'."
  (let* ((width (lambda (s) (overlook-pixel-width (propertize s 'face face))))
         (cut (truncate-string-to-width text (/ pixels (max 1 (funcall width "x"))) nil nil "…")))
    (while (and (> (string-width cut) 1) (> (funcall width cut) pixels))
      (setq cut (truncate-string-to-width text (1- (string-width cut)) nil nil "…")))
    (when (>= pixels (* 4 (frame-char-width)))
      (propertize cut 'face face))))

(defun overlook-string-columns (string)
  "Columns STRING takes as drawn; fonts draw icons wider than `string-width'."
  (max (string-width string)
       (ceiling (overlook-pixel-width string) (frame-char-width))))

(defvar overlook--pad-widths (make-hash-table :test #'eq :weakness 'key)
  "Columns the widest of each `:pad' segment's texts takes as drawn.")

(defun overlook--pad (text like fit)
  "Spaces after TEXT making it as wide as the widest of LIKE.
With FIT, as drawn in the current buffer; else by `overlook-alt-text'."
  (let ((width (if fit
                   #'overlook-string-columns
                 (lambda (string) (string-width (overlook-alt-text string))))))
    (make-string (max 0 (- (if fit
                               (with-memoization (gethash like overlook--pad-widths)
                                 (apply #'max 0 (mapcar width like)))
                             (apply #'max 0 (mapcar width like)))
                           (funcall width text)))
                 ?\s)))

(defun overlook--wrap (pieces gap head)
  "PIECES joined by GAP after HEAD, wrapped to the window showing the buffer.
Lines below start where the first piece did, and leave a column at the end."
  (let* ((start (overlook-pixel-width head))
         (limit (- (overlook-window-pixels) (frame-char-width)))
         (gap-width (overlook-pixel-width gap))
         (newline (concat "\n" (propertize " " 'display `(space :width (,start)))))
         (x start)
         (text ""))
    (dolist (piece pieces)
      (let ((width (overlook-pixel-width piece)))
        (cond ((string-empty-p text)
               (setq text piece x (+ start width)))
              ((<= (+ x gap-width width) limit)
               (setq text (concat text gap piece) x (+ x gap-width width)))
              (t (setq text (concat text newline piece) x (+ start width))))))
    text))

(defun overlook-row-segments (row &optional columns)
  "ROW's content as a flat list of segments, for COLUMNS as in `overlook-row'."
  (overlook--segments (overlook-row-content row) columns))

(defun overlook--segments (content columns)
  "CONTENT, a row's, as a flat list of segments, for COLUMNS as in `overlook-row'."
  (cond ((null content) nil)
        ((stringp content) (list content))
        ((functionp content) (overlook--segments (funcall content columns) columns))
        ((keywordp (car content)) (list content))
        (t (mapcan (lambda (part) (overlook--segments part columns)) content))))

(defun overlook--segment (segment head fit)
  "SEGMENT as text, after HEAD on its line.
With FIT, it is laid out for the window showing the current buffer;
else nothing is cut."
  (pcase segment
    ((pred stringp) segment)
    (`(:right ,text . ,_)
     (concat (propertize " " 'display
                         `(space :align-to (- right ,(+ (plist-get segment :columns)
                                                        (string-width text)))))
             text))
    (`(:pad ,text . ,_)
     (concat text (overlook--pad text (plist-get segment :like) fit)))
    (`(:wrap ,pieces . ,_)
     (let ((gap (make-string (or (plist-get segment :gap) 1) ?\s)))
       (if fit (overlook--wrap pieces gap head) (string-join pieces gap))))
    (`(:cell ,glyph)
     (concat glyph (if fit
                       (let ((pad (- (* 3 (frame-char-width)) (overlook-pixel-width glyph))))
                         (propertize " " 'display `(space :width (,(max 1 pad)))))
                     " ")))
    (`(:fit ,text . ,_)
     (let* ((face (plist-get segment :face))
            (before (or (plist-get segment :before) ""))
            (text (if fit
                      (overlook-fit text
                                    (- (overlook-window-pixels)
                                       (overlook-pixel-width (concat head before))
                                       (* (or (plist-get segment :reserve) 0)
                                          (frame-char-width)))
                                    face)
                    (propertize text 'face face))))
       (if text (concat before text) "")))
    (_ "")))

(defun overlook--line (row fit &optional indent)
  "ROW's content as one string after INDENT, laid out as with FIT.
See `overlook--segment'."
  (let ((line (or indent "")))
    (dolist (segment (overlook--segments
                      (overlook-row-content row)
                      (and fit (- (overlook--window-width) (length line)))))
      (setq line (concat line (overlook--segment segment line fit))))
    line))

(defun overlook--add-faces (faces start end string &optional append)
  "Add FACES, a face or list of faces, to STRING from START to END.
They go under its own faces with APPEND, else over them."
  (dolist (face (if (and (consp faces) (not (keywordp (car faces)))) faces (list faces)))
    (add-face-text-property start end face append string)))

(defun overlook--row-look (row text start end)
  "Add ROW's face to TEXT past START, and dim it before END when ROW is dim."
  (when (overlook-row-face row)
    (overlook--add-faces (overlook-row-face row) start (length text) text t))
  (when (overlook-row-dim row)
    (add-face-text-property 0 end 'shadow nil text)))

(defun overlook-row-text (row)
  "ROW's content as one string with its look, nothing cut or aligned.
For views other than the dashboard buffer."
  (let ((text (overlook--line row nil)))
    (overlook--row-look row text 0 (length text))
    text))

(defun overlook-row-key (row &optional text)
  "What identifies ROW across redraws: its id, else its line TEXT, trimmed.
TEXT defaults to `overlook-row-text'."
  (or (overlook-row-id row)
      (string-trim (substring-no-properties (or text (overlook-row-text row))))))

(defun overlook--choose-at-point (choose)
  "Call CHOOSE with the answer at point, or visit the row off any answer."
  (if-let* ((key (get-text-property (point) 'overlook-choice)))
      (funcall choose key)
    (overlook-visit)))

(defun overlook--keymap (row)
  "Keymap of ROW: its own, under keys giving the answers it offers."
  (if-let* ((choose (overlook-row-choose row))
            ((overlook-row-choices row)))
      (let ((map (make-sparse-keymap)))
        (pcase-dolist (`(,key . ,_) (overlook-row-choices row))
          (keymap-set map key (lambda () (interactive) (funcall choose key))))
        (keymap-set map "RET" (lambda () (interactive) (overlook--choose-at-point choose)))
        (keymap-set map "<mouse-1>" (lambda (event)
                                      (interactive "e")
                                      (mouse-set-point event)
                                      (overlook--choose-at-point choose)))
        (when (overlook-row-keymap row)
          (set-keymap-parent map (overlook-row-keymap row)))
        map)
    (overlook-row-keymap row)))

(defun overlook--choices-line (row prefix)
  "The line under ROW offering its answers, after PREFIX, or an empty string."
  (if-let* ((choices (overlook-row-choices row)))
      (concat prefix
              (mapconcat (pcase-lambda (`(,key ,label . ,_))
                           (propertize (concat (propertize key 'face 'help-key-binding) " "
                                               (truncate-string-to-width label 40 nil nil "…"))
                                       'overlook-choice key
                                       'mouse-face 'highlight))
                         choices "  ")
              "\n")
    ""))

(defun overlook--row-lines (row indent)
  "ROW's text in the dashboard after INDENT, its line then its answers'.
Returns (TEXT . ID), ID being the row's id, else its trimmed text."
  (let* ((line (overlook--line row t indent))
         (heading-end (1+ (length line)))
         (wrap (and (overlook-row-wrap row)
                    (concat indent (overlook-row-wrap row))))
         (text (concat line "\n" (overlook--choices-line row (or wrap indent))))
         (keymap (overlook--keymap row)))
    (overlook--row-look row text (length indent) heading-end)
    (when (overlook-row-heading row)
      (put-text-property 0 heading-end 'overlook-heading t text))
    (when (overlook-row-attention row)
      (put-text-property 0 heading-end 'overlook-attention t text))
    (add-text-properties
     0 (length text)
     `(,@(and (overlook-row-id row) (list 'overlook-item (overlook-row-id row)))
       ,@(and (overlook-row-action row) (list 'overlook-action (overlook-row-action row)))
       ,@(and (overlook-row-help row) (list 'help-echo (overlook-row-help row)))
       ,@(and wrap (list 'wrap-prefix wrap))
       ,@(and keymap (list 'keymap keymap)))
     text)
    (cons text (overlook-row-key row line))))

(defun overlook--end-with-blank (section)
  "Insert a blank line at point, the end of SECTION, as part of SECTION.
Like Magit's, it highlights and folds with SECTION."
  (let ((start (point)))
    (unless (oref section content)
      (oset section content (copy-marker start)))
    (insert "\n")
    (put-text-property start (point) 'magit-section section)
    (oset section end (point-marker))
    (when (oref section hidden) (magit-section-hide section))))

(defun overlook--insert-row (row indent)
  "Insert ROW after INDENT, with the rows under it, and return its section."
  (pcase-let* ((`(,text . ,id) (overlook--row-lines row indent))
               (children (overlook-row-children row))
               (inner (if (overlook-row-nest row) (concat indent "  ") indent))
               (section
                (magit-insert-section (overlook-section id (overlook-row-folded row))
                  (insert text)
                  (when children
                    (let ((heading-end (point)))
                      (magit-insert-heading)
                      (if (functionp children)
                          (magit-insert-section-body
                            (overlook-insert-rows (overlook-row-rows row) inner))
                        (overlook-insert-rows children inner))
                      (when (and (= (point) heading-end)
                                 (not (oref magit-insert-section--current washer)))
                        (oset magit-insert-section--current content nil)))))))
    (when (overlook-row-gap row) (overlook--end-with-blank section))
    section))

(defun overlook-insert-rows (rows &optional indent)
  "Insert ROWS at point as dashboard sections, each after INDENT."
  (dolist (row rows)
    (overlook--insert-row row (or indent ""))))

(defun overlook-format-duration (seconds)
  "Format SECONDS compactly with its two largest units, like 2h10m or 3d4h."
  (let ((m (/ (max 0 (floor seconds)) 60)))
    (cond ((< m 60) (format "%dm" m))
          ((< m 1440) (format "%dh%dm" (/ m 60) (% m 60)))
          (t (format "%dd%dh" (/ m 1440) (% (/ m 60) 24))))))

(defun overlook-main-window ()
  "Select the most recently used window that is not a side window."
  (when (window-parameter (selected-window) 'window-side)
    (select-window (get-mru-window nil nil t))))

;;; Perspectives section

(defun overlook--sections ()
  "Functions of `overlook-sections', sorted by `overlook-section-order'."
  (let (functions)
    (run-hook-wrapped 'overlook-sections (lambda (f) (push f functions) nil))
    (seq-sort-by (lambda (f) (or (seq-position overlook-section-order f)
                                 (length overlook-section-order)))
                 #'< (nreverse functions))))

(defun overlook--heading-marks (name)
  "The marks `overlook-heading-mark-functions' put after perspective NAME."
  (mapconcat (lambda (function) (or (funcall function name) ""))
             overlook-heading-mark-functions))

(defun overlook--perspective-row (name current)
  "The heading of perspective NAME over its rows, or nil when left out.
CURRENT is the current perspective's name.  See `overlook--perspectives'."
  (let* ((marks (overlook--heading-marks name))
         (rows (append (overlook-rows 'overlook-perspective-functions name)
                       (unless (overlook-worktrees name)
                         (overlook-rows 'overlook-worktree-functions name nil))))
         (row (overlook-row
               :id (cons 'perspective name)
               :content (list (propertize (concat name marks)
                                          'face (if (equal name current)
                                                    'overlook-heading-current
                                                  'overlook-heading))
                              (when-let* ((tag (and overlook-perspective-annotation
                                                    (funcall overlook-perspective-annotation name))))
                                (propertize (concat " " tag) 'face 'shadow)))
               :heading t
               :action (lambda () (overlook-show-elsewhere name #'ignore))
               :children rows)))
    (when (and (or rows (equal name current) overlook-show-empty-perspectives
                   (not (string-empty-p marks)))
               (or (equal name current)
                   (null overlook-perspective-filter)
                   (funcall overlook-perspective-filter name)
                   (overlook-row-attention-p row)))
      row)))

(defun overlook--perspectives ()
  "Each perspective's heading over its rows.
One with no rows and no mark after its heading is left out unless
current or `overlook-show-empty-perspectives' is set.  Those
`overlook-perspective-filter' hides are left out unless current or
needing attention."
  (let ((current (overlook-current-perspective)))
    (overlook-gaps (seq-keep (lambda (name) (overlook--perspective-row name current))
                             (overlook-ordered-perspectives)))))

(defun overlook--perspectives-section ()
  "The Perspectives section."
  (overlook-section-row "Perspectives" (overlook--perspectives)))

(add-hook 'overlook-sections #'overlook--perspectives-section)

;;; Model

(defvar overlook--model nil
  "The model `overlook-model' last gathered, as (GENERATION . SECTIONS).")

(defun overlook-model ()
  "The dashboard as data, gathered afresh: a list of sections.
Each is a row, as `overlook-row' describes, its children the rows of
the section.  Views keep it as `overlook-latest-model' gives it."
  (let* ((generation overlook--generation)
         (overlook--buffers-cache (make-hash-table :test #'equal))
         (overlook--roots-cache (make-hash-table :test #'equal))
         (overlook--worktrees-cache (make-hash-table :test #'equal))
         (sections (progn
                     (run-hooks 'overlook-before-render-hook)
                     (seq-mapcat (lambda (function) (ensure-list (funcall function)))
                                 (overlook--sections)))))
    (setq overlook--model (cons generation sections))
    (run-hooks 'overlook-after-model-hook)
    sections))

(defun overlook-model-fresh-p ()
  "Non-nil when no `overlook-refresh' came since the last model was gathered."
  (and overlook--model (= (car overlook--model) overlook--generation)))

(defun overlook-latest-model ()
  "The dashboard's model: the last one gathered while fresh, else a new one.
The dashboard gathers one each redraw, so other views of it share that
one; see `overlook-after-model-hook'."
  (if (overlook-model-fresh-p)
      (cdr overlook--model)
    (overlook-model)))

;;; Render

(defun overlook--goto-current ()
  "Move to the current perspective's heading; nil when it is not shown."
  (when-let* ((name (overlook-current-perspective))
              (match (save-excursion
                       (goto-char (point-min))
                       (text-property-search-forward
                        'overlook-item (cons 'perspective name) #'equal))))
    (goto-char (prop-match-beginning match))))

(defun overlook--place (pos)
  "Where POS is, as (SECTION LINE CHAR NUMBER), to find it after a redraw.
SECTION is the innermost one at POS below the root, LINE and CHAR are
relative to its start, and NUMBER is POS's line number."
  (save-excursion
    (goto-char pos)
    (let ((section (magit-current-section)))
      `(,@(if (and section (oref section parent))
              (cons section (magit-section-get-relative-position section))
            (list nil nil nil))
        ,(line-number-at-pos)))))

(defun overlook--find-place (place &optional successor)
  "Position of PLACE, from `overlook--place', in the redrawn dashboard.
With SUCCESSOR, a section that is gone gives way to a nearby one;
otherwise, or with no section left at all, PLACE's line number is used."
  (pcase-let ((`(,section ,line ,char ,number) place))
    (save-excursion
      (goto-char (point-min))
      (unless (and section
                   (if successor
                       (magit-section-goto-successor section line char)
                     (when-let* ((found (magit-get-section (magit-section-ident section))))
                       (goto-char (oref found start))
                       (forward-line line))))
        (forward-line (1- number)))
      (point))))

(defun overlook--redrawn-point (place)
  "Where point at PLACE goes after a redraw.
After a perspective switch, it goes to the current perspective's heading."
  (save-excursion
    (unless (and overlook--to-current (overlook--goto-current))
      (goto-char (overlook--find-place place t)))
    (while (and (invisible-p (point)) (not (bobp)))
      (forward-line -1))
    (point)))

(defun overlook--render ()
  "Redraw the dashboard, keeping each window on the same rows.
After a perspective switch, point goes to the current perspective instead."
  (when-let* ((dashboard (get-buffer overlook-buffer-name)))
    (with-current-buffer dashboard
      (let* ((windows (get-buffer-window-list dashboard nil t))
             ;; The selected window goes last, so the buffer's point ends up as its.
             (places (if windows
                         (mapcar (lambda (window)
                                   (list window
                                         (overlook--place (window-point window))
                                         (overlook--place (window-start window))))
                                 (reverse windows))
                       (list (list nil (overlook--place (point)) nil))))
             (inhibit-read-only t))
        (erase-buffer)
        (let ((model (overlook-model)))
          (magit-insert-section (overlook-section 'root)
            (overlook-insert-rows model)))
        (magit-section-show magit-root-section)
        (pcase-dolist (`(,window ,point ,start) places)
          (let ((point (overlook--redrawn-point point))
                ;; Erasing sent the window back to the top; put it where it was.
                (start (if start (overlook--find-place start) (point-min))))
            (goto-char point)
            (when window
              (set-window-point window point)
              (set-window-start window start t))
            (overlook--remember-point point start)))
        (setq overlook--to-current nil)
        (magit-section-update-highlight t)))))

(defvar-local overlook--point nil
  "Point and window start, as markers, after the last redraw or command.")

(defun overlook--remember-point (&optional point start)
  "Record POINT and START, by default those of the selected window."
  (let ((point (or point (point)))
        (start (or start (window-start))))
    (if overlook--point
        (progn (move-marker (car overlook--point) point)
               (move-marker (cdr overlook--point) start))
      (setq overlook--point (cons (copy-marker point) (copy-marker start))))))

(defun overlook--restore-points (&rest _)
  "Put dashboard windows left at the top back where `overlook--point' was.
Restoring a window configuration saved before a redraw, as Ediff does on
quitting, leaves them there."
  (when-let* ((dashboard (get-buffer overlook-buffer-name)))
    (pcase-let ((`(,point . ,start) (buffer-local-value 'overlook--point dashboard)))
      (dolist (window (get-buffer-window-list dashboard nil t))
        (when (and point (/= point 1)
                   (= (window-point window) 1)
                   (= (window-start window) 1))
          (set-window-point window point)
          (set-window-start window start t))))))

;;; Navigation

(defun overlook--step (forward property what)
  "Move to the next line starting with PROPERTY, wrapping.
FORWARD picks the direction; WHAT names those lines when there is none."
  (let ((start (line-beginning-position))
        (pos nil))
    (save-excursion
      (catch 'found
        (dotimes (_ (count-lines (point-min) (point-max)))
          (if forward
              (when (or (/= 0 (forward-line 1)) (eobp)) (goto-char (point-min)))
            (when (/= 0 (forward-line -1)) (goto-char (point-max)) (forward-line -1)))
          (when (= (point) start) (throw 'found nil))
          (when (and (get-text-property (point) property) (not (invisible-p (point))))
            (throw 'found (setq pos (point)))))))
    (if pos
        (goto-char pos)
      (message "No %s%s" (if (get-text-property start property) "other " "") what))))

(defun overlook-next-heading ()
  "Move to the next heading."
  (interactive)
  (overlook--step t 'overlook-heading "heading"))

(defun overlook-previous-heading ()
  "Move to the previous heading."
  (interactive)
  (overlook--step nil 'overlook-heading "heading"))

(defun overlook-next-attention ()
  "Move to the next row needing your attention."
  (interactive)
  (overlook--step t 'overlook-attention "row needing attention"))

(defun overlook-previous-attention ()
  "Move to the previous row needing your attention."
  (interactive)
  (overlook--step nil 'overlook-attention "row needing attention"))

(defun overlook-item-at-point ()
  "The id of the row at point, as given to `overlook-row', or nil."
  (get-text-property (line-beginning-position) 'overlook-item))

(defun overlook-delete ()
  "Delete what the row at point stands for, such as an agent or a worktree."
  (interactive)
  (let ((item (overlook-item-at-point)))
    (unless (and item (run-hook-with-args-until-success 'overlook-delete-functions item))
      (user-error "Nothing to delete on this line"))))

(defun overlook-visit ()
  "Run the action of the row at point, or fold the rows under it."
  (interactive)
  (if-let* ((action (get-text-property (line-beginning-position) 'overlook-action)))
      (funcall action)
    (let ((section (magit-current-section)))
      (if (and section (oref section content))
          (magit-section-toggle section)
        (user-error "Nothing to visit on this line")))))

;;; Window

(defun overlook--display ()
  "Show the dashboard in a side window and return that window."
  (display-buffer-in-side-window
   (get-buffer overlook-buffer-name)
   `((side . ,overlook-side) (slot . -1) (window-width . ,(overlook-columns))
     (window-parameters (no-delete-other-windows . t)))))

(defun overlook--follow ()
  "Show the dashboard in the selected frame when it is toggled on."
  (when (and overlook--shown (overlook-live-p)
             (not (get-buffer-window overlook-buffer-name)))
    (overlook--display)))

(defun overlook-show-elsewhere (perspective show)
  "Switch to PERSPECTIVE when non-nil, then call SHOW in a main window.
The dashboard stays shown; for actions on dashboard rows."
  (when perspective (overlook-switch-perspective perspective))
  (overlook-main-window)
  (funcall show)
  (setq overlook--shown t)
  (overlook--follow))

;;;###autoload
(defun overlook ()
  "Toggle the dashboard side window."
  (interactive)
  (if-let* ((window (get-buffer-window overlook-buffer-name)))
      (progn (setq overlook--shown nil)
             (delete-window window))
    (setq overlook--shown t)
    (with-current-buffer (get-buffer-create overlook-buffer-name)
      (unless (derived-mode-p 'overlook-mode) (overlook-mode)))
    (unless overlook--tick-timer
      (setq overlook--tick-timer
            (run-with-timer 0 overlook-tick-interval #'overlook--tick)))
    (overlook--render)
    (select-window (overlook--display))))

(provide 'overlook)
;;; overlook.el ends here
