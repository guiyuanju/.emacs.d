;;; jgy-workspace.el --- Workspaces, projects, perspectives and repos -*- lexical-binding: t; -*-

;;; Commentary:
;; workspace（~/workspace/me、okj…）→ 项目 projects/<id>/（project.md）→ 若干 repo（各一个 git 仓库）；
;; 每个项目对应一个同名 perspective。
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
(declare-function persp-current-name "perspective")
(declare-function persp-current-buffers "perspective")
(declare-function persp-other-buffer "perspective")
(declare-function overlook-refresh "overlook")
(declare-function overlook-insert-section "overlook")
(declare-function overlook-ordered-perspectives "overlook")
(declare-function overlook-current-perspective "overlook")
(declare-function overlook-agent-project-root "overlook-agent")
(declare-function overlook-perspective-guess-root "overlook-perspective")
(defvar overlook-sections)

;;; Projects

(defvar jgy-workspace-code-directory "~/Code/"
  "Directory whose <group>/<repo> Git checkouts are clone sources.")
(defvar jgy-workspace-directory "~/workspace/"
  "Directory containing workspaces, each with a projects/ folder.")

(defun jgy-workspace-project-root (&optional directory)
  "Return the <workspace>/projects/<id>/ folder containing DIRECTORY, or nil.
Symlinks are resolved first, so ~/.emacs.d finds the project it links into."
  (let ((dir (file-name-as-directory (file-truename (or directory default-directory))))
        (base (file-name-as-directory (file-truename jgy-workspace-directory))))
    (when (string-match (concat "\\`" (regexp-quote base) "[^/]+/projects/[^./][^/]*/") dir)
      (let ((root (match-string 0 dir)))
        (and (file-exists-p (expand-file-name "project.md" root)) root)))))

(defun jgy-workspace-project-files (&optional directory)
  "Return every project card under DIRECTORY, defaulting to the workspaces."
  (file-expand-wildcards
   (expand-file-name "*/projects/*/project.md"
                     (or directory jgy-workspace-directory))))

