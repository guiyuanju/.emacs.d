;;; overlook.el --- A dashboard over your projects, repos and agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
;; Maintainer: guiyuanju <guiyuanjune@outlook.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (tabspaces "1.10") (agent-shell "0.87.3") (simple-httpd "1.7"))
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

;; The Emacs view of the shared dashboard model.
;; Project backends and model collection live in `overlook-model';
;; row data and content segments live in `overlook-row'.

;;; Code:

(require 'overlook-model)
(require 'magit-section)

(defcustom overlook-width 65
  "Width of the dashboard side window.
An integer is a number of columns; a float is a fraction of the frame width."
  :type '(choice (natnum :tag "Columns") (float :tag "Fraction of frame"))
  :group 'overlook)

(defcustom overlook-side 'right
  "Frame side the dashboard window is shown on."
  :type '(choice (const left) (const right))
  :group 'overlook)

(defun overlook--order-selection-changed (&optional _frame)
  "Start a fresh project order when entering or leaving the dashboard."
  (setq overlook--project-order-snapshots nil)
  (when (eq (window-buffer (selected-window)) (get-buffer overlook-buffer-name))
    (overlook-refresh)))

(add-hook 'window-selection-change-functions #'overlook--order-selection-changed)

(defcustom overlook-refresh-idle 0.5
  "Seconds input must pause before the dashboard redraws."
  :type 'number
  :group 'overlook)

(defcustom overlook-refresh-gap 1
  "Fewest seconds between two redraws the dashboard asks for itself."
  :type 'number
  :group 'overlook)

(defcustom overlook-refresh-max-wait 10
  "Most seconds a redraw waits for input to pause."
  :type 'number
  :group 'overlook)

(put 'overlook-detached 'permanent-local t)

(put 'overlook--detach-shown 'permanent-local-hook t)

(defvar overlook--to-current nil
  "Non-nil when the next redraw moves point to the current project.")

;;; Refresh

(defvar overlook--timer nil)

(defvar overlook--shown nil
  "Non-nil while the dashboard is toggled on; every project then shows it.")

(defvar overlook--rendered 0
  "When the dashboard was last redrawn.")

(defvar overlook--render-generation -1
  "Model generation last drawn in the dashboard.")

(defun overlook--visible-p ()
  "Non-nil when a window on any frame displays the dashboard."
  (get-buffer-window overlook-buffer-name t))

(defun overlook--render-when-idle (asked)
  "Redraw once input has paused for `overlook-refresh-idle' seconds.
Waits no longer than `overlook-refresh-max-wait' seconds after time ASKED."
  (if (not (overlook--visible-p))
      (setq overlook--timer nil)
    (let ((idle (current-idle-time)))
      (if (and (or (null idle) (< (float-time idle) overlook-refresh-idle))
               (< (- (float-time) asked) overlook-refresh-max-wait))
          (setq overlook--timer (run-with-timer 0.2 nil #'overlook--render-when-idle asked))
        (setq overlook--timer nil
              overlook--rendered (float-time))
        (overlook--render)))))

(defun overlook--render-soon ()
  "Redraw the dashboard once the current command is done, skipping the wait."
  (when (overlook--visible-p)
    (when (timerp overlook--timer) (cancel-timer overlook--timer))
    (setq overlook--timer (run-at-time 0 nil #'overlook--render-now))))

(defun overlook--render-now ()
  "Redraw the dashboard now."
  (setq overlook--timer nil
        overlook--rendered (float-time))
  (when (overlook--visible-p) (overlook--render)))

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
  "Dashboard over projects and what lives in them."
  (setq-local revert-buffer-function (lambda (&rest _) (overlook--render))
              truncate-lines nil
              truncate-partial-width-windows nil
              word-wrap t
              word-wrap-by-category t
              left-margin-width 1
              right-margin-width 1
              mode-line-format '(:eval (overlook--mode-line))
              ;; No fringe arrows; a folded section still ends in an ellipsis.
              magit-section-visibility-indicators '(("…" . t)))
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
  (advice-add 'magit-section-maybe-update-visibility-indicator :after #'overlook--color-ellipses)
  (advice-add 'magit-section-maybe-paint-visibility-ellipses :after #'overlook--color-ellipses)
  (add-hook 'kill-buffer-hook #'overlook--dashboard-killed nil t)
  (when (fboundp 'display-line-numbers-mode) (display-line-numbers-mode -1)))

(defun overlook--mode-line ()
  "The dashboard's mode line: its name, then `overlook-mode-line-functions'."
  (string-replace
   "%" "%%"
   (string-join (cons (concat " " (propertize "Overlook" 'face 'mode-line-buffer-id))
                      (delq nil (mapcar #'funcall overlook-mode-line-functions)))
                "   ")))

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

(defun overlook--color-ellipses (&rest _)
  "Draw the ellipses of folded sections in the face of the text before them.
Magit takes their face from `font-lock-face', which the rows do not set."
  (when (derived-mode-p 'overlook-mode)
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (eq (overlay-get overlay 'magit-vis-indicator) 'eoh)
        (let ((pos (overlay-start overlay)))
          (overlay-put overlay 'after-string
                       (propertize (substring-no-properties (overlay-get overlay 'after-string))
                                   'face (delq nil (append (mapcar (lambda (o) (overlay-get o 'font-lock-face))
                                                                   (overlays-at pos))
                                                           ;; Not `get-char-property': the face alias would
                                                           ;; give the highlight overlay's face instead.
                                                           (let ((face (get-text-property pos 'face)))
                                                             (if (keywordp (car-safe face))
                                                                 (list face)
                                                               (ensure-list face))))))))))))

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
Without FACE, TEXT keeps its own faces.  Measured in pixels, as fonts
draw glyphs like … wider than `string-width'."
  (let* ((width (lambda (s) (overlook-pixel-width (if face (propertize s 'face face) s))))
         (cut (truncate-string-to-width text (/ pixels (max 1 (funcall width "x"))) nil nil "…")))
    (while (and (> (string-width cut) 1) (> (funcall width cut) pixels))
      (setq cut (truncate-string-to-width text (1- (string-width cut)) nil nil "…")))
    (when (>= pixels (* 4 (frame-char-width)))
      (if face (propertize cut 'face face) cut))))

(defun overlook-string-columns (string)
  "Columns STRING takes as drawn; fonts draw icons wider than `string-width'."
  (max (string-width string)
       (ceiling (overlook-pixel-width string) (frame-char-width))))

(defvar overlook--pad-widths (make-hash-table :test #'eq :weakness 'key)
  "Columns the widest of each `:pad' segment's texts takes as drawn.")

(defun overlook--pad (text like)
  "Spaces after TEXT making it as wide as the widest of LIKE as drawn."
  (make-string
   (max 0 (- (with-memoization (gethash like overlook--pad-widths)
               (apply #'max 0 (mapcar #'overlook-string-columns like)))
             (overlook-string-columns text)))
   ?\s))

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

(defun overlook--segment (segment head)
  "Lay out SEGMENT after HEAD for the current dashboard window."
  (pcase segment
    (`(:pad ,text . ,_)
     (concat text (overlook--pad text (plist-get segment :like))))
    (`(:wrap ,pieces . ,_)
     (overlook--wrap pieces (make-string (or (plist-get segment :gap) 1) ?\s) head))
    (`(:cell ,glyph)
     (let ((pad (- (* 3 (frame-char-width)) (overlook-pixel-width glyph))))
       (concat glyph (propertize " " 'display `(space :width (,(max 1 pad)))))))
    (`(:fit ,text . ,_)
     (let* ((before (or (plist-get segment :before) ""))
            (text (overlook-fit text
                                (- (overlook-window-pixels)
                                   (overlook-pixel-width (concat head before))
                                   (* (or (plist-get segment :reserve) 0)
                                      (frame-char-width)))
                                (plist-get segment :face))))
       (if text (concat before text) "")))
    (_ (overlook-segment-text segment))))

(defun overlook--line (row &optional indent)
  "Lay out ROW's content as text after INDENT for the dashboard window."
  (let ((line (or indent "")))
    (dolist (segment (overlook-row-segments row (- (overlook--window-width) (length line))))
      (setq line (concat line (overlook--segment segment line))))
    line))

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
                                               (overlook-truncate label 40))
                                       'overlook-choice key
                                       'mouse-face 'highlight))
                         choices "  ")
              "\n")
    ""))

(defun overlook--row-lines (row indent)
  "ROW's text in the dashboard after INDENT, its line then its answers'.
Returns (TEXT . ID), ID being the row's id, else its trimmed text."
  (let* ((line (overlook--line row indent))
         (heading-end (1+ (length line)))
         (wrap (and (overlook-row-wrap row)
                    (concat indent (overlook-row-wrap row))))
         (text (concat line "\n" (overlook--choices-line row (or wrap indent))))
         (keymap (overlook--keymap row)))
    (overlook-row-apply-look row text (length indent) heading-end)
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

(defun overlook-main-window ()
  "Select the most recently used window that is not a side window."
  (when (window-parameter (selected-window) 'window-side)
    (select-window (get-mru-window nil nil t))))

;;; Render

(defun overlook--goto-current ()
  "Move to the current project's heading; nil when it is not shown."
  (when-let* ((name (overlook-current-project))
              (match (save-excursion
                       (goto-char (point-min))
                       (text-property-search-forward
                        'overlook-item (cons 'project name) #'equal))))
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
After a project switch, it goes to the current project's heading."
  (save-excursion
    (unless (and overlook--to-current (overlook--goto-current))
      (goto-char (overlook--find-place place t)))
    (while (and (invisible-p (point)) (not (bobp)))
      (forward-line -1))
    (point)))

(defun overlook--render ()
  "Redraw the dashboard, keeping each window on the same rows.
After a project switch, point goes to the current project instead."
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
            (overlook-insert-rows model))
          (setq overlook--render-generation (car overlook--model)))
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

(defun overlook-show-elsewhere (project show)
  "Switch to PROJECT when non-nil, then call SHOW in a main window.
The dashboard stays shown; for actions on dashboard rows."
  (when project (overlook-switch-project project))
  (overlook-main-window)
  (funcall show)
  (setq overlook--shown t)
  (overlook--follow))

(defun overlook-start ()
  "Make the dashboard live and draw it, without showing it."
  (with-current-buffer (get-buffer-create overlook-buffer-name)
    (unless (derived-mode-p 'overlook-mode) (overlook-mode)))
  (overlook-start-updates 'dashboard)
  (overlook--render))

;;;###autoload
(defun overlook ()
  "Toggle the dashboard side window."
  (interactive)
  (if-let* ((window (get-buffer-window overlook-buffer-name)))
      (progn (setq overlook--shown nil)
             (delete-window window))
    (setq overlook--shown t)
    (overlook-start)
    (select-window (overlook--display))))

(defun overlook--schedule-render ()
  "Schedule the Emacs view after a model invalidation."
  (when (overlook--visible-p)
    (if overlook--to-current
        (overlook--render-soon)
      (unless (timerp overlook--timer)
        (setq overlook--timer
              (run-with-timer (max 0.1 (- (+ overlook--rendered overlook-refresh-gap) (float-time)))
                              nil #'overlook--render-when-idle (float-time)))))))

(defun overlook--window-changed ()
  "Refresh a newly displayed dashboard when its model has changed."
  (when (and (overlook--visible-p)
             (or overlook--to-current
                 (/= overlook--render-generation overlook--generation)))
    (overlook--schedule-render)))

(defun overlook--project-switched ()
  "Follow a project switch and place point on its heading at the next redraw."
  (setq overlook--to-current t)
  (overlook--follow))

(defun overlook--dashboard-killed ()
  "Release the Emacs view's update subscription and pending redraw."
  (overlook-stop-updates 'dashboard)
  (when (timerp overlook--timer) (cancel-timer overlook--timer))
  (setq overlook--timer nil))

(add-hook 'overlook-refresh-hook #'overlook--schedule-render)

(add-hook 'window-configuration-change-hook #'overlook--window-changed)

(add-hook 'overlook-project-switch-hook #'overlook--project-switched)

(provide 'overlook)
;;; overlook.el ends here
