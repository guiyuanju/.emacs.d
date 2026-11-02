;;; courier-ci.el --- CI results as events for the agents on a branch -*- lexical-binding: t; -*-

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

;; A source of courier events: while `courier-ci-mode' is on, the CI of
;; each branch an agent works on in a worktree is watched, and each run
;; that finishes is an event in the thread of the branch, whose room that
;; agent follows.  Only branches pushed to a remote are asked about, and
;; only every `courier-ci-interval' seconds, in the background.  A run that
;; had finished before the branch was first looked at is not announced.
;; `courier-ci-backends' says how to ask each host: GitHub through gh,
;; GitLab through glab.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'courier-event)
(require 'courier-worktree)

(defcustom courier-ci-interval 60
  "Seconds between looks at the CI of the branches agents work on."
  :type 'number
  :group 'courier)

(defcustom courier-ci-backends
  '(("github\\.com" . courier-ci-github)
    ("gitlab" . courier-ci-gitlab))
  "Alist of a regexp matching a remote's URL to the function asking its CI.
The function takes the checkout, the branch on the remote and a function
to call with the branch's latest run, or nil when it has none: a plist
of :id, :done (non-nil once finished), :result, :name, :url, :sha and
:hint, a command reading more of it."
  :type '(alist :key-type regexp :value-type function)
  :group 'courier)

(defvar courier-ci--reading nil
  "Checkouts being looked at.")

(defun courier-ci--json (text)
  "TEXT parsed as JSON, or nil."
  (and text (ignore-errors (json-parse-string text :object-type 'plist :array-type 'list))))

(defun courier-ci-github (dir branch then)
  "Call THEN with the latest GitHub Actions run of BRANCH, from checkout DIR."
  (courier-event-run
   dir (list "gh" "run" "list" "--branch" branch "--limit" "1" "--json"
             "databaseId,status,conclusion,workflowName,url,headSha")
   (lambda (text)
     (funcall then
              (when-let* ((run (car (courier-ci--json text))))
                (list :id (plist-get run :databaseId)
                      :done (equal (plist-get run :status) "completed")
                      :result (plist-get run :conclusion)
                      :name (plist-get run :workflowName)
                      :url (plist-get run :url)
                      :sha (plist-get run :headSha)
                      :hint (format "gh run view %s --log-failed" (plist-get run :databaseId))))))))

(defun courier-ci-gitlab (dir branch then)
  "Call THEN with the latest GitLab pipeline of BRANCH, from checkout DIR."
  (courier-event-run
   dir (list "glab" "ci" "list" "--ref" branch "--per-page" "1" "--output" "json")
   (lambda (text)
     (funcall then
              (when-let* ((run (car (courier-ci--json text))))
                (list :id (plist-get run :id)
                      :done (member (plist-get run :status)
                                    '("success" "failed" "canceled" "skipped"))
                      :result (plist-get run :status)
                      :name "pipeline"
                      :url (plist-get run :web_url)
                      :sha (plist-get run :sha)
                      :hint (format "glab ci view --branch %s" branch)))))))

(defun courier-ci--checkouts ()
  "The Git checkouts in the worktrees registered agents work in."
  (let ((pattern (concat "\\`\\(.*/" (regexp-quote courier-worktree-directory) "/[^/]+/\\)"))
        folders)
    (dolist (agent (courier-agents))
      (when-let* ((buffer (courier-agent-buffer agent))
                  ((buffer-live-p buffer))
                  (dir (expand-file-name (buffer-local-value 'default-directory buffer)))
                  ((string-match pattern dir)))
        (cl-pushnew (match-string 1 dir) folders :test #'equal)))
    (mapcan #'courier-worktree-repos (nreverse folders))))

(defun courier-ci--message (checkout branch run)
  "What is published of RUN, finished on BRANCH of CHECKOUT."
  (let ((failed (not (member (plist-get run :result) '("success" "skipped"))))
        (sha (or (plist-get run :sha) "unknown")))
    (format "CI %s %s on branch %s of %s (%s): %s%s"
            (plist-get run :name) (plist-get run :result) branch
            (file-name-nondirectory (directory-file-name checkout))
            (substring sha 0 (min 7 (length sha)))
            (plist-get run :url)
            (if failed (format "\nRead why with `%s` in %s." (plist-get run :hint)
                               (abbreviate-file-name checkout))
              ""))))

(defun courier-ci-saw (checkout branch run)
  "Note RUN, the latest on BRANCH of CHECKOUT, emitting it if it newly finished.
Returns its entry in `courier-event-log' when it was emitted."
  (let ((first (courier-event-first-look-p "ci" (concat checkout "\0" branch)))
        (key (and run (plist-get run :done) (format "%s %s" checkout (plist-get run :id)))))
    (cond ((null key) nil)
          (first (courier-event-remember "ci" key) nil)
          (t (let ((entry (courier-event-emit
                           (list :source "ci" :thread branch :key key
                                 :text (courier-ci--message checkout branch run)))))
               (and (not (eq (plist-get entry :outcome) 'duplicate)) entry))))))

(defun courier-ci--look (checkout)
  "Look at the CI of the branch checked out in CHECKOUT, if it is pushed."
  (unless (member checkout courier-ci--reading)
    (push checkout courier-ci--reading)
    (let ((done (lambda () (setq courier-ci--reading (delete checkout courier-ci--reading)))))
      (courier-event-run
       checkout (list (or (bound-and-true-p vc-git-program) "git")
                      "rev-parse" "--abbrev-ref" "HEAD" "@{upstream}")
       (lambda (text)
         (pcase (and text (split-string text "\n" t))
           ((and `(,branch ,upstream)
                 (guard (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" upstream)))
            (let ((remote (match-string 1 upstream))
                  (remote-branch (match-string 2 upstream)))
              (courier-event-run
               checkout (list (or (bound-and-true-p vc-git-program) "git") "remote" "get-url" remote)
               (lambda (url)
                 (if-let* ((url)
                           (backend (cdr (seq-find (lambda (entry) (string-match-p (car entry) url))
                                                   courier-ci-backends))))
                     (funcall backend checkout remote-branch
                              (lambda (run)
                                (funcall done)
                                (courier-ci-saw checkout branch run)))
                   (funcall done))))))
           (_ (funcall done))))))))

(defun courier-ci-look ()
  "Look at the CI of every branch an agent works on in a worktree."
  (interactive)
  (mapc #'courier-ci--look (courier-ci--checkouts)))

;;;###autoload
(define-minor-mode courier-ci-mode
  "Emit the CI results of the branches agents work on as courier events."
  :global t
  :group 'courier
  (if courier-ci-mode
      (courier-event-add-source 'ci :interval courier-ci-interval :poll #'courier-ci-look)
    (courier-event-remove-source 'ci)))

(provide 'courier-ci)
;;; courier-ci.el ends here
