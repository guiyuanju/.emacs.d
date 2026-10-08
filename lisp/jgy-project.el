;;; jgy-project.el --- Project folders opened as tab workspaces -*- lexical-binding: t; -*-

;;; Commentary:
;; 一个项目一个文件夹（含 project.md 和 clone 进来的仓库），一个同名 tab。

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'tab-bar)

(declare-function magit-clone-regular "magit-clone")

(defvar jgy/code-directory "~/Code/okj/"
  "Directory containing the main Git checkouts, used as clone sources.")
(defvar jgy/project-directory "~/workspace/okj/projects/"
  "Directory containing one folder per project.")

(defun jgy/project-root (&optional directory)
  "Return the project folder containing DIRECTORY, or nil."
  (when-let* ((root (locate-dominating-file (or directory default-directory)
                                            "project.md")))
    (and (file-in-directory-p root jgy/project-directory)
         (file-name-as-directory (expand-file-name root)))))

(defun jgy/project--names ()
  "Return the project folder names, newest first."
  (let ((default-directory (expand-file-name jgy/project-directory)))
    (sort (seq-filter (lambda (name) (file-exists-p (expand-file-name "project.md" name)))
                      (directory-files "." nil directory-files-no-dot-files-regexp))
          (lambda (a b) (file-newer-than-file-p (expand-file-name "project.md" a)
                                                (expand-file-name "project.md" b))))))

(defun jgy/project--create (id title)
  "Create the folder and project.md for ID with TITLE."
  (let ((file (expand-file-name (concat id "/project.md") jgy/project-directory)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (format "---\nid: %s\ntitle: %s\nstatus: active\nstart: %s\nend:\n---\n\n"
                      id title (format-time-string "%F"))
              "## 目标\n\n## Todo\n\n## 资源\n\n## 成果\n\n## 日志\n"))
    file))

(defun jgy/project-open (id)
  "Switch to the tab of project ID, creating the project when it is new."
  (interactive (list (string-trim (completing-read "Project: " (jgy/project--names)))))
  (when (string-empty-p id) (user-error "Project id cannot be empty"))
  (let ((file (expand-file-name (concat id "/project.md") jgy/project-directory)))
    (unless (file-exists-p file)
      (jgy/project--create id (read-string "Title: ")))
    (tab-bar-switch-to-tab id)
    (find-file file)))

(defun jgy/project-clone (repo)
  "Clone REPO from `jgy/code-directory''s origin into the current project."
  (interactive
   (list (completing-read
          "Repository: "
          (seq-filter (lambda (name)
                        (file-exists-p (expand-file-name (concat name "/.git")
                                                         jgy/code-directory)))
                      (directory-files jgy/code-directory nil
                                       directory-files-no-dot-files-regexp))
          nil t)))
  (let* ((root (or (jgy/project-root) (user-error "Not inside a project folder")))
         (target (expand-file-name repo root))
         (url (car (process-lines "git" "-C" (expand-file-name repo jgy/code-directory)
                                  "remote" "get-url" "origin"))))
    (when (file-exists-p target) (user-error "%s already exists" target))
    (require 'magit-clone)
    (magit-clone-regular url target nil)))

(defun jgy/project--glab-json (&rest args)
  "Return the parsed JSON output of glab ARGS."
  (with-temp-buffer
    (unless (zerop (apply #'call-process "glab" nil '(t nil) nil args))
      (user-error "glab %s failed" (car args)))
    (goto-char (point-min))
    (json-parse-buffer :object-type 'alist :array-type 'list)))

(defun jgy/browse-mr ()
  "Open the GitLab merge request for the current branch in a browser.
An open request wins over merged or closed ones; with none, offer the
new merge request page."
  (interactive)
  (unless (executable-find "glab") (user-error "glab not found"))
  (let* ((branch (car (ignore-errors
                        (process-lines "git" "branch" "--show-current"))))
         (_ (unless branch (user-error "Not on a Git branch")))
         (mrs (jgy/project--glab-json "mr" "list" "--source-branch" branch
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
               (alist-get 'web_url (jgy/project--glab-json "repo" "view"
                                                           "-F" "json"))
               (url-hexify-string branch)))))))

(provide 'jgy-project)
;;; jgy-project.el ends here
