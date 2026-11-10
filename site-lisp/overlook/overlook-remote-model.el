;;; overlook-remote-model.el --- Dashboard data for the browser -*- lexical-binding: t; -*-

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

;; Serializes shared rows and computes dashboard subtree deltas.
;; Keeps the browser protocol separate from HTTP connections.

;;; Code:

(require 'overlook-agent-core)

(defcustom overlook-remote-styles
  '((overlook-section . "section") (overlook-tabular . "tabular")
    (overlook-usage-bar-track . "track") (overlook-agent-done . "done")
    (overlook-agent-waiting . "waiting") (help-key-binding . "key")
    (shadow . "dim") (font-lock-comment-face . "dim") (completions-annotations . "dim")
    (warning . "warning") (error . "error") (success . "success")
    (link . "accent") (font-lock-keyword-face . "accent")
    (font-lock-string-face . "string") (font-lock-function-name-face . "name")
    (font-lock-type-face . "name") (font-lock-doc-face . "italic")
    (bold . "bold") (italic . "italic"))
  "Styles the page draws faces in, each (FACE . STYLE).
The faces a face inherits from count only when it has no style here."
  :type '(alist :key-type face :value-type string)
  :group 'overlook)

(defun overlook-remote--text (text)
  "TEXT without properties, or an empty string for nil."
  (if text (substring-no-properties text) ""))

;;; Dashboard

(defun overlook-remote--styles (face)
  "Styles of FACE, a face or list of faces, from `overlook-remote-styles'.
A face without one takes those of the faces it inherits from, and
\"bold\" or \"italic\" when it sets that itself."
  (let ((todo (list face))
        seen styles)
    (while todo
      (let ((face (pop todo)))
        (cond ((and (symbolp face) face (not (keywordp face)) (facep face)
                    (not (memq face seen)))
               (push face seen)
               (if-let* ((style (alist-get face overlook-remote-styles)))
                   (push style styles)
                 (setq styles (append (overlook-remote--own-styles
                                       (face-attribute face :weight nil)
                                       (face-attribute face :slant nil))
                                      styles))
                 (push (face-attribute face :inherit nil) todo)))
              ((keywordp (car-safe face))
               (setq styles (append (overlook-remote--own-styles (plist-get face :weight)
                                                                 (plist-get face :slant))
                                    styles))
               (push (plist-get face :inherit) todo))
              ((proper-list-p face) (setq todo (append face todo))))))
    (delete-dups (nreverse styles))))

(defun overlook-remote--own-styles (weight slant)
  "Styles a face of WEIGHT and SLANT sets itself."
  (append (and (memq weight '(semi-bold bold extra-bold ultra-bold heavy black ultra-heavy))
               '("bold"))
          (and (memq slant '(italic oblique)) '("italic"))))

(defun overlook-remote--merge-run (head run)
  "Add RUN's text to run HEAD when both are text of one look.
Return non-nil when it did; HEAD may be nil or not a run."
  (when (and (plist-get head :text)
             (not (plist-get head :icon))
             (not (plist-get run :icon))
             (equal (plist-get head :styles) (plist-get run :styles)))
    (plist-put head :text (concat (plist-get head :text) (plist-get run :text)))))

(defun overlook-remote--runs (row text)
  "TEXT's runs of one look, ROW's look added, each (:text T :styles NAMES).
A string with an `overlook-alt' carries that name as :icon and fallback text."
  (let ((text (copy-sequence text))
        (start 0)
        runs)
    (overlook-row-apply-look row text 0 (length text))
    (while (< start (length text))
      (let* ((alt (get-text-property start 'overlook-alt text))
             (end (if alt
                      (next-single-property-change start 'overlook-alt text (length text))
                    (next-property-change start text (length text))))
             (run (append (list :text (or alt (substring-no-properties text start end))
                                :styles (vconcat (overlook-remote--styles
                                                  (get-text-property start 'face text))))
                          (and alt (list :icon alt)))))
        (unless (overlook-remote--merge-run (car runs) run)
          (push run runs))
        (setq start end)))
    (nreverse runs)))

(defun overlook-remote--spans (row)
  "ROW's content as the page lays it out, a vector of spans in order.
A span is a run of one look, (:text T :styles NAMES); (:right RUNS),
aligned to the right edge; (:fit RUNS), cut to fit its line; or
\(:wrap PIECES :gap N), pieces, each a vector of runs, wrapping to lines
that start where the first did."
  (let (spans)
    (cl-flet ((add (text)
                (dolist (run (overlook-remote--runs row (if spans text (string-trim-left text))))
                  (unless (overlook-remote--merge-run (car spans) run)
                    (push run spans)))))
      (dolist (segment (overlook-row-segments row))
        (pcase segment
          (`(:pad ,text . ,_)
           (push (list :pad (vconcat (overlook-remote--runs row text))
                       :labels (vconcat (mapcar (lambda (label)
                                                  (vconcat (overlook-remote--runs row label)))
                                                (plist-get segment :like))))
                 spans))
          (`(:right ,text . ,_)
           (unless (string-blank-p text)
             (push (list :right (vconcat (overlook-remote--runs row text))) spans)))
          (`(:fit ,text . ,_)
           (add (or (plist-get segment :before) ""))
           (push (list :fit (vconcat (overlook-remote--runs
                                      row (propertize text 'face (plist-get segment :face)))))
                 spans))
          (`(:wrap ,pieces . ,_)
           (push (list :wrap (vconcat (mapcar (lambda (piece)
                                                (vconcat (overlook-remote--runs row piece)))
                                              pieces))
                       :gap (or (plist-get segment :gap) 1))
                 spans))
          (_ (add (overlook-segment-text segment))))))
    (vconcat (nreverse spans))))

(defvar overlook-remote--rows nil
  "Table of the rows of the dashboard last made, by their node's id.")

(defun overlook-remote--commands (commands)
  "COMMANDS of a row, as the page shows them."
  (vconcat (mapcar (lambda (command)
                     `(:name ,(plist-get command :name)
                       :label ,(overlook-remote--text (plist-get command :label))
                       ,@(and (plist-get command :input)
                              `(:input ,(overlook-remote--text (plist-get command :input))))
                       ,@(and (plist-get command :options)
                              `(:options ,(vconcat (plist-get command :options))))
                       ,@(and (plist-get command :confirm) '(:confirm t))))
                   commands)))

(defun overlook-remote--node (row parent)
  "ROW of the dashboard's model as the page shows it, under the node of id PARENT.
An agent's row names it in :agent and gives the answers it offers in
:choices; :commands are the row's, run through /api/command by the
node's id, and :diff tells that /api/diff gives its diff.  :hash
changes whenever the node or any under it does."
  (let* ((value (overlook-row-key row))
         (id (substring (secure-hash 'sha1 (concat parent
                                                   (let ((print-length nil) (print-level nil))
                                                     (prin1-to-string value))))
                        0 16))
         (agent (pcase (overlook-row-id row) (`(agent . ,buffer) buffer)))
         (children (vconcat (mapcar (lambda (child) (overlook-remote--node child id))
                                    (overlook-row-rows row))))
         (node `(:id ,id
                 :spans ,(overlook-remote--spans row)
                 ,@(and (overlook-row-heading row) '(:heading t))
                 ,@(and (overlook-row-attention row) '(:attention t))
                 ,@(and (overlook-row-folded row) '(:folded t))
                 ,@(and (overlook-agent-p agent)
                        `(:agent ,(buffer-name agent)
                          :choices ,(overlook-remote--choices (overlook-row-choices row))))
                 ,@(and (overlook-row-commands row)
                        `(:commands ,(overlook-remote--commands (overlook-row-commands row))))
                 ,@(and (overlook-row-diff row) '(:diff t)))))
    (when overlook-remote--rows (puthash id row overlook-remote--rows))
    `(:hash ,(substring (secure-hash
                         'sha1 (json-serialize
                                (append node `(:children ,(vconcat
                                                          (mapcar (lambda (child)
                                                                    (plist-get child :hash))
                                                                  children))))))
                        0 16)
      ,@node
      :children ,children)))

(defvar overlook-remote--dashboard nil
  "The model the page's dashboard was last made of, and that dashboard.
As (MODEL SECTIONS . HASH).")

(defvar overlook-remote--versions nil
  "The latest dashboards the page may know, newest first, each (HASH . NODES).
NODES is a table of the hashes of their nodes.")

(defvar overlook-remote--model nil
  "A cell holding the model the calls answered together share, or nil.")

(defmacro overlook-remote--together (&rest body)
  "Run BODY, the calls it answers sharing one model."
  (declare (indent 0))
  `(let ((overlook-remote--model (list nil))) ,@body))

(defun overlook-remote--model ()
  "The dashboard's model: the live dashboard's while fresh, else a new one.
Calls answered in one `overlook-remote--together' share a new one."
  (if (overlook-live-p)
      (overlook-latest-model)
    (if overlook-remote--model
        (with-memoization (car overlook-remote--model) (overlook-model))
      (overlook-model))))

(defun overlook-remote--dashboard ()
  "The dashboard as the page shows it, and a hash telling when that changes.
Made once per model `overlook-remote--model' gives."
  (let ((model (overlook-remote--model)))
    (unless (eq model (car overlook-remote--dashboard))
      (setq overlook-remote--rows (make-hash-table :test #'equal))
      (let* ((sections (vconcat (mapcar (lambda (row) (overlook-remote--node row ""))
                                        model)))
             (hash (secure-hash 'sha1 (mapconcat (lambda (node) (plist-get node :hash))
                                                 sections "")))
             (nodes (make-hash-table :test #'equal)))
        (setq overlook-remote--dashboard (cons model (cons sections hash)))
        (unless (assoc hash overlook-remote--versions)
          (named-let walk ((children sections))
            (seq-doseq (node children)
              (puthash (plist-get node :hash) t nodes)
              (walk (plist-get node :children))))
          (setq overlook-remote--versions
                (seq-take (cons (cons hash nodes) overlook-remote--versions) 8)))))
    (cdr overlook-remote--dashboard)))

(defun overlook-remote--delta (nodes known)
  "NODES with each one the table KNOWN holds the hash of sent as (:same HASH)."
  (vconcat (seq-map (lambda (node)
                      (if (gethash (plist-get node :hash) known)
                          `(:same ,(plist-get node :hash))
                        (plist-put (copy-sequence node) :children
                                   (overlook-remote--delta (plist-get node :children) known))))
                    nodes)))

(defun overlook-remote--dashboard-news (known)
  "The dashboard for a page knowing state KNOWN, with only what it lacks.
What it knows goes as (:same HASH), when KNOWN is among the latest."
  (pcase-let ((`(,sections . ,hash) (overlook-remote--dashboard))
              (nodes (cdr (assoc known overlook-remote--versions))))
    `(:sections ,(if nodes (overlook-remote--delta sections nodes) sections) :known ,hash)))

(defun overlook-remote--choices (choices)
  "CHOICES an agent offers, as the page shows them."
  (vconcat (mapcar (pcase-lambda (`(,key ,label . ,_))
                     `(:key ,key :label ,(overlook-remote--text label)))
                   choices)))

(provide 'overlook-remote-model)
;;; overlook-remote-model.el ends here