(defun jgy-workspace--projects-by-mtime ()
  "Return the project folders of every workspace, newest first."
  (sort (jgy-workspace-project-files) #'file-newer-than-file-p))

(defun jgy-workspace--read-workspace ()
  "Read a workspace name and return its projects folder."
  (let* ((names (mapcar (lambda (dir) (file-name-nondirectory (directory-file-name
                                                                (file-name-directory dir))))
                        (file-expand-wildcards
                         (expand-file-name "*/projects/" jgy-workspace-directory))))
         (name (if (cdr names)
                   (completing-read "Workspace: " names nil t)
                 (or (car names) (user-error "No workspace under %s" jgy-workspace-directory)))))
    (expand-file-name (concat name "/projects/") jgy-workspace-directory)))

(defun jgy-workspace--create-project (file id title)
  "Create project.md FILE for ID with TITLE."
  (make-directory (file-name-directory file) t)
  ;; overlook-markers 据此把项目文件夹连同其中所有 clone 当作一个 project。
  (write-region "" nil (expand-file-name ".overlook" (file-name-directory file)))
  (with-temp-file file
    (insert (format "---\nid: %s\ntitle: %s\nstatus: active\nstart: %s\nend:\n---\n\n"
                    id title (format-time-string "%F"))
            "## 目标\n\n## Todo\n\n## 资源\n\n## 成果\n\n## 日志\n")))

(defun jgy-workspace-open-project (id)
  "Switch to the perspective of project ID, creating the project when it is new.
A new perspective opens project.md; an existing one keeps its windows."
  (interactive (list (string-trim
                      (completing-read "Project: "
                                       (mapcar (lambda (file) (file-name-nondirectory
                                                               (directory-file-name
                                                                (file-name-directory file))))
                                               (jgy-workspace--projects-by-mtime))))))
  (when (string-empty-p id) (user-error "Project id cannot be empty"))
  (let ((file (or (seq-find (lambda (file) (string-suffix-p (concat "/" id "/project.md") file))
                            (jgy-workspace--projects-by-mtime))
                  (expand-file-name (concat id "/project.md") (jgy-workspace--read-workspace)))))
    (unless (file-exists-p file)
      (jgy-workspace--create-project file id (read-string "Title: ")))
    (let ((new (not (member id (persp-names)))))
      (persp-switch id)
      (when new (find-file file)))))

(defun jgy-workspace-visit-project-md ()
  "Open the project.md of the current project folder."
  (interactive)
  (find-file (expand-file-name "project.md" (or (jgy-workspace-project-root)
                                                (user-error "Not inside a project folder")))))

(defun jgy-workspace-clone-repo (repo)
  "Clone the origin of REPO into the current project.
REPO is a <group>/<repo> checkout under `jgy-workspace-code-directory'."
  (interactive
   (list (completing-read
          "Repository: "
          (mapcar (lambda (git) (file-relative-name (directory-file-name (file-name-directory git))
                                                    (expand-file-name jgy-workspace-code-directory)))
                  (file-expand-wildcards (expand-file-name "*/*/.git" jgy-workspace-code-directory)))
          nil t)))
  (let* ((root (or (jgy-workspace-project-root) (user-error "Not inside a project folder")))
         (target (expand-file-name (file-name-nondirectory (directory-file-name repo)) root))
         (url (car (process-lines "git" "-C" (expand-file-name repo jgy-workspace-code-directory)
                                  "remote" "get-url" "origin"))))
    (when (file-exists-p target) (user-error "%s already exists" target))
    (require 'magit-clone)
    (magit-clone-regular url target nil)))

;;; Perspective buffer history

;; frame 的 buffer-list 是全局的使用顺序，跨 perspective 共享的 buffer 会被别处的使用顶到前面；
;; 所以每个 perspective 自己记录 buffer 的使用顺序。
(defvar jgy-persp-history (make-hash-table :test #'equal)
  "Perspective name to its buffers, most recently selected first.")

(defun jgy-persp-record (&rest _)
  "Move the selected window's buffer to the front of this perspective's history."
  (when (bound-and-true-p persp-mode)
    (let ((buffer (window-buffer (selected-window)))
          (name (persp-current-name)))
      (unless (or (minibufferp buffer) (string-prefix-p " " (buffer-name buffer)))
        (puthash name (cons buffer (seq-filter (lambda (b) (and (buffer-live-p b) (not (eq b buffer))))
                                               (gethash name jgy-persp-history)))
                 jgy-persp-history)))))

(defun jgy-last-buffer ()
  "Switch to the most recently used other buffer of this perspective."
  (interactive)
  (let ((buffers (persp-current-buffers)))
    (switch-to-buffer
     (or (seq-find (lambda (b) (and (buffer-live-p b) (not (eq b (current-buffer))) (memq b buffers)))
                   (gethash (persp-current-name) jgy-persp-history))
         (persp-other-buffer (current-buffer))))))

;;; Overlook

(defun jgy-workspace-project-dir (id)
  "Folder of project ID, or nil."
  (when-let* ((card (seq-find (lambda (file) (string-suffix-p (concat "/" id "/project.md") file))
                              (jgy-workspace-project-files))))
    (file-name-directory card)))

(defun jgy-workspace-agent-root ()
  "Return the project folder when inside one, else the version-control root."
  (or (jgy-workspace-project-root) (overlook-agent-project-root)))

(defun jgy-workspace-perspective-root (name)
  "Root of perspective NAME: the project folder of that id, else a guess."
  (or (jgy-workspace-project-dir name) (overlook-perspective-guess-root name)))

(defun jgy-workspace-perspective-workspace (name)
  "Name of the workspace holding project NAME, or nil."
  (when-let* ((dir (jgy-workspace-project-dir name)))
    (file-name-nondirectory (directory-file-name (file-name-parent-directory
                                                  (file-name-parent-directory dir))))))

;;; Dashboard todos

(defvar jgy-workspace--todo-cache nil
  "Parsed cards, as (STAMP . CARDS); STAMP lists each card's file and mtime.")

(defun jgy-workspace--todo-parse (file)
  "Parse card FILE into a plist of :id :status :file :todos.
Each todo is (TEXT LINE DEPTH) for an open checkbox under the Todo heading,
or anywhere when tagged #waiting; DEPTH is its indent in columns."
  (with-temp-buffer
    (insert-file-contents file)
    (let (id status todos in-todo)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties (point) (line-end-position))))
          (cond
           ((string-match "\\`id: *\\(.+\\)" line) (setq id (string-trim (match-string 1 line))))
           ((string-match "\\`status: *\\([a-z]+\\)" line) (setq status (match-string 1 line)))
           ((string-prefix-p "## " line) (setq in-todo (string= line "## Todo")))
           ((and (string-match "\\`\\( *\\)- \\[ \\] \\(.+\\)" line)
                 (or in-todo (string-match-p "#waiting\\>" line)))
            (push (list (match-string 2 line) (line-number-at-pos) (length (match-string 1 line)))
                  todos))))
        (forward-line 1))
      (list :id id :status status :file file :todos (nreverse todos)))))

