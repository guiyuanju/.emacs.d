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

(require 'overlook-data)
(require 'overlook-remote-contract)

(declare-function overlook-remote--unread-count "overlook-remote-activity" (buffer))

(defun overlook-remote--text (text)
  "TEXT without properties, or an empty string for nil."
  (if text (substring-no-properties text) ""))

(defun overlook-remote--legacy-row-data (row)
  "Plain text compatibility data for extension ROW without a data provider."
  (let (title subtitle)
    (dolist (segment (overlook-row-segments row))
      (pcase segment
        (`(:fit ,text . ,_) (push (overlook-remote--text text) subtitle))
        (`(:cell . ,_) nil)
        (_ (push (overlook-remote--text (overlook-segment-text segment)) title))))
    (list :kind (if (overlook-row-heading row) "group" "text")
          :title (string-trim (apply #'concat (nreverse title)))
          :subtitle (string-join (nreverse subtitle) " "))))

(defun overlook-remote--row-data (row)
  "Business data behind ROW, or explicitly adapted legacy extension text."
  (or (overlook-data (overlook-row-id row))
      (run-hook-with-args-until-success 'overlook-row-data-functions row)
      (overlook-remote--legacy-row-data row)))

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
  (let* ((data (overlook-remote--row-data row))
         (value (or (plist-get data :resourceId) (overlook-row-key row)))
         (id (substring (secure-hash 'sha1 (concat parent
                                                   (let ((print-length nil) (print-level nil))
                                                     (prin1-to-string value))))
                        0 16))
         (agent (pcase (overlook-row-id row) (`(agent . ,buffer) buffer)))
         (children (vconcat (mapcar (lambda (child) (overlook-remote--node child id))
                                    (overlook-row-rows row))))
         (node `(:id ,id
                 ,@(overlook-remote-contract-node data)
                 ,@(and (overlook-row-heading row) '(:heading t))
                 ,@(and (overlook-row-attention row) '(:attention t))
                 ,@(and (overlook-agent-p agent)
                        `(:agent ,(overlook-data-agent-id agent)
                          :unreadCount ,(if (fboundp 'overlook-remote--unread-count)
                                            (overlook-remote--unread-count agent) 0)
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
