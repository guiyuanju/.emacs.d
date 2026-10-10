;;; jgy-project.el --- Project folders opened as perspective workspaces -*- lexical-binding: t; -*-

;;; Commentary:
;; 一个项目一个文件夹（含 project.md 和 clone 进来的代码仓库），一个同名 perspective。
;; 项目放在各 workspace 的 projects/ 下，如 ~/workspace/okj/projects/<id>/。

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)

(declare-function magit-clone-regular "magit-clone")
(declare-function persp-names "perspective")
(declare-function persp-switch "perspective")

(defvar jgy-code-directory "~/Code/"
  "Directory whose <group>/<repo> Git checkouts are clone sources.")
(defvar jgy-workspace-directory "~/workspace/"
  "Directory containing workspaces, each with a projects/ folder.")

(defun jgy-project-root (&optional directory)
  "Return the project folder containing DIRECTORY, or nil.
Symlinks are resolved first, so ~/.emacs.d finds the project it links into."
  (when-let* ((root (locate-dominating-file
                     (file-truename (or directory default-directory)) "project.md")))
    (and (file-in-directory-p root jgy-workspace-directory)
         (file-name-as-directory (expand-file-name root)))))

(defun jgy-project-files (&optional directory)
  "Return every project card under DIRECTORY, defaulting to the workspaces."
  (file-expand-wildcards
   (expand-file-name "*/projects/*/project.md"
                     (or directory jgy-workspace-directory))))

(defun jgy-project--folders ()
  "Return the project folders of every workspace, newest first."
  (sort (jgy-project-files) #'file-newer-than-file-p))

(defun jgy-project--read-workspace ()
  "Read a workspace name and return its projects folder."
  (let* ((names (mapcar (lambda (dir) (file-name-nondirectory (directory-file-name
                                                                (file-name-directory dir))))
                        (file-expand-wildcards
                         (expand-file-name "*/projects/" jgy-workspace-directory))))
         (name (if (cdr names)
                   (completing-read "Workspace: " names nil t)
                 (or (car names) (user-error "No workspace under %s" jgy-workspace-directory)))))
    (expand-file-name (concat name "/projects/") jgy-workspace-directory)))

(defun jgy-project--create (file id title)
  "Create project.md FILE for ID with TITLE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert (format "---\nid: %s\ntitle: %s\nstatus: active\nstart: %s\nend:\n---\n\n"
                    id title (format-time-string "%F"))
            "## 目标\n\n## Todo\n\n## 资源\n\n## 成果\n\n## 日志\n")))

(defun jgy-project-open (id)
  "Switch to the workspace of project ID, creating the project when it is new.
A new workspace opens project.md; an existing one keeps its windows."
  (interactive (list (string-trim
                      (completing-read "Project: "
                                       (mapcar (lambda (file) (file-name-nondirectory
                                                               (directory-file-name
                                                                (file-name-directory file))))
                                               (jgy-project--folders))))))
  (when (string-empty-p id) (user-error "Project id cannot be empty"))
  (let ((file (or (seq-find (lambda (file) (string-suffix-p (concat "/" id "/project.md") file))
                            (jgy-project--folders))
                  (expand-file-name (concat id "/project.md") (jgy-project--read-workspace)))))
    (unless (file-exists-p file)
      (jgy-project--create file id (read-string "Title: ")))
    (let ((new (not (member id (persp-names)))))
      (persp-switch id)
      (when new (find-file file)))))

(defun jgy-project-visit-file ()
  "Open the project.md of the current project folder."
  (interactive)
  (find-file (expand-file-name "project.md" (or (jgy-project-root)
                                                (user-error "Not inside a project folder")))))

(defun jgy-project-clone (repo)
  "Clone the origin of REPO, a <group>/<repo> checkout under `jgy-code-directory'."
  (interactive
   (list (completing-read
          "Repository: "
          (mapcar (lambda (git) (file-relative-name (directory-file-name (file-name-directory git))
                                                    (expand-file-name jgy-code-directory)))
                  (file-expand-wildcards (expand-file-name "*/*/.git" jgy-code-directory)))
          nil t)))
  (let* ((root (or (jgy-project-root) (user-error "Not inside a project folder")))
         (target (expand-file-name (file-name-nondirectory (directory-file-name repo)) root))
         (url (car (process-lines "git" "-C" (expand-file-name repo jgy-code-directory)
                                  "remote" "get-url" "origin"))))
    (when (file-exists-p target) (user-error "%s already exists" target))
    (require 'magit-clone)
    (magit-clone-regular url target nil)))

;; 项目文件夹整个算一个 project，含所有 clone；文件由 fd 列出，遵守各 clone 的 .gitignore。
(defun jgy-project-try (directory)
  "Return the project folder containing DIRECTORY as a project."
  (when-let* ((root (jgy-project-root directory)))
    (cons 'jgy root)))

(cl-defmethod project-root ((project (head jgy)))
  (cdr project))

(cl-defmethod project-files ((project (head jgy)) &optional dirs)
  (mapcan (lambda (dir)
            (let ((default-directory (file-name-as-directory (expand-file-name dir))))
              (mapcar #'expand-file-name
                      (process-lines "fd" "--type" "f" "--hidden" "--exclude" ".git"))))
          (or dirs (list (project-root project)))))

(defun jgy-project--glab-json (&rest args)
  "Return the parsed JSON output of glab ARGS."
  (with-temp-buffer
    (unless (zerop (apply #'call-process "glab" nil '(t nil) nil args))
      (user-error "glab %s failed" (car args)))
    (goto-char (point-min))
    (json-parse-buffer :object-type 'alist :array-type 'list)))

(defun jgy-browse-mr ()
  "Open the GitLab merge request for the current branch in a browser.
An open request wins over merged or closed ones; with none, offer the
new merge request page."
  (interactive)
  (unless (executable-find "glab") (user-error "glab not found"))
  (let* ((branch (car (ignore-errors
                        (process-lines "git" "branch" "--show-current"))))
         (_ (unless branch (user-error "Not on a Git branch")))
         (mrs (jgy-project--glab-json "mr" "list" "--source-branch" branch
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
               (alist-get 'web_url (jgy-project--glab-json "repo" "view"
                                                           "-F" "json"))
               (url-hexify-string branch)))))))

(provide 'jgy-project)
;;; jgy-project.el ends here