(defun jgy-workspace--todo-cards ()
  "Return parsed active cards, re-reading only when a card file changed."
  (let* ((files (jgy-workspace-project-files))
         (stamp (mapcar (lambda (file)
                          (cons file (file-attribute-modification-time (file-attributes file))))
                        files)))
    (unless (equal stamp (car jgy-workspace--todo-cache))
      (setq jgy-workspace--todo-cache (cons stamp (mapcar #'jgy-workspace--todo-parse files))))
    (seq-filter (lambda (card) (member (plist-get card :status) '("active" "waiting")))
                (cdr jgy-workspace--todo-cache))))

(defun jgy-workspace--todo-rank (text)
  "0 for a #now todo TEXT, 1 for #waiting, 2 for the rest.
Tags inside `code' do not count."
  (let ((text (replace-regexp-in-string "`[^`]*`" "" text)))
    (cond ((string-match-p "#now\\>" text) 0)
          ((string-match-p "#waiting\\>" text) 1)
          (t 2))))

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
    (when (window-parameter (selected-window) 'window-side)
      (select-window (get-mru-window nil nil t)))
    (find-file file)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun jgy-workspace--todo-insert-card (card current)
  "Insert a heading for CARD followed by its todos; CURRENT highlights the heading."
  (insert (propertize (plist-get card :id)
                      'face (if current 'overlook-heading-current 'overlook-heading)
                      'overlook-heading t
                      'overlook-action (jgy-workspace--todo-visit (plist-get card :file) 1))
          "\n")
  (pcase-dolist (`(,text ,line ,depth) (jgy-workspace--todo-sort (plist-get card :todos)))
    (let ((indent (make-string (+ 3 depth) ?\s))
          (mark (pcase (jgy-workspace--todo-rank text) (0 "→") (1 "◷") (_ "☐"))))
      ;; →、◷、☐ 在等宽字体里都占两列，折行接在它们后面。
      (insert (propertize (concat indent (propertize mark 'face 'shadow) " "
                                  (jgy-workspace--todo-display text))
                          'overlook-action (jgy-workspace--todo-visit (plist-get card :file) line)
                          'wrap-prefix (concat indent "   "))
              "\n"))))

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
       (let ((first t))
         (dolist (card (jgy-workspace--todo-ordered (jgy-workspace--todo-cards)))
           (unless first (insert "\n"))
           (setq first nil)
           (jgy-workspace--todo-insert-card card (equal (plist-get card :id) current))))))))

;;; Dashboard inbox

(defun jgy-workspace--inbox-workspace (file)
  "Name of the workspace holding inbox FILE."
  (file-name-nondirectory (directory-file-name (file-name-directory file))))

(defun jgy-workspace--inbox-items (file)
  "Open items of inbox FILE, as (TEXT LINE DEPTH) like todos."
  (with-temp-buffer
    (insert-file-contents file)
    (let (items)
      (while (re-search-forward "^\\( *\\)- \\(?:\\[ \\] \\)?\\(.+\\)" nil t)
        (unless (string-prefix-p "[x] " (match-string 2))
          (push (list (match-string 2) (line-number-at-pos) (length (match-string 1))) items)))
      (nreverse items))))

(defun jgy-workspace--inbox-section ()
  "Insert an Inbox section with each workspace's open inbox items.
The workspace of the current perspective comes first."
  (let* ((current (jgy-workspace-perspective-workspace (or (overlook-current-perspective) "")))
         (files (file-expand-wildcards (expand-file-name "*/inbox.md" jgy-workspace-directory)))
         (mine (lambda (file) (equal (jgy-workspace--inbox-workspace file) current)))
         (files (append (seq-filter mine files) (seq-remove mine files))))
    (overlook-insert-section
     "Inbox"
     (lambda ()
       (let ((first t))
         (dolist (file files)
           (when-let* ((items (jgy-workspace--inbox-items file)))
             (unless first (insert "\n"))
             (setq first nil)
             (insert (propertize (jgy-workspace--inbox-workspace file)
                                 'face 'overlook-heading
                                 'overlook-heading t
                                 'overlook-action (jgy-workspace--todo-visit file 1))
                     "\n")
             (pcase-dolist (`(,text ,line ,depth) items)
               (let ((indent (make-string (+ 3 depth) ?\s)))
                 (insert (propertize (concat indent (propertize "☐" 'face 'shadow) " "
                                             (jgy-workspace--todo-display text))
                                     'overlook-action (jgy-workspace--todo-visit file line)
                                     'wrap-prefix (concat indent "   "))
                         "\n"))))))))))

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
  :group 'overlook
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
