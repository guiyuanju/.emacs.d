;;; iuiw-workspace.el --- Workspaces, projects, perspectives and repos -*- lexical-binding: t; -*-

;;; Commentary:
;; workspace（~/workspace/me、okj…）→ 项目 projects/<id>/（project.md）→ 若干 repo（各一个 git 仓库）；
;; 每个项目对应一个同名 perspective，项目 id 即文件夹名。
;; 位置固定的 repo（如 ~/.emacs.d）不搬进项目文件夹，用 `iuiw-workspace-project-roots' 指过去：
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
;; 各项目的 #now 项连同子项收到最上面的 #now 组，当前项目的在前，再按到期日排，不再列在项目下。
;; 项目名后依次是不为 0 的 ☐#now 数、◷#waiting 数和未完成的顶层待办数，非 #now 的待办折叠在项目名下，#waiting 在前。
;; status 为 later 的项目排在最后，收在一行折叠的 later 下面。
;; `iuiw-workspace-filter' 只显示一个 workspace 的项目、perspective 和 inbox；front matter 的
;; also: [okj] 让项目也算进列出的其他 workspace。

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
(defvar persp-sort)
(defvar overlook-mode-line-functions)

(defgroup iuiw-workspace nil
  "Project folders under ~/workspace."
  :group 'convenience)

(defcustom iuiw-workspace-directory "~/workspace/"
  "Directory containing workspaces, each with a projects/ folder."
  :type 'directory
  :group 'iuiw-workspace)

(defcustom iuiw-workspace-project-roots nil
  "Alist of project id to its root outside the workspaces.
The project's card stays in its workspace folder; the dashboard lists
the repos of the root, and agents started in the card folder run there."
  :type '(alist :key-type string :value-type directory)
  :group 'iuiw-workspace)

(defcustom iuiw-workspace-filter nil
  "Workspace whose projects the dashboard and `iuiw-workspace-open-project' show.
Nil shows every workspace.  A project also counts for the workspaces in
the also: list of its front matter."
  :type '(choice (const :tag "All" nil) string)
  :group 'iuiw-workspace)

(defcustom iuiw-workspace-pull-repos '("~/.emacs.d/" "~/workspace/")
  "Repos pulled by `iuiw-workspace-pull'."
  :type '(repeat directory)
  :group 'iuiw-workspace)

;;; Cache

(defvar iuiw-workspace--cache nil
  "Alist of key to (STAMP . VALUE), see `iuiw-workspace--cached'.")

(defun iuiw-workspace--cached (key stamp compute)
  "Value cached under KEY while it was computed at STAMP, else call COMPUTE."
  (let ((entry (alist-get key iuiw-workspace--cache)))
    (if (and entry (equal (car entry) stamp))
        (cdr entry)
      (let ((value (funcall compute)))
        (setf (alist-get key iuiw-workspace--cache) (cons stamp value))
        value))))

(defun iuiw-workspace--mtimes (files)
  "FILES paired with their modification times, nil for missing ones."
  (mapcar (lambda (file) (cons file (file-attribute-modification-time (file-attributes file))))
          files))

;;; Projects

(defun iuiw-workspace--base ()
  "`iuiw-workspace-directory' with symlinks resolved, as a directory name.
Every project path is built from this, so paths compare with `equal'."
  (file-name-as-directory (file-truename iuiw-workspace-directory)))

(defun iuiw-workspace--root (id)
  "Root of project ID from `iuiw-workspace-project-roots', or nil."
  (when-let* ((dir (cdr (assoc id iuiw-workspace-project-roots))))
    (file-name-as-directory (file-truename dir))))

(defun iuiw-workspace--root-id (&optional directory)
  "Id of the project whose root in `iuiw-workspace-project-roots' holds DIRECTORY.
Of nested roots the innermost wins."
  (let ((directory (or directory default-directory)))
    (car (car (sort (seq-filter (lambda (entry) (file-in-directory-p directory (cdr entry)))
                                iuiw-workspace-project-roots)
                    (lambda (a b) (> (length (iuiw-workspace--root (car a)))
                                     (length (iuiw-workspace--root (car b))))))))))

(defun iuiw-workspace--file-id (file)
  "Id of the project whose card is FILE: its folder name."
  (file-name-nondirectory (directory-file-name (file-name-directory file))))

(defun iuiw-workspace-project-root (&optional directory)
  "Return the <workspace>/projects/<id>/ folder containing DIRECTORY, or nil.
Symlinks are resolved first, so a link into a project folder finds it."
  (let ((dir (file-name-as-directory (file-truename (or directory default-directory)))))
    (when (string-match (concat "\\`" (regexp-quote (iuiw-workspace--base)) "[^/]+/projects/[^./][^/]*/")
                        dir)
      (let ((root (match-string 0 dir)))
        (and (file-exists-p (expand-file-name "project.md" root)) root)))))

(defun iuiw-workspace--projects ()
  "Alist of project id to project.md across the workspaces.
Globbed again only when the workspace root or a projects/ folder changes."
  (let* ((base (iuiw-workspace--base))
         (stamp (cons base (iuiw-workspace--mtimes
                            (cons base (mapcar (lambda (dir) (expand-file-name "projects/" dir))
                                               (directory-files base t "\\`[^.]")))))))
    (iuiw-workspace--cached
     'projects stamp
     (lambda ()
       (seq-keep (lambda (file)
                   (let ((id (iuiw-workspace--file-id file)))
                     (unless (string-prefix-p "." id) (cons id file))))
                 (file-expand-wildcards (expand-file-name "*/projects/*/project.md" base)))))))

(defun iuiw-workspace-project-files ()
  "Return every project card of the workspaces."
  (mapcar #'cdr (iuiw-workspace--projects)))

(defun iuiw-workspace--workspaces ()
  "Names of the workspaces, the folders with a projects/ folder."
  (mapcar (lambda (dir) (file-name-nondirectory (directory-file-name (file-name-parent-directory dir))))
          (file-expand-wildcards (expand-file-name "*/projects/" (iuiw-workspace--base)))))

(defun iuiw-workspace--file-workspace (file)
  "Name of the workspace holding project card FILE."
  (file-name-nondirectory (directory-file-name (file-name-parent-directory
                                                (file-name-parent-directory
                                                 (file-name-directory file))))))

(defun iuiw-workspace--shown-p (card)
  "Non-nil when CARD belongs to `iuiw-workspace-filter', or there is no filter."
  (or (null iuiw-workspace-filter)
      (equal iuiw-workspace-filter (plist-get card :workspace))
      (member iuiw-workspace-filter (plist-get card :also))))

(defun iuiw-workspace-perspective-shown-p (name)
  "Non-nil unless perspective NAME is a project hidden by `iuiw-workspace-filter'."
  (let ((card (seq-find (lambda (card) (equal (plist-get card :id) name)) (iuiw-workspace--cards))))
    (or (null card) (iuiw-workspace--shown-p card))))

(defun iuiw-workspace-switch-perspective (name)
  "Switch to perspective NAME, offering those shown by `iuiw-workspace-filter'.
Candidates are most recently used first.  Any name works; a new one
creates the perspective."
  (interactive
   (let ((names (seq-filter #'iuiw-workspace-perspective-shown-p
                            (remove (persp-current-name)
                                    (let ((persp-sort 'access)) (persp-names))))))
     (list (completing-read "Perspective: "
                            (lambda (string pred action)
                              (if (eq action 'metadata)
                                  '(metadata (display-sort-function . identity))
                                (complete-with-action action names string pred)))))))
  (persp-switch name))

(defun iuiw-workspace-cycle-filter ()
  "Cycle `iuiw-workspace-filter' through every workspace, then all."
  (interactive)
  (let ((choices (cons nil (iuiw-workspace--workspaces))))
    (setq iuiw-workspace-filter (or (cadr (member iuiw-workspace-filter choices)) nil))
    (message "Workspace filter: %s" (or iuiw-workspace-filter "all"))
    (force-mode-line-update t)
    (when (fboundp 'overlook-refresh) (overlook-refresh))))

(defun iuiw-workspace-project-dir (id)
  "Folder of project ID, or nil."
  (when-let* ((file (cdr (assoc id (iuiw-workspace--projects)))))
    (file-name-directory file)))

(defun iuiw-workspace--projects-by-mtime ()
  "Return the project.md of every project shown by the filter, newest first."
  (sort (mapcar (lambda (card) (plist-get card :file))
                (seq-filter #'iuiw-workspace--shown-p (iuiw-workspace--cards)))
        #'file-newer-than-file-p))

(defun iuiw-workspace--read-workspace ()
  "Read a workspace name and return its projects folder."
  (let* ((base (iuiw-workspace--base))
         (names (iuiw-workspace--workspaces))
         (name (if (cdr names)
                   (completing-read "Workspace: " names nil t)
                 (or (car names) (user-error "No workspace under %s" iuiw-workspace-directory)))))
    (expand-file-name (concat name "/projects/") base)))

(defun iuiw-workspace--check-new-id (id)
  "Signal a `user-error' unless ID can name a new project."
  (unless (string-match-p "\\`[a-z0-9][a-z0-9-]*\\'" id)
    (user-error "Project id must be lowercase letters, digits and hyphens: %S" id))
  (when (and (fboundp 'persp-names) (bound-and-true-p persp-mode) (member id (persp-names)))
    (user-error "Perspective %s exists and is not a project" id)))

(defun iuiw-workspace--template ()
  "Contents of the project template, or a `user-error' when it is missing."
  (let ((file (expand-file-name "project-template.md" iuiw-workspace-directory)))
    (unless (file-readable-p file) (user-error "No project template at %s" file))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun iuiw-workspace--create-project (file id title)
  "Create project.md FILE for ID with TITLE from the project template."
  (let ((text (replace-regexp-in-string
               "{{\\(id\\|title\\|date\\)}}"
               (lambda (match)
                 (pcase match
                   ("{{id}}" id)
                   ("{{title}}" title)
                   (_ (format-time-string "%F"))))
               (iuiw-workspace--template) t t)))
    (make-directory (file-name-directory file) t)
    ;; overlook-markers 据此把项目文件夹连同其中所有 clone 当作一个 project。
    (write-region "" nil (expand-file-name ".overlook" (file-name-directory file)))
    (write-region text nil file nil nil nil 'excl)))

(defun iuiw-workspace--new-project (id)
  "Create project ID in a workspace read from the user; return its project.md."
  (iuiw-workspace--check-new-id id)
  (when (assoc id (iuiw-workspace--projects)) (user-error "Project %s exists" id))
  (iuiw-workspace--template)
  (let ((file (expand-file-name (concat id "/project.md") (iuiw-workspace--read-workspace))))
    (iuiw-workspace--create-project file id (read-string "Title: "))
    file))

(defun iuiw-workspace--switch (id file)
  "Switch to the perspective of project ID; a new one opens its project.md FILE."
  (let ((new (not (member id (persp-names)))))
    (persp-switch id)
    (when new (find-file file))))

(defun iuiw-workspace-open-project (id)
  "Switch to the perspective of project ID, creating the project when it is new.
A new perspective opens project.md; an existing one keeps its windows.
Only projects shown by `iuiw-workspace-filter' are offered; any id works."
  (interactive (list (string-trim
                      (completing-read "Project: " (mapcar #'iuiw-workspace--file-id
                                                           (iuiw-workspace--projects-by-mtime))))))
  (iuiw-workspace--switch id (or (cdr (assoc id (iuiw-workspace--projects)))
                                (iuiw-workspace--new-project id))))

(defun iuiw-workspace-new-project (id)
  "Create project ID, clone repositories into it and open it in its perspective.
The repositories are read with `completing-read-multiple'; none is fine."
  (interactive (list (string-trim (read-string "New project id: "))))
  (let* ((file (iuiw-workspace--new-project id))
         (root (file-name-directory file))
         (candidates (condition-case err
                         (iuiw-workspace--clone-candidates root)
                       (user-error (message "Skipping clone: %s" (error-message-string err))
                                   nil)))
         (repos (when candidates
                  (let ((completion-extra-properties
                         (iuiw-workspace--candidate-properties candidates)))
                    ;; A function instead of t lets vertico select the empty prompt.
                    (completing-read-multiple
                     "Clone repositories (empty for none): " candidates nil
                     (lambda (input)
                       (seq-every-p (lambda (repo) (assoc repo candidates))
                                    (split-string input crm-separator t))))))))
    (iuiw-workspace--switch id file)
    (when repos
      (iuiw-workspace--clone-candidates-into root (mapcar (lambda (repo) (assoc repo candidates)) repos)))))

(defun iuiw-workspace-visit-project-md ()
  "Open the project.md of the current perspective, project folder or root.
From a side window such as the dashboard it opens in the main window."
  (interactive)
  (let ((dir (iuiw-workspace--current-card-root)))
    (when (fboundp 'overlook-main-window) (overlook-main-window))
    (find-file (expand-file-name "project.md" dir))))

(defun iuiw-workspace--cli-output (program &rest args)
  "Stdout of PROGRAM run with ARGS from the home folder, or a `user-error'."
  (let ((default-directory (expand-file-name "~/"))
        (stderr (make-temp-file "iuiw-workspace-cli")))
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

(defun iuiw-workspace--parse-json-arrays (text)
  "Concatenate the JSON arrays in TEXT, as printed page by page by glab."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (items)
      (while (progn (skip-chars-forward " \t\n\r") (not (eobp)))
        (setq items (append items (json-parse-buffer :array-type 'list :object-type 'alist
                                                     :null-object nil))))
      items)))

(defun iuiw-workspace--remotes (root)
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

(defun iuiw-workspace--remote-repos (forge arg)
  "Repositories of remote FORGE with ARG, as (NAME PATH URL DESCRIPTION).
The URL follows the protocol configured in the forge's CLI."
  (pcase forge
    ("github"
     (let ((ssh (equal (string-trim (iuiw-workspace--cli-output "gh" "config" "get" "git_protocol"))
                       "ssh")))
       (mapcar (lambda (repo)
                 (let ((name (alist-get 'nameWithOwner repo)))
                   (list name (file-name-nondirectory name)
                         (if ssh (alist-get 'sshUrl repo) (concat (alist-get 'url repo) ".git"))
                         (alist-get 'description repo))))
               (json-parse-string
                (iuiw-workspace--cli-output "gh" "repo" "list" arg "--no-archived" "--limit" "1000"
                                           "--json" "nameWithOwner,url,sshUrl,description")
                :array-type 'list :object-type 'alist :null-object nil))))
    ("gitlab"
     (let ((ssh (equal (string-trim (iuiw-workspace--cli-output "glab" "config" "get" "git_protocol"
                                                               "--host" arg))
                       "ssh")))
       (mapcar (lambda (repo)
                 (list (alist-get 'path_with_namespace repo) (alist-get 'path repo)
                       (alist-get (if ssh 'ssh_url_to_repo 'http_url_to_repo) repo)
                       (alist-get 'description repo)))
               (iuiw-workspace--parse-json-arrays
                (iuiw-workspace--cli-output
                 "glab" "api" "--hostname" arg "--paginate"
                 "projects?membership=true&simple=true&archived=false&per_page=100")))))
    (_ (user-error "Unknown forge in .remotes: %s" forge))))

(defun iuiw-workspace--clone-candidates (root)
  "Remote repos to clone into project folder ROOT, as (NAME PATH URL DESCRIPTION).
Repos whose path exists in ROOT or is registered in its project.md are left out."
  (let ((taken (mapcar (lambda (repo) (alist-get 'path repo)) (iuiw-workspace--read-repos root)))
        candidates)
    (pcase-dolist (`(,forge ,arg) (iuiw-workspace--remotes root))
      (dolist (repo (iuiw-workspace--remote-repos forge arg))
        (unless (or (assoc (car repo) candidates)
                    (member (nth 1 repo) taken)
                    (file-exists-p (expand-file-name (nth 1 repo) root)))
          (push repo candidates))))
    (nreverse candidates)))

(defun iuiw-workspace--candidate-properties (candidates)
  "`completion-extra-properties' showing the description of CANDIDATES."
  (list :annotation-function
        (lambda (name)
          (when-let* ((description (nth 3 (assoc name candidates)))
                      ((not (string-empty-p description))))
            (concat "  " (propertize description 'face 'completions-annotations))))))

(defun iuiw-workspace--current-card-root ()
  "Return the current project's card directory, including mapped projects."
  (or (and (bound-and-true-p persp-mode)
           (iuiw-workspace-project-dir (persp-current-name)))
      (iuiw-workspace-project-root)
      (when-let* ((id (iuiw-workspace--root-id)))
        (iuiw-workspace-project-dir id))
      (user-error "Not inside a project folder")))

(defun iuiw-workspace--repos-region ()
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

(defun iuiw-workspace--validate-repos (repos root)
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

(defun iuiw-workspace--read-repos (root)
  "Read ROOT's repos array using Emacs's built-in JSON parser.
The JSON array is also valid YAML.  Other front matter is left untouched."
  (with-current-buffer (find-file-noselect (expand-file-name "project.md" root))
    (unless (verify-visited-file-modtime (current-buffer))
      (user-error "Revert project.md before reading repositories"))
    (save-excursion
      (save-restriction
        (widen)
        (let ((region (iuiw-workspace--repos-region)))
          (when region
            (let* ((text (buffer-substring-no-properties (+ (car region) 6) (cdr region)))
                   (repos (condition-case nil
                              (json-parse-string text :array-type 'list :object-type 'alist
                                                 :null-object :null :false-object :false)
                            (error (user-error "repos must be a JSON array of path/url objects")))))
              (unless (string-prefix-p "[" (string-trim-left text))
                (user-error "repos must be a JSON array"))
              (iuiw-workspace--validate-repos repos root))))))))

(defun iuiw-workspace--write-repos (root repos)
  "Save REPOS in ROOT's card, preserving other fields and body.
Refuse to save over unsaved user edits or external file changes."
  (iuiw-workspace--validate-repos repos root)
  (with-current-buffer (find-file-noselect (expand-file-name "project.md" root))
    (when (or (buffer-modified-p) (not (verify-visited-file-modtime (current-buffer))))
      (user-error "Save or revert project.md before registering repositories"))
    (save-excursion
      (save-restriction
        (widen)
        (let ((region (iuiw-workspace--repos-region))
              (json-encoding-pretty-print nil))
          (when region
            (delete-region (car region) (cdr region))
            (goto-char (car region)))
          (insert "repos: [")
          (cl-loop for repo in repos for first = t then nil do
                   (insert (if first "\n" ",\n") "  " (json-encode repo)))
          (insert (if repos "\n  ]\n" "]\n"))
          (save-buffer))))))

(defun iuiw-workspace--add-repo (repos path url)
  "Return REPOS with PATH and URL appended, unchanged when PATH is listed.
Signal a `user-error' when PATH is listed with another URL."
  (if-let* ((entry (seq-find (lambda (repo) (equal (alist-get 'path repo) path)) repos)))
      (if (equal (alist-get 'url entry) url)
          repos
        (user-error "Repo %s already registered with another URL" path))
    (append repos (list `((path . ,path) (url . ,url))))))

(defun iuiw-workspace--register-repo (root path url)
  "Register PATH and URL in ROOT after a successful clone."
  (let* ((repos (iuiw-workspace--read-repos root))
         (new (iuiw-workspace--add-repo repos path url)))
    (unless (eq new repos)
      (iuiw-workspace--write-repos root new))))

(defun iuiw-workspace--clone-entries (root repos &optional register)
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
            (iuiw-workspace--clone-entries root (cdr repos) register))
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
                          (not (process-get proc 'iuiw-workspace-handled)))
                 (process-put proc 'iuiw-workspace-handled t)
                 (if (not (zerop (process-exit-status proc)))
                     (message "Clone failed for %s; see Magit process buffer" path)
                   (condition-case err
                       (progn
                         (when register (iuiw-workspace--register-repo root path url))
                         (iuiw-workspace--clone-entries root (cdr repos) register))
                     (error (message "Repository cloned; registration/restore stopped: %s"
                                     (error-message-string err))))))))))))))

(defun iuiw-workspace--clone-candidates-into (root candidates)
  "Clone CANDIDATES from `iuiw-workspace--clone-candidates' into ROOT one by one.
Each is registered in ROOT's project.md after it is cloned."
  (let ((entries (mapcar (lambda (candidate)
                           `((path . ,(nth 1 candidate)) (url . ,(nth 2 candidate))))
                         candidates)))
    (iuiw-workspace--validate-repos (append (iuiw-workspace--read-repos root) entries) root)
    (iuiw-workspace--clone-entries root entries t)))

(defun iuiw-workspace-clone-repo (repo &optional root candidates)
  "Clone remote repository REPO into ROOT and register it after success.
REPO is a name from CANDIDATES, by default `iuiw-workspace--clone-candidates'."
  (interactive
   (let* ((root (iuiw-workspace--current-card-root))
          (candidates (or (iuiw-workspace--clone-candidates root)
                          (user-error "No remote repository left to clone")))
          (completion-extra-properties (iuiw-workspace--candidate-properties candidates)))
     (list (completing-read "Repository: " candidates nil t) root candidates)))
  (let* ((root (or root (iuiw-workspace--current-card-root)))
         (candidate (or (assoc repo (or candidates (iuiw-workspace--clone-candidates root)))
                        (user-error "%s is not a repository to clone" repo))))
    (iuiw-workspace--clone-candidates-into root (list candidate))))

(defun iuiw-workspace-restore-repos (&optional root)
  "Clone missing repositories listed in the current project's project.md.
Existing paths, branches and working trees are left alone."
  (interactive)
  (let ((root (or root (iuiw-workspace--current-card-root))))
    (iuiw-workspace--clone-entries root (iuiw-workspace--read-repos root))))

(defun iuiw-workspace-register-repos (&optional root)
  "Add existing immediate child Git repositories to project.md.
Use this once for projects created before repo manifests were available.
Mapped external roots such as ~/.emacs.d remain configured separately."
  (interactive)
  (let* ((root (or root (iuiw-workspace--current-card-root)))
         (repos (iuiw-workspace--read-repos root)))
    (dolist (dir (directory-files root t directory-files-no-dot-files-regexp))
      (when (and (file-directory-p dir) (file-exists-p (expand-file-name ".git" dir)))
        (setq repos (iuiw-workspace--add-repo
                     repos (file-name-nondirectory dir)
                     (car (process-lines "git" "-C" dir "remote" "get-url" "origin"))))))
    (iuiw-workspace--write-repos root repos)
    (message "Registered %d repositories" (length repos))))

(defun iuiw-workspace--pull (dirs)
  "Pull DIRS one after another, stopping at the first failure."
  (if (null dirs)
      (message "Pulled %s" (mapconcat #'abbreviate-file-name iuiw-workspace-pull-repos ", "))
    (let* ((default-directory (file-name-as-directory (expand-file-name (car dirs))))
           (process (magit-run-git-async "pull" "--rebase" "--autostash")))
      (set-process-sentinel
       process
       (lambda (proc event)
         (magit-process-sentinel proc event)
         (when (memq (process-status proc) '(exit signal))
           (if (zerop (process-exit-status proc))
               (iuiw-workspace--pull (cdr dirs))
             (message "Pull failed in %s, see magit process buffer" (car dirs)))))))))

(defun iuiw-workspace-pull ()
  "Pull every repo in `iuiw-workspace-pull-repos' through magit."
  (interactive)
  (require 'magit-process)
  (iuiw-workspace--pull iuiw-workspace-pull-repos))

;;; Overlook

(defun iuiw-workspace-agent-root ()
  "Return the project's root when inside its folder or root.
A project in `iuiw-workspace-project-roots' has its root there.  Outside
any project, return the version-control root."
  (if-let* ((folder (iuiw-workspace-project-root)))
      (or (iuiw-workspace--root (iuiw-workspace--file-id folder)) folder)
    (if-let* ((id (iuiw-workspace--root-id)))
        (iuiw-workspace--root id)
      (overlook-agent-project-root))))

(defun iuiw-workspace-perspective-root (name)
  "Root of perspective NAME: the root or project folder of that id, else a guess."
  (or (iuiw-workspace--root name)
      (iuiw-workspace-project-dir name)
      (overlook-perspective-guess-root name)))

(defun iuiw-workspace-perspective-folders (name)
  "Folder of project NAME, whose project.md lives in the workspace repo."
  (when-let* ((dir (iuiw-workspace-project-dir name)))
    (list dir)))

(defun iuiw-workspace-perspective-workspace (name)
  "Name of the workspace holding project NAME, or nil."
  (when-let* ((file (cdr (assoc name (iuiw-workspace--projects)))))
    (iuiw-workspace--file-workspace file)))

;;; Dashboard todos

(defun iuiw-workspace--todo-parse (file)
  "Parse card FILE into a plist of :id :workspace :status :also :file :todos.
The id is the folder name; the status and the also: list of workspace
names come from the front matter.
Each todo is (TEXT LINE DEPTH) for an open checkbox under the Todo heading,
or anywhere when tagged #waiting; DEPTH is its indent in columns."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((front (looking-at-p "---[ \t]*$"))
          (number 1)
          status also todos in-todo in-fence)
      (when front (forward-line 1) (setq number 2))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties (point) (line-end-position))))
          (cond
           (front
            (cond ((string-match-p "\\`---[ \t]*\\'" line) (setq front nil))
                  ((string-match "\\`status: *\\([a-z]+\\)" line)
                   (setq status (match-string 1 line)))
                  ((string-match "\\`also: *\\[\\([^]]*\\)\\]" line)
                   (setq also (split-string (match-string 1 line) "[ \t,\"']+" t)))))
           ((string-match-p "\\`[ \t]*```" line) (setq in-fence (not in-fence)))
           (in-fence)
           ((string-prefix-p "## " line) (setq in-todo (string= (string-trim-right line) "## Todo")))
           ((and (string-match "\\`\\( *\\)- \\[ \\] \\(.+\\)" line)
                 (or in-todo (string-match-p "#waiting\\>" line)))
            (push (list (match-string 2 line) number (length (match-string 1 line))) todos))))
        (forward-line 1)
        (cl-incf number))
      (list :id (iuiw-workspace--file-id file) :workspace (iuiw-workspace--file-workspace file)
            :status status :also also :file file :todos (nreverse todos)))))

(defun iuiw-workspace--cards ()
  "Return every parsed card, re-reading only when a card file changed."
  (let ((files (iuiw-workspace-project-files)))
    (iuiw-workspace--cached 'cards (iuiw-workspace--mtimes files)
                           (lambda () (mapcar #'iuiw-workspace--todo-parse files)))))

(defun iuiw-workspace--todo-cards ()
  "Return parsed ongoing cards shown by `iuiw-workspace-filter'."
  (seq-filter (lambda (card) (and (member (plist-get card :status) '("active" "waiting" "later"))
                                  (iuiw-workspace--shown-p card)))
              (iuiw-workspace--cards)))

(defun iuiw-workspace--todo-rank (text)
  "0 for a #now todo TEXT, 1 for #waiting, 2 for the rest.
Tags inside `code' do not count."
  (let ((text (replace-regexp-in-string "`[^`]*`" "" text)))
    (cond ((string-match-p "#now\\>" text) 0)
          ((string-match-p "#waiting\\>" text) 1)
          (t 2))))

(defun iuiw-workspace--todo-mark (text)
  "Bullet of todo TEXT by its rank, dimmed unless #now."
  (pcase (iuiw-workspace--todo-rank text)
    (0 "☐")
    (1 (propertize "◷" 'face 'shadow))
    (_ (propertize "☐" 'face 'shadow))))

(defun iuiw-workspace--todo-sort (todos)
  "TODOS with #now first, then #waiting, then the rest, among siblings.
A todo moves with its subitems, ranked by the most urgent of them."
  (let (siblings)
    (while todos
      (let* ((todo (pop todos))
             (children (seq-take-while (lambda (child) (> (nth 2 child) (nth 2 todo))) todos)))
        (setq todos (nthcdr (length children) todos))
        (push (cons todo (iuiw-workspace--todo-sort children)) siblings)))
    (mapcan #'copy-sequence
            (seq-sort-by (lambda (group) (apply #'min (mapcar (lambda (todo) (iuiw-workspace--todo-rank (car todo))) group)))
                         #'<
                         (nreverse siblings)))))

(defun iuiw-workspace--todo-display (text)
  "Return TEXT without inline fields and tags, with its due date appended.
#now shows plain, #waiting italic and the rest dimmed."
  (let ((due (and (string-match "\\[due:: *\\([0-9-]+\\)\\]" text) (match-string 1 text)))
        (face (pcase (iuiw-workspace--todo-rank text)
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

(defun iuiw-workspace--todo-take-now (todos)
  "Split TODOS into (NOW . REST), taking out each outermost #now todo.
NOW lists them as (PARENT . ITEMS): PARENT is the text of the todo it
sits under, or nil, and ITEMS are it and its subitems, depths from 0."
  (let (now rest ancestors)
    (while todos
      (let* ((todo (pop todos))
             (depth (nth 2 todo)))
        (setq ancestors (seq-drop-while (lambda (ancestor) (>= (nth 2 ancestor) depth)) ancestors))
        (if (= (iuiw-workspace--todo-rank (car todo)) 0)
            (let ((children (seq-take-while (lambda (child) (> (nth 2 child) depth)) todos)))
              (setq todos (nthcdr (length children) todos))
              (push (cons (car (car ancestors))
                          (mapcar (lambda (item) (list (car item) (nth 1 item) (- (nth 2 item) depth)))
                                  (cons todo children)))
                    now))
          (push todo ancestors)
          (push todo rest))))
    (cons (nreverse now) (nreverse rest))))

(defun iuiw-workspace--todo-now-items (cards current)
  "The #now todos of CARDS with their subitems.
Those of project CURRENT come first, then by due date, then card order.
Each leading item names its project, highlighted when it is CURRENT, and
its parent todo, if any, before its text."
  (let (subtrees)
    (dolist (card cards)
      (let ((id (plist-get card :id))
            (file (plist-get card :file)))
        (pcase-dolist (`(,parent . ,items) (car (iuiw-workspace--todo-take-now (plist-get card :todos))))
          (push (cons (list (car (car items)) (nth 1 (car items)) 0 file id
                            (and parent
                                 (propertize (concat (substring-no-properties
                                                      (iuiw-workspace--todo-display parent))
                                                     " › ")
                                             'face 'shadow))
                            (propertize (concat "  " id)
                                        'face (if (equal id current) 'overlook-heading-current 'shadow)))
                      (mapcar (lambda (item) (append item (list file id))) (cdr items)))
                subtrees))))
    (apply #'append
           (seq-sort-by (lambda (subtree)
                          (let ((text (car (car subtree))))
                            (concat (if (equal (nth 4 (car subtree)) current) "0" "1")
                                    (if (string-match "\\[due:: *\\([0-9-]+\\)\\]" text)
                                        (match-string 1 text)
                                      "~"))))
                        #'string<
                        (nreverse subtrees)))))

(defun iuiw-workspace--todo-visit (perspective file line)
  "Return a command that opens FILE at LINE in the main window.
It first switches to PERSPECTIVE, creating it if needed, when non-nil."
  (lambda ()
    (overlook-show-elsewhere perspective
                             (lambda ()
                               (find-file file)
                               (goto-char (point-min))
                               (forward-line (1- line))))))

(defun iuiw-workspace--insert-groups (groups mark)
  "Insert GROUPS separated by blank lines, each item led by MARK of its text.
Each group is (NAME FILE CURRENT ITEMS PERSPECTIVE COUNT FOLDED): a heading
NAME followed by the string COUNT, if any, that visits FILE, if any,
highlighted when CURRENT, then ITEMS, folded until toggled when FOLDED, as
\(TEXT LINE DEPTH), deeper ones under the item before them.  Visiting switches to
PERSPECTIVE first when it is non-nil.  An item can be (TEXT LINE DEPTH
FILE PERSPECTIVE BEFORE AFTER) instead, visiting its own FILE and showing
the strings BEFORE and AFTER around its text.  Return the last group's
section."
  (let ((previous nil))
    (pcase-dolist (`(,name ,file ,current ,items ,perspective ,count ,folded) groups)
      (when previous (overlook-end-with-blank previous))
      (cl-labels ((insert-items (items)
                    (while items
                      (pcase-let* ((`(,text ,line ,depth ,item-file ,item-perspective ,before ,after)
                                    (pop items))
                                   (children (seq-take-while (lambda (child) (> (nth 2 child) depth))
                                                             items))
                                   (indent (make-string depth ?\s)))
                        (setq items (nthcdr (length children) items))
                        ;; ◷、☐ 在等宽字体里都占两列，折行接在它们后面。
                        (overlook-insert-row
                         (propertize (concat indent (funcall mark text) " "
                                             before (iuiw-workspace--todo-display text) after "\n")
                                     'overlook-action (iuiw-workspace--todo-visit
                                                       (or item-perspective perspective)
                                                       (or item-file file)
                                                       line)
                                     'wrap-prefix (concat indent "   "))
                         (and children (lambda () (insert-items children))))))))
        (setq previous (overlook-insert-row
                        (concat (propertize name
                                            'face (if current 'overlook-heading-current 'overlook-heading)
                                            'overlook-heading t
                                            'overlook-item (list 'todo-group name)
                                            'overlook-action (and file (iuiw-workspace--todo-visit
                                                                        perspective file 1)))
                                (if count (propertize (concat " " count) 'face 'shadow) "")
                                "\n")
                        (lambda () (insert-items items))
                        folded))))
    previous))

(defun iuiw-workspace--todo-ordered (cards)
  "CARDS with todos, those with a perspective first in the dashboard's order."
  (let ((order (overlook-ordered-perspectives)))
    (seq-sort-by (lambda (card) (or (seq-position order (plist-get card :id)) (length order)))
                 #'<
                 (seq-filter (lambda (card) (plist-get card :todos)) cards))))

(defun iuiw-workspace--todo-groups (cards current)
  "Groups for `iuiw-workspace--insert-groups' of CARDS, highlighting CURRENT.
Each counts the card's open #now, #waiting and top-level todos and lists
them folded, leaving out #now todos."
  (delq nil
        (mapcar (lambda (card)
                  (when-let* ((todos (plist-get card :todos)))
                    (list (plist-get card :id) (plist-get card :file)
                          (equal (plist-get card :id) current)
                          (iuiw-workspace--todo-sort (cdr (iuiw-workspace--todo-take-now todos)))
                          (plist-get card :id)
                          (let* ((top (apply #'min (mapcar (lambda (todo) (nth 2 todo)) todos)))
                                 (rank (lambda (n) (seq-count (lambda (todo) (= (iuiw-workspace--todo-rank (car todo)) n))
                                                              todos))))
                            (mapconcat #'identity
                                       (delq nil (list (and (> (funcall rank 0) 0) (format "☐%d" (funcall rank 0)))
                                                       (and (> (funcall rank 1) 0) (format "◷%d" (funcall rank 1)))
                                                       (number-to-string
                                                        (seq-count (lambda (todo) (= (nth 2 todo) top)) todos))))
                                       " "))
                          t)))
                cards)))

(defun iuiw-workspace--todo-section ()
  "Insert a Todo section with every ongoing project's open todos.
The #now todos of all of them come first, in a \"#now\" group.  Projects
with status later go last, under a folded \"later projects\" line."
  (let ((current (overlook-current-perspective)))
    (overlook-insert-section
     "Todo"
     (lambda ()
       (let* ((cards (iuiw-workspace--todo-ordered (iuiw-workspace--todo-cards)))
              (later-p (lambda (card) (equal (plist-get card :status) "later")))
              (now (iuiw-workspace--todo-now-items cards current))
              (later (iuiw-workspace--todo-groups (seq-filter later-p cards) current))
              (last (iuiw-workspace--insert-groups
                     (append (and now (list (list "#now" nil nil now nil nil)))
                             (iuiw-workspace--todo-groups (seq-remove later-p cards) current))
                     #'iuiw-workspace--todo-mark)))
         (when later
           (when last (overlook-end-with-blank last))
           (overlook-insert-row
            (propertize (format "later projects (%d)\n" (length later))
                        'face 'shadow
                        'overlook-item '(todo-later))
            (lambda () (iuiw-workspace--insert-groups later #'iuiw-workspace--todo-mark))
            t)))))))

;;; Dashboard inbox

(defun iuiw-workspace--inbox-workspace (file)
  "Name of the workspace holding inbox FILE."
  (file-name-nondirectory (directory-file-name (file-name-directory file))))

(defun iuiw-workspace--inbox-items (file)
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

(defun iuiw-workspace--inbox-section ()
  "Insert an Inbox section with each workspace's open inbox items.
Only the inbox of `iuiw-workspace-filter' shows when it is set.  The
workspace of the current perspective comes first."
  (let* ((current (iuiw-workspace-perspective-workspace (or (overlook-current-perspective) "")))
         (files (seq-filter (lambda (file) (or (null iuiw-workspace-filter)
                                               (equal iuiw-workspace-filter (iuiw-workspace--inbox-workspace file))))
                            (file-expand-wildcards (expand-file-name "*/inbox.md" (iuiw-workspace--base)))))
         (mine (lambda (file) (equal (iuiw-workspace--inbox-workspace file) current)))
         (files (append (seq-filter mine files) (seq-remove mine files))))
    (overlook-insert-section
     "Inbox"
     (lambda ()
       (iuiw-workspace--insert-groups
        (seq-keep (lambda (file)
                    (when-let* ((items (iuiw-workspace--inbox-items file)))
                      (list (iuiw-workspace--inbox-workspace file) file nil items)))
                  files)
        (lambda (_) (propertize "☐" 'face 'shadow)))))))

(defun iuiw-workspace--mode-line ()
  "`iuiw-workspace-filter' for the dashboard's mode line, or nil when unset."
  (and iuiw-workspace-filter (propertize iuiw-workspace-filter 'face 'warning)))

(defun iuiw-workspace--refresh-after-save ()
  "Re-render the dashboard after saving a project.md or inbox.md."
  (when (and buffer-file-name
             (fboundp 'overlook-refresh)
             (pcase (file-name-nondirectory buffer-file-name)
               ("project.md" (iuiw-workspace-project-root))
               ("inbox.md" (file-in-directory-p buffer-file-name iuiw-workspace-directory))))
    (overlook-refresh)))

;;;###autoload
(define-minor-mode iuiw-workspace-dashboard-mode
  "Show ongoing projects' todos and the inboxes in the agents dashboard."
  :global t
  :group 'iuiw-workspace
  (if iuiw-workspace-dashboard-mode
      (progn
        (add-hook 'overlook-sections #'iuiw-workspace--todo-section 50)
        (add-hook 'overlook-sections #'iuiw-workspace--inbox-section 60)
        (add-hook 'overlook-mode-line-functions #'iuiw-workspace--mode-line -50)
        (add-hook 'after-save-hook #'iuiw-workspace--refresh-after-save))
    (remove-hook 'overlook-sections #'iuiw-workspace--todo-section)
    (remove-hook 'overlook-sections #'iuiw-workspace--inbox-section)
    (remove-hook 'overlook-mode-line-functions #'iuiw-workspace--mode-line)
    (remove-hook 'after-save-hook #'iuiw-workspace--refresh-after-save)))

(provide 'iuiw-workspace)
;;; iuiw-workspace.el ends here
