;;; jgy-project.el --- Project folders opened as tab workspaces -*- lexical-binding: t; -*-

;;; Commentary:
;; 一个项目一个 git 仓库（含 project.md，代码仓库作为 submodule），一个同名 tab。

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'tab-bar)

(declare-function magit-call-git "magit-process")
(declare-function magit-submodule-add-1 "magit-submodule")
(defvar magit-this-process)

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
  "Create the repository and project.md for ID with TITLE."
  (let* ((default-directory (file-name-as-directory
                             (expand-file-name id jgy/project-directory)))
         (file (expand-file-name "project.md")))
    (make-directory default-directory t)
    (with-temp-file file
      (insert (format "---\nid: %s\ntitle: %s\nstatus: active\nstart: %s\nend:\n---\n\n"
                      id title (format-time-string "%F"))
              "## 目标\n\n## Todo\n\n## 资源\n\n## 成果\n\n## 日志\n"))
    (with-temp-file ".gitignore" (insert ".DS_Store\n"))
    (dolist (args `(("init" "-q" "-b" "main")
                    ("add" "project.md" ".gitignore")
                    ("commit" "-q" "-m" ,(concat "Init " id))))
      (unless (zerop (apply #'call-process "git" nil nil nil args))
        (user-error "git %s failed in %s" (car args) default-directory)))
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

(defun jgy/project-visit-file ()
  "Open the project.md of the current project folder."
  (interactive)
  (find-file (expand-file-name "project.md" (or (jgy/project-root)
                                                (user-error "Not inside a project folder")))))

(defun jgy/project-clone (repo)
  "Add REPO's origin as a submodule of the current project.
REPO is a checkout under `jgy/code-directory'."
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
         (default-directory root)
         (url (car (process-lines "git" "-C" (expand-file-name repo jgy/code-directory)
                                  "remote" "get-url" "origin"))))
    (when (file-exists-p repo) (user-error "%s already exists" (expand-file-name repo)))
    (require 'magit-submodule)
    (magit-submodule-add-1 url repo repo)
    ;; 代码仓库里的提交不让项目仓库显示为改动。
    (add-function :after (process-sentinel magit-this-process)
                  (lambda (process _event)
                    (when (and (eq (process-status process) 'exit)
                               (zerop (process-exit-status process)))
                      (let ((default-directory root))
                        (magit-call-git "config" "-f" ".gitmodules"
                                        (format "submodule.%s.ignore" repo) "all")))))))

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
