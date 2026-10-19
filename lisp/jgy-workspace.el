;;; jgy-workspace.el --- Workspaces, projects, perspectives and repos -*- lexical-binding: t; -*-

;;; Commentary:
;; workspace（~/workspace/me、okj…）→ 项目 projects/<id>/（project.md）→ 若干 repo（各一个 git 仓库）；
;; 每个项目对应一个同名 perspective，项目 id 即文件夹名。
;; 位置固定的 repo（如 ~/.emacs.d）不搬进项目文件夹，用 `jgy-workspace-project-roots' 指过去：
;; project.md 仍在 workspace，看板、agent 以那个目录为项目根。
;; project.md 的 front matter 可用 YAML 兼容的 JSON 数组记录仓库，例如：
;; repos: [
;;   {"path": "app", "url": "git@github.com:owner/app.git"}
;;   ]
;; clone-repo 成功后自动登记；register-repos 登记现有仓库；restore-repos 补齐缺失项。
;; clone 的候选来自 workspace 根下 .remotes 列出的远端，每行一个：
;;   github <owner>   gh 列出 owner 名下未归档的仓库
;;   gitlab <host>    glab 列出该 host 上我是 member 的仓库
;; 也给 overlook 提供项目根，并在看板底部列出所有进行中项目的待办：
;; Todo 段的未完成项（含缩进的子项），加上任意段落里带 #waiting 的未完成项。
;; status 为 later 的项目排在最后，收在一行折叠的 later 下面。

;;; Code:

(require 'cl-lib)
(require 'crm)
(require 'project)
(require 'json)
(require 'seq)
(require 'subr-x)

(declare-function magit-run-git-async "magit-process")
(declare-function magit-process-sentinel "magit-process")
(declare-function persp-current-name "perspective")
(declare-function persp-names "perspective")
(declare-function persp-switch "perspective")
(declare-function overlook-refresh "overlook")
(declare-function overlook-insert-section "overlook")
(declare-function overlook-insert-row "overlook")
(declare-function overlook-ordered-perspectives "overlook")
(declare-function overlook-current-perspective "overlook")
(declare-function overlook-main-window "overlook")
(declare-function overlook-show-elsewhere "overlook")
(declare-function overlook-agent-project-root "overlook-agent")
(declare-function overlook-end-with-blank "overlook")
(declare-function overlook-perspective-guess-root "overlook-perspective")
(defvar overlook-sections)

(defgroup jgy-workspace nil
  "Project folders under ~/workspace."
  :group 'convenience)

(defcustom jgy-workspace-directory "~/workspace/"
  "Directory containing workspaces, each with a projects/ folder."
  :type 'directory
  :group 'jgy-workspace)

(defcustom jgy-workspace-project-roots nil
  "Alist of project id to its root outside the workspaces.
The project's card stays in its workspace folder; the dashboard lists
the repos of the root, and agents started in the card folder run there."
  :type '(alist :key-type string :value-type directory)
  :group 'jgy-workspace)

(defcustom jgy-workspace-pull-repos '("~/.emacs.d/" "~/workspace/")
  "Repos pulled by `jgy-workspace-pull'."
  :type '(repeat directory)
  :group 'jgy-workspace)

;;; Cache

(defvar jgy-workspace--cache nil
  "Alist of key to (STAMP . VALUE), see `jgy-workspace--cached'.")

(defun jgy-workspace--cached (key stamp compute)
  "Value cached under KEY while it was computed at STAMP, else call COMPUTE."
  (let ((entry (alist-get key jgy-workspace--cache)))
    (if (and entry (equal (car entry) stamp))
        (cdr entry)
      (let ((value (funcall compute)))
        (setf (alist-get key jgy-workspace--cache) (cons stamp value))
        value))))

(defun jgy-workspace--mtimes (files)
  "FILES paired with their modification times, nil for missing ones."
  (mapcar (lambda (file) (cons file (file-attribute-modification-time (file-attributes file))))
          files))

;;; Projects

(defun jgy-workspace--base ()
  "`jgy-workspace-directory' with symlinks resolved, as a directory name.
Every project path is built from this, so paths compare with `equal'."
  (file-name-as-directory (file-truename jgy-workspace-directory)))

(defun jgy-workspace--root (id)
  "Root of project ID from `jgy-workspace-project-roots', or nil."
  (when-let* ((dir (cdr (assoc id jgy-workspace-project-roots))))
    (file-name-as-directory (file-truename dir))))

(defun jgy-workspace--root-id (&optional directory)
  "Id of the project whose root in `jgy-workspace-project-roots' holds DIRECTORY."
  (car (seq-find (lambda (entry)
                   (file-in-directory-p (or directory default-directory) (cdr entry)))
                 jgy-workspace-project-roots)))

(defun jgy-workspace--file-id (file)
  "Id of the project whose card is FILE: its folder name."
  (file-name-nondirectory (directory-file-name (file-name-directory file))))

