;;; overlook-row.el --- Shared dashboard rows and content segments -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
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

;; Rows and content segments shared by the dashboard and other views.
;; No window measurement or Magit dependency is needed to inspect a row.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup overlook nil
  "A dashboard over projects, repos and agents."
  :group 'tools
  :prefix "overlook-")

(defcustom overlook-agent-icons nil
  "Icons shown in place of agents' names, keyed by name."
  :type '(alist :key-type string :value-type string)
  :group 'overlook)

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
  (:cell GLYPH), GLYPH padded to `overlook-cell-columns', as
          `overlook-glyph-cell' makes;
  (:fit TEXT :face FACE :before GAP :reserve N), TEXT in FACE, or in
          its own faces without one, after GAP, cut with an ellipsis
          to fit before the last N columns, or left out with GAP when
          hardly any fits;
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
KEY giving that answer.

COMMANDS are what views without the dashboard's keys, such as
overlook-remote's page, offer on the row.  Each is a plist:
  :name     its name, one of the row's;
  :label    what its button says;
  :input    when non-nil, what to ask for as text;
  :options  strings to pick one of;
  :confirm  a question to confirm first, or a function returning one,
            or nil when none is needed;
  :run      a function of the text, when :input, and then the option,
            when :options.  It must not ask in the minibuffer; returning
            an agent's buffer shows that agent, and (BUFFER . TEXT)
            also leaves TEXT in its prompt, unsent.
DIFF is a function returning the unified diff the row stands for, as
text, which such views show when the row is picked."
  id content heading attention folded children nest gap dim face
  action help wrap keymap choices choose commands diff)

(defun overlook-row-command (row name)
  "ROW's command NAME, or nil."
  (seq-find (lambda (command) (equal (plist-get command :name) name))
            (overlook-row-commands row)))

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

(defun overlook-section-row (title rows &optional action commands)
  "A top level section TITLE over ROWS, or nil when ROWS is empty.
ACTION is what RET on the title does; by default it folds the section.
COMMANDS are the title's, as `overlook-row' describes."
  (when rows
    (let ((title (copy-sequence title)))
      (add-face-text-property 0 (length title) 'overlook-section t title)
      (overlook-row :content title :heading t :action action :children rows :gap t
                    :commands commands))))

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

(defun overlook-mode-line-icon (name fallback &optional face)
  "Return Codicon NAME, or FALLBACK without Nerd Icons, optionally in FACE."
  (if (fboundp 'nerd-icons-codicon)
      (nerd-icons-codicon name :face face :height 0.85)
    (propertize fallback 'face face)))

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

(defconst overlook-cell-columns 3
  "Columns of a glyph cell, and the indent of a `:nest' row's children.
Those then start under the name after the row's cell.")

(defun overlook-glyph-cell (glyph)
  "A segment of GLYPH padded to `overlook-cell-columns', lining up names after it.
Fonts draw glyphs like ◐ two columns wide but ⚠ or ⎇ one."
  (list :cell glyph))

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

(defun overlook--add-faces (faces start end string &optional append)
  "Add FACES, a face or list of faces, to STRING from START to END.
They go under its own faces with APPEND, else over them."
  (dolist (face (if (and (consp faces) (not (keywordp (car faces)))) faces (list faces)))
    (add-face-text-property start end face append string)))

(defun overlook-row-apply-look (row text start end)
  "Add ROW's face to TEXT past START, and dim it before END when ROW is dim."
  (when (overlook-row-face row)
    (overlook--add-faces (overlook-row-face row) start (length text) text t))
  (when (overlook-row-dim row)
    (add-face-text-property 0 end 'shadow nil text)))

(defun overlook-row-text (row)
  "ROW's content as one string with its look, nothing cut or aligned.
For views other than the dashboard buffer."
  (let ((text (mapconcat #'overlook-segment-text (overlook-row-segments row) "")))
    (overlook-row-apply-look row text 0 (length text))
    text))

(defun overlook-row-key (row &optional text)
  "What identifies ROW across redraws: its id, else its line TEXT, trimmed.
TEXT defaults to `overlook-row-text'."
  (or (overlook-row-id row)
      (string-trim (substring-no-properties (or text (overlook-row-text row))))))

(defun overlook-segment-text (segment)
  "SEGMENT as unbounded text, without measuring any window or font."
  (pcase segment
    ((pred stringp) segment)
    (`(:right ,text . ,_)
     (concat (propertize " " 'display
                         `(space :align-to (- right ,(+ (plist-get segment :columns)
                                                        (string-width text)))))
             text))
    (`(:pad ,text . ,_)
     (let* ((width (lambda (s) (string-width (overlook-alt-text s))))
            (widest (apply #'max 0 (mapcar width (plist-get segment :like)))))
       (concat text (make-string (max 0 (- widest (funcall width text))) ?\s))))
    (`(:wrap ,pieces . ,_)
     (string-join pieces (make-string (or (plist-get segment :gap) 1) ?\s)))
    (`(:cell ,glyph) (concat glyph " "))
    (`(:fit ,text . ,_)
     (concat (or (plist-get segment :before) "")
             (if-let* ((face (plist-get segment :face)))
                 (propertize text 'face face)
               text)))
    (_ "")))

;;; Faces

(defface overlook-section
  '((t :inherit (font-lock-keyword-face bold)))
  "Face of section titles."
  :group 'overlook)

(defface overlook-tabular
  '((t))
  "Face of rows whose text lines up in columns.
Views in proportional fonts draw such rows in a fixed-pitch one."
  :group 'overlook)

(defface overlook-heading
  '((t :inherit bold))
  "Face of project headings."
  :group 'overlook)

(defface overlook-heading-current
  '((t :inherit (success bold)))
  "Face of the current project's heading."
  :group 'overlook)

(defun overlook-truncate (text width)
  "TEXT cut to WIDTH columns with an ellipsis in the face of the text it ends."
  (truncate-string-to-width
   text width nil nil
   (propertize "…" 'face (and (> (length text) 0)
                              (get-text-property (min (1- (length text)) (max 0 (- width 2)))
                                                 'face text)))))

(provide 'overlook-row)
;;; overlook-row.el ends here
