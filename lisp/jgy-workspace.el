;;; jgy-workspace.el --- Workspaces, projects, perspectives and repos -*- lexical-binding: t; -*-

;;; Commentary:
;; workspace（~/workspace/me、okj…）→ 项目 projects/<id>/（project.md）→ 若干 repo（各一个 git 仓库）；
;; 每个项目对应一个同名 perspective，项目 id 即文件夹名。
;; 位置固定的 repo（如 ~/.emacs.d）不搬进项目文件夹，用 `jgy-workspace-project-roots' 指过去：
;; project.md 仍在 workspace，看板、agent 以那个目录为项目根。
;; 也给 overlook 提供项目根，并在看板底部列出所有进行中项目的待办：
;; Todo 段的未完成项（含缩进的子项），加上任意段落里带 #waiting 的未完成项。

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)

(declare-function magit-clone-regular "magit-clone")
(declare-function persp-names "perspective")
(declare-function persp-switch "perspective")
(declare-function overlook-refresh "overlook")
(declare-function overlook-insert-section "overlook")
(declare-function overlook-ordered-perspectives "overlook")
(declare-function overlook-current-perspective "overlook")
(declare-function overlook-main-window "overlook")
(declare-function overlook-agent-project-root "overlook-agent")
(declare-function overlook-perspective-guess-root "overlook-perspective")
(defvar overlook-sections)

(defgroup jgy-workspace nil
  "Project folders under ~/workspace."
  :group 'convenience)

(defcustom jgy-workspace-directory "~/workspace/"
  "Directory containing workspaces, each with a projects/ folder."
  :type 'directory
  :group 'jgy-workspace)

(defcustom jgy-workspace-code-directories '("~/Code/*/")
  "Directories whose Git checkouts are clone sources; wildcards allowed."
  :type '(repeat directory)
  :group 'jgy-workspace)

(defcustom jgy-workspace-project-roots nil
  "Alist of project id to its root outside the workspaces.
The project's card stays in its workspace folder; the dashboard lists
the repos of the root, and agents started in the card folder run there."
  :type '(alist :key-type string :value-type directory)
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
                                                                (file-name-directory dir))))
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

(defun jgy-workspace-open-project (id)
  "Switch to the perspective of project ID, creating the project when it is new.
A new perspective opens project.md; an existing one keeps its windows."
  (interactive (list (string-trim
                      (completing-read "Project: " (mapcar #'jgy-workspace--file-id
                                                           (jgy-workspace--projects-by-mtime))))))
  (let ((file (cdr (assoc id (jgy-workspace--projects)))))
    (unless file
      (jgy-workspace--check-new-id id)
      (jgy-workspace--template)
      (setq file (expand-file-name (concat id "/project.md") (jgy-workspace--read-workspace)))
      (jgy-workspace--create-project file id (read-string "Title: ")))
    (let ((new (not (member id (persp-names)))))
      (persp-switch id)
      (when new (find-file file)))))

(defun jgy-workspace-visit-project-md ()
  "Open the project.md of the current project folder or root."
  (interactive)
  (find-file (expand-file-name "project.md"
                               (or (jgy-workspace-project-root)
                                   (when-let* ((id (jgy-workspace--root-id)))
                                     (jgy-workspace-project-dir id))
                                   (user-error "Not inside a project folder")))))

(defun jgy-workspace--clone-sources ()
  "Checkouts under `jgy-workspace-code-directories'."
  (mapcan (lambda (dir)
            (mapcar (lambda (git) (abbreviate-file-name (file-name-directory git)))
                    (file-expand-wildcards (expand-file-name "*/.git" dir))))
          jgy-workspace-code-directories))

(defun jgy-workspace-clone-repo (repo)
  "Clone the origin of REPO into the current project.
REPO is a checkout directory under `jgy-workspace-code-directories'."
  (interactive
   (list (completing-read "Repository: " (jgy-workspace--clone-sources) nil t)))
  (let* ((root (or (jgy-workspace-project-root) (user-error "Not inside a project folder")))
         (target (expand-file-name (file-name-nondirectory (directory-file-name repo)) root))
         (url (car (process-lines "git" "-C" (expand-file-name repo) "remote" "get-url" "origin"))))
    (when (file-exists-p target) (user-error "%s already exists" target))
    (require 'magit-clone)
    (magit-clone-regular url target nil)))

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
    (seq-filter (lambda (card) (member (plist-get card :status) '("active" "waiting")))
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
  "Bullet of todo TEXT by its rank."
  (pcase (jgy-workspace--todo-rank text) (0 "→") (1 "◷") (_ "☐")))

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

(defun jgy-workspace--todo-visit (file line)
  "Return a command that opens FILE at LINE in the main window."
  (lambda ()
    (overlook-main-window)
    (find-file file)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun jgy-workspace--insert-groups (groups mark)
  "Insert GROUPS separated by blank lines, each item led by MARK of its text.
Each group is (NAME FILE CURRENT ITEMS): a heading NAME that visits FILE,
highlighted when CURRENT, then ITEMS as (TEXT LINE DEPTH)."
  (let ((first t))
    (pcase-dolist (`(,name ,file ,current ,items) groups)
      (unless first (insert "\n"))
      (setq first nil)
      (insert (propertize name
                          'face (if current 'overlook-heading-current 'overlook-heading)
                          'overlook-heading t
                          'overlook-action (jgy-workspace--todo-visit file 1))
              "\n")
      (pcase-dolist (`(,text ,line ,depth) items)
        (let ((indent (make-string (+ 3 depth) ?\s)))
          ;; →、◷、☐ 在等宽字体里都占两列，折行接在它们后面。
          (insert (propertize (concat indent (propertize (funcall mark text) 'face 'shadow) " "
                                      (jgy-workspace--todo-display text))
                              'overlook-action (jgy-workspace--todo-visit file line)
                              'wrap-prefix (concat indent "   "))
                  "\n"))))))

(defun jgy-workspace--todo-ordered (cards)
  "CARDS with todos, those with a perspective first in the dashboard's order."
  (let ((order (overlook-ordered-perspectives)))
    (seq-sort-by (lambda (card) (or (seq-position order (plist-get card :id)) (length order)))
                 #'<
                 (seq-filter (lambda (card) (plist-get card :todos)) cards))))

(defun jgy-workspace--todo-section ()
  "Insert a Todo section with every ongoing project's open todos."
  (let ((current (overlook-current-perspective)))
    (overlook-insert-section
     "Todo"
     (lambda ()
       (jgy-workspace--insert-groups
        (mapcar (lambda (card)
                  (list (plist-get card :id) (plist-get card :file)
                        (equal (plist-get card :id) current)
                        (jgy-workspace--todo-sort (plist-get card :todos))))
                (jgy-workspace--todo-ordered (jgy-workspace--todo-cards)))
        #'jgy-workspace--todo-mark)))))

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
        (lambda (_) "☐"))))))

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