(defun jgy-workspace-project-root (&optional directory)
  "Return the <workspace>/projects/<id>/ folder containing DIRECTORY, or nil.
Symlinks are resolved first, so a link into a project folder finds it."
  (let ((dir (file-name-as-directory (file-truename (or directory default-directory)))))
    (when (string-match (concat "\\`" (regexp-quote (jgy-workspace--base)) "[^/]+/projects/[^./][^/]*/")
                        dir)
      (let ((root (match-string 0 dir)))
        (and (file-exists-p (expand-file-name "project.md" root)) root)))))

(defun jgy-workspace--projects ()
  "Alist of project id to project.md across the workspaces.
Globbed again only when the workspace root or a projects/ folder changes."
  (let* ((base (jgy-workspace--base))
         (stamp (cons base (jgy-workspace--mtimes
                            (cons base (mapcar (lambda (dir) (expand-file-name "projects/" dir))
                                               (directory-files base t "\\`[^.]")))))))
    (jgy-workspace--cached
     'projects stamp
     (lambda ()
       (seq-keep (lambda (file)
                   (let ((id (jgy-workspace--file-id file)))
                     (unless (string-prefix-p "." id) (cons id file))))
                 (file-expand-wildcards (expand-file-name "*/projects/*/project.md" base)))))))

