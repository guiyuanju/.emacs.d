;;; iuiw-jira.el --- Jira tickets of workspace projects through acli -*- lexical-binding: t; -*-

;;; Commentary:
;; project.md 的 front matter 用 jira: [KEY-1, KEY-2] 列出项目的 ticket，只追加不删。
;; `iuiw-jira-add-ticket' 追加到当前项目并 commit，`iuiw-jira-browse' 用浏览器打开其中一个。

;;; Code:

(require 'subr-x)
(require 'iuiw-workspace)

(declare-function overlook-refresh "overlook")

(defgroup iuiw-jira nil
  "Jira tickets of workspace projects."
  :group 'tools
  :prefix "iuiw-jira-")

(defcustom iuiw-jira-site nil
  "Base URL of the Jira site, such as \"https://example.atlassian.net\"."
  :type '(choice (const nil) string))

(defcustom iuiw-jira-forbidden-workspaces '("me")
  "Workspaces whose project.md must not list tickets."
  :type '(repeat string))

(defconst iuiw-jira--key-regexp "\\`[A-Z][A-Z0-9_]*-[0-9]+\\'")

;;; Commands

(defun iuiw-jira--current-card ()
  "The card of the current project."
  (or (iuiw-workspace--card (file-name-nondirectory
                             (directory-file-name (iuiw-workspace--current-card-root))))
      (user-error "No project.md for this project")))

;;;###autoload
(defun iuiw-jira-browse (key)
  "Open ticket KEY in a browser; interactively, one of the current project's."
  (interactive
   (let ((keys (or (plist-get (iuiw-jira--current-card) :jira)
                   (user-error "This project.md lists no jira tickets"))))
     (list (if (cdr keys) (completing-read "Ticket: " keys nil t) (car keys)))))
  (unless iuiw-jira-site (user-error "Set `iuiw-jira-site' first"))
  (browse-url (concat (string-remove-suffix "/" iuiw-jira-site) "/browse/" key)))

(defun iuiw-jira--write-keys (file keys)
  "Save KEYS as the jira: field of card FILE, leaving the rest untouched."
  (with-current-buffer (find-file-noselect file)
    (when (or (buffer-modified-p) (not (verify-visited-file-modtime (current-buffer))))
      (user-error "Save or revert project.md first"))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (unless (looking-at "---[ \t]*\n") (user-error "project.md needs YAML front matter"))
        (forward-line 1)
        (let ((end (save-excursion
                     (unless (re-search-forward "^---[ \t]*$" nil t)
                       (user-error "Unclosed project.md front matter"))
                     (line-beginning-position))))
          (if (re-search-forward "^jira:.*\n" end t)
              (delete-region (match-beginning 0) (match-end 0))
            (goto-char end)))
        (insert (format "jira: [%s]\n" (string-join keys ", ")))
        (save-buffer)))))

;;;###autoload
(defun iuiw-jira-add-ticket (key)
  "Append ticket KEY to the current project's jira: list and commit project.md.
It is not committed when project.md already had other uncommitted changes."
  (interactive (list (upcase (string-trim (read-string "Jira ticket: ")))))
  (unless (string-match-p iuiw-jira--key-regexp key) (user-error "Not a ticket key: %s" key))
  (let* ((card (iuiw-jira--current-card))
         (file (plist-get card :file))
         (default-directory (file-name-directory file)))
    (when (member (plist-get card :workspace) iuiw-jira-forbidden-workspaces)
      (user-error "Tickets are not written to the %s workspace" (plist-get card :workspace)))
    (when (member key (plist-get card :jira)) (user-error "%s is already listed" key))
    (let ((clean (zerop (call-process "git" nil nil nil "diff" "--quiet" "HEAD" "--" "project.md"))))
      (iuiw-jira--write-keys file (append (plist-get card :jira) (list key)))
      (let ((committed (and clean
                            (zerop (call-process "git" nil nil nil "commit" "-q" "-m"
                                                 (format "%s: jira 加 %s" (plist-get card :id) key)
                                                 "--" "project.md")))))
        (when (fboundp 'overlook-refresh) (overlook-refresh))
        (message "%s added%s" key
                 (if committed "" "  (project.md not committed)"))))))

(provide 'iuiw-jira)
;;; iuiw-jira.el ends here
