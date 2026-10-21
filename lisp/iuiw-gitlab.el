;;; iuiw-gitlab.el --- GitLab merge requests through glab -*- lexical-binding: t; -*-

;;; Commentary:
;; 在浏览器里打开当前分支的 GitLab merge request。

;;; Code:

(require 'seq)

(defun iuiw-gitlab--json (&rest args)
  "Return the parsed JSON output of glab ARGS."
  (with-temp-buffer
    (unless (zerop (apply #'call-process "glab" nil '(t nil) nil args))
      (user-error "glab %s failed" (car args)))
    (goto-char (point-min))
    (json-parse-buffer :object-type 'alist :array-type 'list)))

(defun iuiw-browse-mr ()
  "Open the GitLab merge request for the current branch in a browser.
An open request wins over merged or closed ones; with none, offer the
new merge request page."
  (interactive)
  (unless (executable-find "glab") (user-error "glab not found"))
  (let* ((branch (car (ignore-errors
                        (process-lines "git" "branch" "--show-current"))))
         (_ (unless branch (user-error "Not on a Git branch")))
         (mrs (iuiw-gitlab--json "mr" "list" "--source-branch" branch
                                      "--all" "-F" "json"))
         (mr (or (seq-find (lambda (mr) (equal (alist-get 'state mr) "opened"))
                           mrs)
                 (car mrs))))
    (cond
     (mr
      (browse-url (alist-get 'web_url mr))
      (message "!%s [%s] %s" (alist-get 'iid mr) (alist-get 'state mr)
               (alist-get 'title mr)))
     ((y-or-n-p (format "No merge request for %s; create one? " branch))
      (browse-url
       (format "%s/-/merge_requests/new?merge_request%%5Bsource_branch%%5D=%s"
               (alist-get 'web_url (iuiw-gitlab--json "repo" "view"
                                                           "-F" "json"))
               (url-hexify-string branch)))))))

(provide 'iuiw-gitlab)
;;; iuiw-gitlab.el ends here