(defun jgy-workspace-project-files ()
  "Return every project card of the workspaces."
  (mapcar #'cdr (jgy-workspace--projects)))

(defun jgy-workspace-project-dir (id)
  "Folder of project ID, or nil."
  (when-let* ((file (cdr (assoc id (jgy-workspace--projects)))))
    (file-name-directory file)))

(defun jgy-workspace--projects-by-mtime ()
  "Return the project.md of every project, newest first."
  (sort (jgy-workspace-project-files) #'file-newer-than-file-p))

(defun jgy-workspace--read-workspace ()
  "Read a workspace name and return its projects folder."
  (let* ((base (jgy-workspace--base))
         (names (mapcar (lambda (dir) (file-name-nondirectory (directory-file-name
                                                                (file-name-parent-directory dir))))
                        (file-expand-wildcards (expand-file-name "*/projects/" base))))
         (name (if (cdr names)
                   (completing-read "Workspace: " names nil t)
                 (or (car names) (user-error "No workspace under %s" jgy-workspace-directory)))))
    (expand-file-name (concat name "/projects/") base)))

(defun jgy-workspace--check-new-id (id)
  "Signal a `user-error' unless ID can name a new project."
  (unless (string-match-p "\\`[a-z0-9][a-z0-9-]*\\'" id)
    (user-error "Project id must be lowercase letters, digits and hyphens: %S" id))
  (when (and (fboundp 'persp-names) (bound-and-true-p persp-mode) (member id (persp-names)))
    (user-error "Perspective %s exists and is not a project" id)))

(defun jgy-workspace--template ()
  "Contents of the project template, or a `user-error' when it is missing."
  (let ((file (expand-file-name "project-template.md" jgy-workspace-directory)))
    (unless (file-readable-p file) (user-error "No project template at %s" file))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun jgy-workspace--create-project (file id title)
  "Create project.md FILE for ID with TITLE from the project template."
  (let ((text (replace-regexp-in-string
               "{{\\(id\\|title\\|date\\)}}"
               (lambda (match)
                 (pcase match
                   ("{{id}}" id)
                   ("{{title}}" title)
                   (_ (format-time-string "%F"))))
               (jgy-workspace--template) t t)))
    (make-directory (file-name-directory file) t)
    ;; overlook-markers 据此把项目文件夹连同其中所有 clone 当作一个 project。
    (write-region "" nil (expand-file-name ".overlook" (file-name-directory file)))
    (write-region text nil file nil nil nil 'excl)))

(defun jgy-workspace--new-project (id)
  "Create project ID in a workspace read from the user; return its project.md."
  (jgy-workspace--check-new-id id)
  (when (assoc id (jgy-workspace--projects)) (user-error "Project %s exists" id))
  (jgy-workspace--template)
  (let ((file (expand-file-name (concat id "/project.md") (jgy-workspace--read-workspace))))
    (jgy-workspace--create-project file id (read-string "Title: "))
    file))

(defun jgy-workspace--switch (id file)
  "Switch to the perspective of project ID; a new one opens its project.md FILE."
  (let ((new (not (member id (persp-names)))))
    (persp-switch id)
    (when new (find-file file))))

(defun jgy-workspace-open-project (id)
  "Switch to the perspective of project ID, creating the project when it is new.
A new perspective opens project.md; an existing one keeps its windows."
  (interactive (list (string-trim
                      (completing-read "Project: " (mapcar #'jgy-workspace--file-id
                                                           (jgy-workspace--projects-by-mtime))))))
  (jgy-workspace--switch id (or (cdr (assoc id (jgy-workspace--projects)))
                                (jgy-workspace--new-project id))))

(defun jgy-workspace-new-project (id)
  "Create project ID, clone repositories into it and open it in its perspective.
The repositories are read with `completing-read-multiple'; none is fine."
  (interactive (list (string-trim (read-string "New project id: "))))
  (let* ((file (jgy-workspace--new-project id))
         (root (file-name-directory file))
         (candidates (condition-case err
                         (jgy-workspace--clone-candidates root)
                       (user-error (message "Skipping clone: %s" (error-message-string err))
                                   nil)))
         (repos (when candidates
                  (let ((completion-extra-properties
                         (jgy-workspace--candidate-properties candidates)))
                    ;; A function instead of t lets vertico select the empty prompt.
                    (completing-read-multiple
                     "Clone repositories (empty for none): " candidates nil
                     (lambda (input)
                       (seq-every-p (lambda (repo) (assoc repo candidates))
                                    (split-string input crm-separator t))))))))
    (jgy-workspace--switch id file)
    (when repos
      (jgy-workspace--clone-candidates-into root (mapcar (lambda (repo) (assoc repo candidates)) repos)))))

(defun jgy-workspace-visit-project-md ()
  "Open the project.md of the current perspective, project folder or root.
From a side window such as the dashboard it opens in the main window."
  (interactive)
  (let ((dir (jgy-workspace--current-card-root)))
    (when (fboundp 'overlook-main-window) (overlook-main-window))
    (find-file (expand-file-name "project.md" dir))))

(defun jgy-workspace--cli-output (program &rest args)
  "Stdout of PROGRAM run with ARGS from the home folder, or a `user-error'."
  (let ((default-directory (expand-file-name "~/"))
        (stderr (make-temp-file "jgy-workspace-cli")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (condition-case nil
                            (apply #'call-process program nil (list t stderr) nil args)
                          (file-missing (user-error "%s is not installed" program)))))
            (unless (eql status 0)
              (user-error "%s %s failed: %s" program (car args)
                          (string-trim (with-temp-buffer
                                         (insert-file-contents stderr)
                                         (buffer-string)))))
            (buffer-string)))
      (delete-file stderr))))

(defun jgy-workspace--parse-json-arrays (text)
  "Concatenate the JSON arrays in TEXT, as printed page by page by glab."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (items)
      (while (progn (skip-chars-forward " \t\n\r") (not (eobp)))
        (setq items (append items (json-parse-buffer :array-type 'list :object-type 'alist
                                                     :null-object nil))))
      items)))

(defun jgy-workspace--remotes (root)
  "Remotes of project folder ROOT's workspace, read from its .remotes file.
Each is a list (FORGE ARG) such as (\"github\" \"owner\")."
  (let ((file (expand-file-name "../../.remotes" root)))
    (unless (file-readable-p file)
      (user-error "No remotes configured: %s not found" (abbreviate-file-name file)))
    (with-temp-buffer
      (insert-file-contents file)
      (delq nil (mapcar (lambda (line)
                          (let ((fields (split-string (replace-regexp-in-string "#.*" "" line))))
                            (when fields
                              (unless (= (length fields) 2)
                                (user-error "Bad line in %s: %s" file line))
                              fields)))
                        (split-string (buffer-string) "\n"))))))

(defun jgy-workspace--remote-repos (forge arg)
  "Repositories of remote FORGE with ARG, as (NAME PATH URL DESCRIPTION).
The URL follows the protocol configured in the forge's CLI."
  (pcase forge
    ("github"
     (let ((ssh (equal (string-trim (jgy-workspace--cli-output "gh" "config" "get" "git_protocol"))
                       "ssh")))
       (mapcar (lambda (repo)
                 (let ((name (alist-get 'nameWithOwner repo)))
                   (list name (file-name-nondirectory name)
                         (if ssh (alist-get 'sshUrl repo) (concat (alist-get 'url repo) ".git"))
                         (alist-get 'description repo))))
               (json-parse-string
                (jgy-workspace--cli-output "gh" "repo" "list" arg "--no-archived" "--limit" "1000"
                                           "--json" "nameWithOwner,url,sshUrl,description")
                :array-type 'list :object-type 'alist :null-object nil))))
    ("gitlab"
     (let ((ssh (equal (string-trim (jgy-workspace--cli-output "glab" "config" "get" "git_protocol"
                                                               "--host" arg))
                       "ssh")))
       (mapcar (lambda (repo)
                 (list (alist-get 'path_with_namespace repo) (alist-get 'path repo)
                       (alist-get (if ssh 'ssh_url_to_repo 'http_url_to_repo) repo)
                       (alist-get 'description repo)))
               (jgy-workspace--parse-json-arrays
                (jgy-workspace--cli-output
                 "glab" "api" "--hostname" arg "--paginate"
                 "projects?membership=true&simple=true&archived=false&per_page=100")))))
    (_ (user-error "Unknown forge in .remotes: %s" forge))))

(defun jgy-workspace--clone-candidates (root)
  "Remote repos to clone into project folder ROOT, as (NAME PATH URL DESCRIPTION).
Repos whose path exists in ROOT or is registered in its project.md are left out."
  (let ((taken (mapcar (lambda (repo) (alist-get 'path repo)) (jgy-workspace--read-repos root)))
        candidates)
    (pcase-dolist (`(,forge ,arg) (jgy-workspace--remotes root))
      (dolist (repo (jgy-workspace--remote-repos forge arg))
        (unless (or (assoc (car repo) candidates)
                    (member (nth 1 repo) taken)
                    (file-exists-p (expand-file-name (nth 1 repo) root)))
          (push repo candidates))))
    (nreverse candidates)))

(defun jgy-workspace--candidate-properties (candidates)
  "`completion-extra-properties' showing the description of CANDIDATES."
  (list :annotation-function
        (lambda (name)
          (when-let* ((description (nth 3 (assoc name candidates)))
                      ((not (string-empty-p description))))
            (concat "  " (propertize description 'face 'completions-annotations))))))

(defun jgy-workspace--current-card-root ()
  "Return the current project's card directory, including mapped projects."
  (or (and (bound-and-true-p persp-mode)
           (jgy-workspace-project-dir (persp-current-name)))
      (jgy-workspace-project-root)
      (when-let* ((id (jgy-workspace--root-id)))
        (jgy-workspace-project-dir id))
      (user-error "Not inside a project folder")))

(defun jgy-workspace--repos-region ()
  "Return bounds of the repos field in the current card's front matter.
Leave point at the closing delimiter if the field is absent."
  (goto-char (point-min))
  (unless (looking-at "---[ \t]*\n")
    (user-error "project.md needs YAML front matter"))
  (forward-line 1)
  (let ((start (point))
        (end (save-excursion
               (unless (re-search-forward "^---[ \t]*$" nil t)
                 (user-error "Unclosed project.md front matter"))
               (line-beginning-position))))
    (if (re-search-forward "^repos:[ \t]*" end t)
        (let ((beg (line-beginning-position)))
          (forward-line 1)
          (while (and (< (point) end) (looking-at "[ \t]+.*$"))
            (forward-line 1))
          (cons beg (point)))
      (goto-char (max start end))
      nil)))

(defun jgy-workspace--validate-repos (repos root)
  "Validate REPOS and their paths under ROOT, returning REPOS.
Each entry has symbol keys path and url.  Paths are relative directories."
  (unless (listp repos) (user-error "repos must be a JSON array"))
  (let (seen)
    (dolist (repo repos)
      (let ((path (alist-get 'path repo)) (url (alist-get 'url repo)))
        (unless (and (stringp path) (not (string-empty-p path))
                     (not (file-name-absolute-p path))
                     (not (string-prefix-p "~" path))
                     (not (member ".." (split-string path "/")))
                     (not (member ".git" (split-string path "/")))
                     (not (equal (directory-file-name path) "."))
                     (stringp url) (not (string-empty-p url)))
          (user-error "Each repo needs a relative path and nonempty url"))
        (let ((target (directory-file-name (expand-file-name path root))))
          (unless (string-prefix-p (file-name-as-directory (file-truename root))
                                   (file-truename target))
            (user-error "Repo path escapes project: %s" path))
          (when (seq-some (lambda (other)
                           (or (equal target other)
                               (string-prefix-p (file-name-as-directory other) target)
                               (string-prefix-p (file-name-as-directory target) other))) seen)
            (user-error "Overlapping repo path: %s" path))
          (push target seen)))))
  repos)

(defun jgy-workspace--read-repos (root)
  "Read ROOT's repos array using Emacs's built-in JSON parser.
The JSON array is also valid YAML.  Other front matter is left untouched."
  (with-current-buffer (find-file-noselect (expand-file-name "project.md" root))
    (unless (verify-visited-file-modtime (current-buffer))
      (user-error "Revert project.md before reading repositories"))
    (save-excursion
      (save-restriction
        (widen)
        (let ((region (jgy-workspace--repos-region)))
          (when region
            (let* ((text (buffer-substring-no-properties (+ (car region) 6) (cdr region)))
                   (repos (condition-case nil
                              (json-parse-string text :array-type 'list :object-type 'alist
                                                 :null-object :null :false-object :false)
                            (error (user-error "repos must be a JSON array of path/url objects")))))
              (unless (string-prefix-p "[" (string-trim-left text))
                (user-error "repos must be a JSON array"))
              (jgy-workspace--validate-repos repos root))))))))

(defun jgy-workspace--write-repos (root repos)
  "Save REPOS in ROOT's card, preserving other fields and body.
Refuse to save over unsaved user edits or external file changes."
  (jgy-workspace--validate-repos repos root)
  (with-current-buffer (find-file-noselect (expand-file-name "project.md" root))
    (when (or (buffer-modified-p) (not (verify-visited-file-modtime (current-buffer))))
      (user-error "Save or revert project.md before registering repositories"))
    (save-excursion
      (save-restriction
        (widen)
        (let ((region (jgy-workspace--repos-region))
              (json-encoding-pretty-print nil))
          (when region
            (delete-region (car region) (cdr region))
            (goto-char (car region)))
          (insert "repos: [")
          (cl-loop for repo in repos for first = t then nil do
                   (insert (if first "\n" ",\n") "  " (json-encode repo)))
          (insert (if repos "\n  ]\n" "]\n"))
          (save-buffer))))))

(defun jgy-workspace--register-repo (root path url)
  "Register PATH and URL in ROOT after a successful clone."
  (let* ((repos (jgy-workspace--read-repos root))
         (entry (seq-find (lambda (repo) (equal (alist-get 'path repo) path)) repos)))
    (if entry
        (unless (equal (alist-get 'url entry) url)
          (user-error "Repo %s already registered with another URL" path))
      (jgy-workspace--write-repos
       root (append repos (list `((path . ,path) (url . ,url))))))))

(defun jgy-workspace--clone-entries (root repos &optional register)
  "Clone REPOS into ROOT sequentially, optionally REGISTER on success.
Existing paths are skipped.  Stop on failure and preserve Magit's log."
  (if (null repos)
      (message "Project repositories ready")
    (let* ((entry (car repos))
           (path (alist-get 'path entry))
           (url (alist-get 'url entry))
           (target (expand-file-name path root)))
      (if (or (file-exists-p target) (file-symlink-p target))
          (progn
            (message "Skipping existing path: %s" target)
            (jgy-workspace--clone-entries root (cdr repos) register))
        (require 'magit-process)
        (make-directory (file-name-directory target) t)
        (let* ((default-directory root)
               (process (magit-run-git-async "clone" "--" url target))
               (sentinel (process-sentinel process)))
          (set-process-sentinel
           process
           (lambda (proc event)
             (unwind-protect
                 (funcall sentinel proc event)
               (when (and (memq (process-status proc) '(exit signal))
                          (not (process-get proc 'jgy-workspace-handled)))
                 (process-put proc 'jgy-workspace-handled t)
                 (if (not (zerop (process-exit-status proc)))
                     (message "Clone failed for %s; see Magit process buffer" path)
                   (condition-case err
                       (progn
                         (when register (jgy-workspace--register-repo root path url))
                         (jgy-workspace--clone-entries root (cdr repos) register))
                     (error (message "Repository cloned; registration/restore stopped: %s"
                                     (error-message-string err))))))))))))))

(defun jgy-workspace--clone-candidates-into (root candidates)
  "Clone CANDIDATES from `jgy-workspace--clone-candidates' into ROOT one by one.
Each is registered in ROOT's project.md after it is cloned."
  (let ((entries (mapcar (lambda (candidate)
                           `((path . ,(nth 1 candidate)) (url . ,(nth 2 candidate))))
                         candidates)))
    (jgy-workspace--validate-repos (append (jgy-workspace--read-repos root) entries) root)
    (jgy-workspace--clone-entries root entries t)))

(defun jgy-workspace-clone-repo (repo &optional root candidates)
  "Clone remote repository REPO into ROOT and register it after success.
REPO is a name from CANDIDATES, by default `jgy-workspace--clone-candidates'."
  (interactive
   (let* ((root (jgy-workspace--current-card-root))
          (candidates (or (jgy-workspace--clone-candidates root)
                          (user-error "No remote repository left to clone")))
          (completion-extra-properties (jgy-workspace--candidate-properties candidates)))
     (list (completing-read "Repository: " candidates nil t) root candidates)))
  (let* ((root (or root (jgy-workspace--current-card-root)))
         (candidate (or (assoc repo (or candidates (jgy-workspace--clone-candidates root)))
                        (user-error "%s is not a repository to clone" repo))))
    (jgy-workspace--clone-candidates-into root (list candidate))))

(defun jgy-workspace-restore-repos (&optional root)
  "Clone missing repositories listed in the current project's project.md.
Existing paths, branches and working trees are left alone."
  (interactive)
  (let ((root (or root (jgy-workspace--current-card-root))))
    (jgy-workspace--clone-entries root (jgy-workspace--read-repos root))))

(defun jgy-workspace-register-repos (&optional root)
  "Add existing immediate child Git repositories to project.md.
Use this once for projects created before repo manifests were available.
Mapped external roots such as ~/.emacs.d remain configured separately."
  (interactive)
  (let* ((root (or root (jgy-workspace--current-card-root)))
         (repos (jgy-workspace--read-repos root)))
    (dolist (dir (directory-files root t directory-files-no-dot-files-regexp))
      (when (and (file-directory-p dir) (file-exists-p (expand-file-name ".git" dir)))
        (let* ((path (file-name-nondirectory dir))
               (url (car (process-lines "git" "-C" dir "remote" "get-url" "origin")))
               (entry (seq-find (lambda (r) (equal (alist-get 'path r) path)) repos)))
          (if entry
              (unless (equal (alist-get 'url entry) url)
                (user-error "Origin differs from manifest for %s" path))
            (setq repos (append repos (list `((path . ,path) (url . ,url)))))))))
    (jgy-workspace--write-repos root repos)
    (message "Registered %d repositories" (length repos))))

(defun jgy-workspace--pull (dirs)
  "Pull DIRS one after another, stopping at the first failure."
  (if (null dirs)
      (message "Pulled %s" (mapconcat #'abbreviate-file-name jgy-workspace-pull-repos ", "))
    (let* ((default-directory (file-name-as-directory (expand-file-name (car dirs))))
           (process (magit-run-git-async "pull" "--rebase" "--autostash")))
      (set-process-sentinel
       process
       (lambda (proc event)
         (magit-process-sentinel proc event)
         (when (memq (process-status proc) '(exit signal))
           (if (zerop (process-exit-status proc))
               (jgy-workspace--pull (cdr dirs))
             (message "Pull failed in %s, see magit process buffer" (car dirs)))))))))

(defun jgy-workspace-pull ()
  "Pull every repo in `jgy-workspace-pull-repos' through magit."
  (interactive)
  (require 'magit-process)
  (jgy-workspace--pull jgy-workspace-pull-repos))

;;; Overlook

(defun jgy-workspace-agent-root ()
  "Return the project's root when inside its folder, else the version-control root.
A project in `jgy-workspace-project-roots' has its root there."
  (if-let* ((folder (jgy-workspace-project-root)))
      (or (jgy-workspace--root (jgy-workspace--file-id folder)) folder)
    (overlook-agent-project-root)))

(defun jgy-workspace-perspective-root (name)
  "Root of perspective NAME: the root or project folder of that id, else a guess."
  (or (jgy-workspace--root name)
      (jgy-workspace-project-dir name)
      (overlook-perspective-guess-root name)))

(defun jgy-workspace-perspective-workspace (name)
  "Name of the workspace holding project NAME, or nil."
  (when-let* ((dir (jgy-workspace-project-dir name)))
    (file-name-nondirectory (directory-file-name (file-name-parent-directory
                                                  (file-name-parent-directory dir))))))

;;; Dashboard todos

(defun jgy-workspace--todo-parse (file)
  "Parse card FILE into a plist of :id :status :file :todos.
The id is the folder name and the status comes from the front matter.
Each todo is (TEXT LINE DEPTH) for an open checkbox under the Todo heading,
or anywhere when tagged #waiting; DEPTH is its indent in columns."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((front (looking-at-p "---[ \t]*$"))
          (number 1)
          status todos in-todo in-fence)
      (when front (forward-line 1) (setq number 2))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties (point) (line-end-position))))
          (cond
           (front
            (cond ((string-match-p "\\`---[ \t]*\\'" line) (setq front nil))
                  ((string-match "\\`status: *\\([a-z]+\\)" line)
                   (setq status (match-string 1 line)))))
           ((string-match-p "\\`[ \t]*```" line) (setq in-fence (not in-fence)))
           (in-fence)
           ((string-prefix-p "## " line) (setq in-todo (string= (string-trim-right line) "## Todo")))
           ((and (string-match "\\`\\( *\\)- \\[ \\] \\(.+\\)" line)
                 (or in-todo (string-match-p "#waiting\\>" line)))
            (push (list (match-string 2 line) number (length (match-string 1 line))) todos))))
        (forward-line 1)
        (cl-incf number))
      (list :id (jgy-workspace--file-id file) :status status :file file :todos (nreverse todos)))))

(defun jgy-workspace--todo-cards ()
  "Return parsed active cards, re-reading only when a card file changed."
  (let ((files (jgy-workspace-project-files)))
    (seq-filter (lambda (card) (member (plist-get card :status) '("active" "waiting" "later")))
                (jgy-workspace--cached 'cards (jgy-workspace--mtimes files)
                                       (lambda () (mapcar #'jgy-workspace--todo-parse files))))))

(defun jgy-workspace--todo-rank (text)
  "0 for a #now todo TEXT, 1 for #waiting, 2 for the rest.
Tags inside `code' do not count."
  (let ((text (replace-regexp-in-string "`[^`]*`" "" text)))
    (cond ((string-match-p "#now\\>" text) 0)
          ((string-match-p "#waiting\\>" text) 1)
          (t 2))))

(defun jgy-workspace--todo-mark (text)
  "Bullet of todo TEXT by its rank, dimmed unless #now."
  (pcase (jgy-workspace--todo-rank text)
    (0 "☐")
    (1 (propertize "◷" 'face 'shadow))
    (_ (propertize "☐" 'face 'shadow))))

(defun jgy-workspace--todo-sort (todos)
  "TODOS with #now first, then #waiting, then the rest, among siblings.
A todo moves with its subitems, ranked by the most urgent of them."
  (let (siblings)
    (while todos
      (let* ((todo (pop todos))
             (children (seq-take-while (lambda (child) (> (nth 2 child) (nth 2 todo))) todos)))
        (setq todos (nthcdr (length children) todos))
        (push (cons todo (jgy-workspace--todo-sort children)) siblings)))
    (mapcan #'copy-sequence
            (seq-sort-by (lambda (group) (apply #'min (mapcar (lambda (todo) (jgy-workspace--todo-rank (car todo))) group)))
                         #'<
                         (nreverse siblings)))))

(defun jgy-workspace--todo-display (text)
  "Return TEXT without inline fields and tags, with its due date appended.
#now shows plain, #waiting italic and the rest dimmed."
  (let ((due (and (string-match "\\[due:: *\\([0-9-]+\\)\\]" text) (match-string 1 text)))
        (face (pcase (jgy-workspace--todo-rank text)
                (0 'default)
                (1 'italic)
                (_ 'shadow)))
        (clean (string-trim
                (replace-regexp-in-string
                 " +" " "
                 (replace-regexp-in-string
                  "\\(`[^`]*`\\)\\|\\[[a-z]+::[^]]*\\]\\|#[[:alnum:]_-]+"
                  (lambda (match) (if (string-prefix-p "`" match) match ""))
                  text t t)))))
    (concat (propertize clean 'face face)
            (if due (propertize (concat " " due) 'face 'shadow) ""))))

(defun jgy-workspace--todo-split (todos)
  "Split sorted TODOS into (URGENT . REST) at the first plain top-level todo.
A top-level todo is urgent when it or one of its subitems is #now or #waiting."
  (let ((top (nth 2 (car todos)))
        (rest todos))
    (while (and rest
                (let ((group (cons (car rest)
                                   (seq-take-while (lambda (todo) (> (nth 2 todo) top)) (cdr rest)))))
                  (when (< (apply #'min (mapcar (lambda (todo) (jgy-workspace--todo-rank (car todo))) group))
                           2)
                    (setq rest (nthcdr (length group) rest))))))
    (cons (seq-take todos (- (length todos) (length rest))) rest)))

(defun jgy-workspace--todo-visit (perspective file line)
  "Return a command that opens FILE at LINE in the main window.
It first switches to PERSPECTIVE, creating it if needed, when non-nil."
  (lambda ()
    (overlook-show-elsewhere perspective
                             (lambda ()
                               (find-file file)
                               (goto-char (point-min))
                               (forward-line (1- line))))))

(defun jgy-workspace--insert-groups (groups mark)
  "Insert GROUPS separated by blank lines, each item led by MARK of its text.
Each group is (NAME FILE CURRENT ITEMS PERSPECTIVE FOLDED): a heading NAME
that visits FILE, highlighted when CURRENT, then ITEMS as (TEXT LINE DEPTH),
deeper ones under the item before them.  Visiting switches to PERSPECTIVE
first when it is non-nil.  FOLDED items go under a \"later\" line counting
their top-level ones, folded until toggled.  Return the last group's section."
  (let ((previous nil))
    (pcase-dolist (`(,name ,file ,current ,items ,perspective ,folded) groups)
      (when previous (overlook-end-with-blank previous))
      (cl-labels ((insert-items (items)
                    (while items
                      (pcase-let* ((`(,text ,line ,depth) (pop items))
                                   (children (seq-take-while (lambda (child) (> (nth 2 child) depth))
                                                             items))
                                   (indent (make-string depth ?\s)))
                        (setq items (nthcdr (length children) items))
                        ;; ◷、☐ 在等宽字体里都占两列，折行接在它们后面。
                        (overlook-insert-row
                         (propertize (concat indent (funcall mark text) " "
                                             (jgy-workspace--todo-display text) "\n")
                                     'overlook-action (jgy-workspace--todo-visit perspective file line)
                                     'wrap-prefix (concat indent "   "))
                         (and children (lambda () (insert-items children))))))))
        (setq previous (overlook-insert-row
                        (concat (propertize name
                                            'face (if current 'overlook-heading-current 'overlook-heading)
                                            'overlook-heading t
                                            'overlook-action (jgy-workspace--todo-visit perspective file 1))
                                "\n")
                        (lambda ()
                          (insert-items items)
                          (when folded
                            (let ((top (nth 2 (car folded))))
                              (overlook-insert-row
                               (propertize (format "later (%d)\n"
                                                   (seq-count (lambda (todo) (= (nth 2 todo) top)) folded))
                                           'face 'shadow
                                           'overlook-item (cons 'todo-fold name))
                               (lambda () (insert-items folded))
                               t))))))))
    previous))

(defun jgy-workspace--todo-ordered (cards)
  "CARDS with todos, those with a perspective first in the dashboard's order."
  (let ((order (overlook-ordered-perspectives)))
    (seq-sort-by (lambda (card) (or (seq-position order (plist-get card :id)) (length order)))
                 #'<
                 (seq-filter (lambda (card) (plist-get card :todos)) cards))))

(defun jgy-workspace--todo-groups (cards current)
  "Groups for `jgy-workspace--insert-groups' of CARDS, highlighting CURRENT."
  (mapcar (lambda (card)
            (let ((split (jgy-workspace--todo-split
                          (jgy-workspace--todo-sort (plist-get card :todos)))))
              (list (plist-get card :id) (plist-get card :file)
                    (equal (plist-get card :id) current)
                    (car split) (plist-get card :id) (cdr split))))
          cards))

(defun jgy-workspace--todo-section ()
  "Insert a Todo section with every ongoing project's open todos.
Projects with status later go last, under a folded \"later\" line."
  (let ((current (overlook-current-perspective)))
    (overlook-insert-section
     "Todo"
     (lambda ()
       (let* ((cards (jgy-workspace--todo-ordered (jgy-workspace--todo-cards)))
              (later-p (lambda (card) (equal (plist-get card :status) "later")))
              (later (seq-filter later-p cards))
              (last (jgy-workspace--insert-groups
                     (jgy-workspace--todo-groups (seq-remove later-p cards) current)
                     #'jgy-workspace--todo-mark)))
         (when later
           (when last (overlook-end-with-blank last))
           (overlook-insert-row
            (propertize (format "later (%d)\n" (length later))
                        'face 'shadow
                        'overlook-item '(todo-later))
            (lambda ()
              (jgy-workspace--insert-groups (jgy-workspace--todo-groups later current)
                                            #'jgy-workspace--todo-mark))
            t)))))))

;;; Dashboard inbox

(defun jgy-workspace--inbox-workspace (file)
  "Name of the workspace holding inbox FILE."
  (file-name-nondirectory (directory-file-name (file-name-directory file))))

(defun jgy-workspace--inbox-items (file)
  "Open items of inbox FILE, as (TEXT LINE DEPTH) like todos.
Done items are left out together with their subitems."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((number 1) items done)
      (while (not (eobp))
        (when (looking-at "\\( *\\)- \\(\\[[xX]\\] \\)?\\(?:\\[ \\] \\)?\\(.+\\)")
          (let ((depth (length (match-string 1))))
            (when (and done (<= depth done)) (setq done nil))
            (cond (done)
                  ((match-beginning 2) (setq done depth))
                  (t (push (list (match-string-no-properties 3) number depth) items)))))
        (forward-line 1)
        (cl-incf number))
      (nreverse items))))

(defun jgy-workspace--inbox-section ()
  "Insert an Inbox section with each workspace's open inbox items.
The workspace of the current perspective comes first."
  (let* ((current (jgy-workspace-perspective-workspace (or (overlook-current-perspective) "")))
         (files (file-expand-wildcards (expand-file-name "*/inbox.md" (jgy-workspace--base))))
         (mine (lambda (file) (equal (jgy-workspace--inbox-workspace file) current)))
         (files (append (seq-filter mine files) (seq-remove mine files))))
    (overlook-insert-section
     "Inbox"
     (lambda ()
       (jgy-workspace--insert-groups
        (seq-keep (lambda (file)
                    (when-let* ((items (jgy-workspace--inbox-items file)))
                      (list (jgy-workspace--inbox-workspace file) file nil items)))
                  files)
        (lambda (_) (propertize "☐" 'face 'shadow)))))))

(defun jgy-workspace--refresh-after-save ()
  "Re-render the dashboard after saving a project.md or inbox.md."
  (when (and buffer-file-name
             (fboundp 'overlook-refresh)
             (pcase (file-name-nondirectory buffer-file-name)
               ("project.md" (jgy-workspace-project-root))
               ("inbox.md" (file-in-directory-p buffer-file-name jgy-workspace-directory))))
    (overlook-refresh)))

;;;###autoload
(define-minor-mode jgy-workspace-dashboard-mode
  "Show ongoing projects' todos and the inboxes in the agents dashboard."
  :global t
  :group 'jgy-workspace
  (if jgy-workspace-dashboard-mode
      (progn
        (add-hook 'overlook-sections #'jgy-workspace--todo-section 50)
        (add-hook 'overlook-sections #'jgy-workspace--inbox-section 60)
        (add-hook 'after-save-hook #'jgy-workspace--refresh-after-save))
    (remove-hook 'overlook-sections #'jgy-workspace--todo-section)
    (remove-hook 'overlook-sections #'jgy-workspace--inbox-section)
    (remove-hook 'after-save-hook #'jgy-workspace--refresh-after-save)))

(provide 'jgy-workspace)
;;; jgy-workspace.el ends here
