;;; overlook.el --- A dashboard over your perspectives, repos and agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
;; Maintainer: guiyuanju <guiyuanjune@outlook.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (perspective "2.22") (agent-shell "0.87.3"))
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
;; agents, and whatever else a module inserts.
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
;; Rows are plain text with properties the core understands:
;; `overlook-item' identifies a row so point stays on it across redraws,
;; `overlook-action' is called by RET, `overlook-heading' marks lines that
;; \\[overlook-next-heading] stops at, and `overlook-attention' those that
;; \\[overlook-next-attention] stops at.
;;
;; The dashboard is a `magit-section-mode' buffer: each section and row is
;; a section, so \\[magit-section-toggle] folds the rows under one and
;; Magit's section commands work.  Insert rows with `overlook-insert-row'.

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

(defcustom overlook-orphan-perspective nil
  "Perspective listing the rows that belong to no perspective, or nil.
Rows opened from there open in it, and it is left out while it has no
rows and is not current.  Without it, they are listed under the current
perspective."
  :type '(choice (const :tag "The current perspective" nil) string))

(defcustom overlook-tick-interval 5
  "Seconds between runs of `overlook-tick-hook' while the dashboard is live."
  :type 'number)

(defconst overlook-indent ""
  "Indent of rows under a heading.")

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

(defun overlook-perspective-root (name)
  "Project root of perspective NAME, or nil."
  (funcall overlook-perspective-root-function name))

(defun overlook-orphan-perspective ()
  "Name of `overlook-orphan-perspective' when it exists, else nil."
  (car (member overlook-orphan-perspective (overlook-perspectives))))

(defun overlook-add-to-perspective (name buffer)
  "Add BUFFER to perspective NAME."
  (funcall overlook-add-to-perspective-function name buffer))

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
  "Functions inserting the dashboard's top level sections, by hook depth.
Each is called with no arguments in the dashboard buffer, and usually
inserts through `overlook-insert-section'.  The perspectives section
sits at depth 0.")

(defvar overlook-perspective-functions nil
  "Functions inserting rows under a perspective's heading, by hook depth.
Each is called with the perspective's NAME in the dashboard buffer.")

(defvar overlook-orphan-functions nil
  "Functions inserting rows that belong to no perspective.
Each is called with no arguments.  The rows go under the perspective
`overlook-orphan-perspective', or else the current one.")

(defvar overlook-mode-line-functions nil
  "Functions returning strings joined into the dashboard's mode line.")

(defvar overlook-before-render-hook nil
  "Hook run in the dashboard buffer before each redraw.")

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

(defun overlook-refresh ()
  "Redraw the dashboard soon, at most once per burst."
  (when (and (overlook-live-p) (not (timerp overlook--timer)))
    (setq overlook--timer
          (run-with-timer 0.1 nil (lambda ()
                                    (setq overlook--timer nil)
                                    (overlook--render))))))

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
  (when (fboundp 'display-line-numbers-mode) (display-line-numbers-mode -1)))

(defun overlook--mode-line ()
  "The dashboard's mode line: its name, then `overlook-mode-line-functions'."
  (string-replace
   "%" "%%"
   (string-join (cons (concat " " (propertize "Overlook" 'face 'mode-line-buffer-id))
                      (delq nil (mapcar #'funcall overlook-mode-line-functions)))
                "   ")))

;;; Drawing helpers

(defface overlook-section
  '((t :inherit (font-lock-keyword-face bold)))
  "Face of section titles.")

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

(defun overlook--row-id (line)
  "What identifies row LINE across redraws: its `overlook-item', else its text."
  (or (get-text-property 0 'overlook-item line)
      (string-trim (substring-no-properties line))))

(defun overlook-insert-row (line &optional children hide)
  "Insert LINE, a row ending in a newline, and return its section.
CHILDREN, a function, inserts the rows under it; they start folded when
HIDE is non-nil, until the row is toggled.  CHILDREN can drop the row by
calling `magit-cancel-section'; the section's end is then nil.  CHILDREN
can wrap its insertion in `magit-insert-section-body' to put it off until
the row is first unfolded."
  (magit-insert-section (overlook-section (overlook--row-id line) hide)
    (insert line)
    (when children
      (let ((heading-end (point)))
        (magit-insert-heading)
        (funcall children)
        (when (and (= (point) heading-end)
                   (not (oref magit-insert-section--current washer)))
          (oset magit-insert-section--current content nil))))))

(defun overlook-end-with-blank (section)
  "Insert a blank line at point, the end of SECTION, as part of SECTION.
Like Magit's, it highlights and folds with SECTION."
  (let ((start (point)))
    (unless (oref section content)
      (oset section content (copy-marker start)))
    (insert "\n")
    (put-text-property start (point) 'magit-section section)
    (oset section end (point-marker))
    (when (oref section hidden) (magit-section-hide section))))

(defun overlook-insert-section (title body)
  "Insert section TITLE, then call BODY, a function, to fill it.
The title is dropped when BODY inserts nothing.  TITLE's text properties,
like `overlook-action', cover its whole line.  A blank line ends the
section, folded with it."
  (let ((line (concat title "\n")))
    (add-face-text-property 0 (length title) 'overlook-section t line)
    (cl-loop for (prop value) on (text-properties-at 0 title) by #'cddr
             unless (eq prop 'face)
             do (put-text-property 0 (length line) prop value line))
    (overlook-insert-row line (lambda ()
                                (funcall body)
                                (magit-cancel-section t)
                                (insert "\n")))))

(defun overlook-align-right (text columns)
  "TEXT aligned to end COLUMNS before the window's right edge."
  (concat (propertize " " 'display `(space :align-to (- right ,(+ columns (string-width text)))))
          text))

(defun overlook-columns ()
  "Width of the dashboard window in columns, per `overlook-width'."
  (if (floatp overlook-width)
      (round (* overlook-width (frame-width)))
    overlook-width))

(defun overlook-window-pixels ()
  "Body width in pixels of the window showing the dashboard."
  (if-let* ((window (get-buffer-window (current-buffer) t)))
      (window-body-width window t)
    (* (overlook-columns) (frame-char-width))))

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

(defun overlook-glyph-cell (glyph)
  "GLYPH padded to three columns, so the names after it line up.
Fonts draw glyphs like ◐ two columns wide but ⚠ or ⎇ one."
  (let ((pad (- (* 3 (frame-char-width)) (overlook-pixel-width glyph))))
    (concat glyph (propertize " " 'display `(space :width (,(max 1 pad)))))))

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

(defun overlook--heading (name &optional current)
  "Heading line of perspective NAME, highlighted when CURRENT."
  (propertize (concat (propertize name 'face (if current 'overlook-heading-current
                                                'overlook-heading))
                      (when-let* ((tag (and overlook-perspective-annotation
                                            (funcall overlook-perspective-annotation name))))
                        (propertize (concat " " tag) 'face 'shadow))
                      "\n")
              'overlook-item (cons 'perspective name)
              'overlook-heading t
              'overlook-action (lambda () (overlook-show-elsewhere name #'ignore))))

(defun overlook--perspectives ()
  "Insert each perspective's heading and rows.
Rows of no perspective go under `overlook-orphan-perspective', which is
left out while it has none and is not current, or else the current one.
Those `overlook-perspective-filter' hides are left out unless current or
needing attention."
  (let* ((current (overlook-current-perspective))
         (orphans (or (overlook-orphan-perspective) current))
         (previous nil))
    (dolist (name (overlook-ordered-perspectives))
      (let ((start (point)))
        (when previous (overlook-end-with-blank previous))
        (let ((section (overlook-insert-row
                        (overlook--heading name (equal name current))
                        (lambda ()
                          (run-hook-with-args 'overlook-perspective-functions name)
                          (when (equal name orphans)
                            (run-hooks 'overlook-orphan-functions)
                            (unless (equal name current) (magit-cancel-section t)))))))
          (if (and (oref section end)
                   (or (equal name current)
                       (null overlook-perspective-filter)
                       (funcall overlook-perspective-filter name)
                       (text-property-not-all start (point) 'overlook-attention nil)))
              (setq previous section)
            (delete-region start (point))))))))

(defun overlook--perspectives-section ()
  "Insert the Perspectives section."
  (overlook-insert-section "Perspectives" #'overlook--perspectives))

(add-hook 'overlook-sections #'overlook--perspectives-section)

;;; Render

(defun overlook--goto-current ()
  "Move to the current perspective's heading; nil when it is not shown."
  (when-let* ((name (overlook-current-perspective))
              (match (save-excursion
                       (goto-char (point-min))
                       (text-property-search-forward
                        'overlook-item (cons 'perspective name) #'equal))))
    (goto-char (prop-match-beginning match))))

(defun overlook--render ()
  "Redraw the dashboard, keeping point on the same row.
After a perspective switch, point goes to the current perspective instead."
  (when-let* ((dashboard (get-buffer overlook-buffer-name)))
    (with-current-buffer dashboard
      (let* ((window (get-buffer-window dashboard t))
             (section (magit-current-section))
             (position (and section (magit-section-get-relative-position section)))
             (line (line-number-at-pos))
             (column (current-column))
             (overlook--buffers-cache (make-hash-table :test #'equal))
             (inhibit-read-only t))
        (erase-buffer)
        (run-hooks 'overlook-before-render-hook)
        (magit-insert-section (overlook-section 'root)
          (run-hooks 'overlook-sections))
        (magit-section-show magit-root-section)
        (goto-char (point-min))
        (cond ((and overlook--to-current (overlook--goto-current))
               (setq column 0))
              ((and section (oref section parent)
                    (apply #'magit-section-goto-successor section position)))
              (t (forward-line (1- line))))
        (setq overlook--to-current nil)
        (while (and (invisible-p (point)) (not (bobp)))
          (forward-line -1))
        (move-to-column column)
        (magit-section-update-highlight t)
        (when window (set-window-point window (point)))))))

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
  "The `overlook-item' of the row at point, or nil."
  (get-text-property (line-beginning-position) 'overlook-item))

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
