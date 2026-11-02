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

;; While `courier-ci-mode' is on, the CI of each branch an agent works on
;; in a worktree is watched, and each run that finishes is published in
;; the room named after the branch, which that agent follows.  Only
;; branches pushed to a remote are asked about, and only every
;; `courier-ci-interval' seconds, in the background.  A run that had
;; finished before the branch was first looked at is not announced.
;; `courier-ci-backends' says how to ask each host: GitHub through gh,
;; GitLab through glab.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'courier)
(require 'courier-room)
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

(defvar courier-ci--seen (make-hash-table :test #'equal)
  "Latest run seen per checkout and branch, or `none' when it had none.")

(defvar courier-ci--reading nil
  "Checkouts being looked at.")

(defvar courier-ci--timer nil)

(defun courier-ci--run (dir command then)
  "Run COMMAND in DIR, calling THEN with its output, or nil when it fails."
  (let ((output (generate-new-buffer " *courier-ci*"))
        (errors (generate-new-buffer " *courier-ci-errors*"))
        (default-directory (file-name-as-directory dir)))
    (condition-case nil
        (make-process
         :name "courier-ci" :buffer output :stderr errors :noquery t :connection-type 'pipe
         :command command
         :sentinel (lambda (process _event)
                     (unless (process-live-p process)
                       (let ((text (and (eq (process-exit-status process) 0)
                                        (with-current-buffer output (buffer-string)))))
                         (kill-buffer output)
                         (kill-buffer errors)
                         (funcall then text)))))
      (file-missing (kill-buffer output) (kill-buffer errors) (funcall then nil)))))

(defun courier-ci--json (text)
  "TEXT parsed as JSON, or nil."
  (and text (ignore-errors (json-parse-string text :object-type 'plist :array-type 'list))))

(defun courier-ci-github (dir branch then)
  "Call THEN with the latest GitHub Actions run of BRANCH, from checkout DIR."
  (courier-ci--run
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
  (courier-ci--run
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
  "Note RUN, the latest on BRANCH of CHECKOUT, publishing it if it newly finished.
Returns non-nil when it was published."
  (let* ((key (concat checkout "\0" branch))
         (before (gethash key courier-ci--seen)))
    (puthash key (or run 'none) courier-ci--seen)
    (when (and before run (plist-get run :done)
               (not (and (consp before)
                         (equal (plist-get before :id) (plist-get run :id))
                         (plist-get before :done))))
      (courier-room-publish (courier-room-name-for branch) "ci"
                            (courier-ci--message checkout branch run))
      t)))

(defun courier-ci--look (checkout)
  "Look at the CI of the branch checked out in CHECKOUT, if it is pushed."
  (unless (member checkout courier-ci--reading)
    (push checkout courier-ci--reading)
    (let ((done (lambda () (setq courier-ci--reading (delete checkout courier-ci--reading)))))
      (courier-ci--run
       checkout (list (or (bound-and-true-p vc-git-program) "git")
                      "rev-parse" "--abbrev-ref" "HEAD" "@{upstream}")
       (lambda (text)
         (pcase (and text (split-string text "\n" t))
           ((and `(,branch ,upstream)
                 (guard (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" upstream)))
            (let ((remote (match-string 1 upstream))
                  (remote-branch (match-string 2 upstream)))
              (courier-ci--run
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
  "Publish the CI results of the branches agents work on in their rooms."
  :global t
  :group 'courier
  (when (timerp courier-ci--timer) (cancel-timer courier-ci--timer))
  (setq courier-ci--timer
        (and courier-ci-mode (run-with-timer courier-ci-interval courier-ci-interval
                                             #'courier-ci-look))))

(provide 'courier-ci)
;;; courier-ci.el ends here
