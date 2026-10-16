;;; jgy-workspace-test.el --- Workspace project checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'jgy-workspace)

(defvar persp-mode)

(defmacro jgy-workspace-test--with-workspace (&rest body)
  "Run BODY with `jgy-workspace-directory' bound to a fresh temporary folder."
  (declare (indent 0))
  `(let* ((jgy-workspace-directory (file-name-as-directory (make-temp-file "jgy-ws" t)))
          (jgy-workspace-project-roots nil)
          (jgy-workspace--cache nil))
     (unwind-protect (progn ,@body)
       (delete-directory jgy-workspace-directory t))))

(defun jgy-workspace-test--write (path text)
  "Write TEXT to PATH under the workspace, creating folders; return the file."
  (let ((file (expand-file-name path jgy-workspace-directory)))
    (make-directory (file-name-directory file) t)
    (write-region text nil file nil 'silent)
    file))

(defconst jgy-workspace-test--card
  "---
title: Demo
status: active
---

## Todo
- [ ] first
  - [ ] child
- [x] done
```
- [ ] fenced
## Not a heading
```
- [ ] after fence

## 日志
status: done
- [ ] plain log item
- [ ] ask ops #waiting
")

(ert-deftest jgy-workspace-todo-parse ()
  (jgy-workspace-test--with-workspace
    (let* ((file (jgy-workspace-test--write "me/projects/demo/project.md" jgy-workspace-test--card))
           (card (jgy-workspace--todo-parse file)))
      ;; 没有 id 字段时用文件夹名；日志里的 status: done 不算。
      (should (equal (plist-get card :id) "demo"))
      (should (equal (plist-get card :status) "active"))
      (should (equal (plist-get card :todos)
                     '(("first" 7 0) ("child" 8 2) ("after fence" 14 0) ("ask ops #waiting" 19 0))))
      (should (equal (mapcar (lambda (c) (plist-get c :id)) (jgy-workspace--todo-cards)) '("demo"))))))

(ert-deftest jgy-workspace-todo-parse-without-front-matter ()
  (jgy-workspace-test--with-workspace
    (let ((card (jgy-workspace--todo-parse
                 (jgy-workspace-test--write "me/projects/bare/project.md"
                                            "id: other\nstatus: active\n## Todo\n- [ ] x\n"))))
      (should (equal (plist-get card :id) "bare"))
      (should-not (plist-get card :status))
      (should (equal (plist-get card :todos) '(("x" 4 0)))))))

(ert-deftest jgy-workspace-todo-section-renders ()
  (jgy-workspace-test--with-workspace
    (jgy-workspace-test--write "me/projects/demo/project.md" jgy-workspace-test--card)
    (jgy-workspace-test--write "me/inbox.md" "- [ ] call\n")
    (cl-letf (((symbol-function 'overlook-insert-section) (lambda (_title body) (funcall body)))
              ((symbol-function 'overlook-ordered-perspectives) (lambda () '("demo")))
              ((symbol-function 'overlook-current-perspective) (lambda () "demo")))
      (with-temp-buffer
        (jgy-workspace--todo-section)
        (jgy-workspace--inbox-section)
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       (concat "demo\n   ◷ ask ops\n   ☐ first\n     ☐ child\n   ☐ after fence\n"
                               "me\n   ☐ call\n")))
        (goto-char (point-min))
        (should (eq (get-text-property (point) 'face) 'overlook-heading-current))))))

(ert-deftest jgy-workspace-todo-sort ()
  (should (equal (mapcar #'car (jgy-workspace--todo-sort
                                '(("a" 1 0) ("a1" 2 2) ("b" 3 0) ("b1" 4 2) ("b2 #now" 5 2)
                                  ("c #waiting" 6 0))))
                 '("b" "b2 #now" "b1" "c #waiting" "a" "a1"))))

(ert-deftest jgy-workspace-project-root ()
  (jgy-workspace-test--with-workspace
    (jgy-workspace-test--write "me/projects/demo/project.md" "")
    (jgy-workspace-test--write "me/projects/.hidden/project.md" "")
    (make-directory (expand-file-name "me/projects/empty/" jgy-workspace-directory) t)
    (make-directory (expand-file-name "me/projects/demo/repo/src/" jgy-workspace-directory) t)
    (let ((demo (file-truename (expand-file-name "me/projects/demo/" jgy-workspace-directory))))
      (should (equal (jgy-workspace-project-root
                      (expand-file-name "me/projects/demo/repo/src/" jgy-workspace-directory))
                     demo))
      (should-not (jgy-workspace-project-root (expand-file-name "me/projects/empty/" jgy-workspace-directory)))
      (should-not (jgy-workspace-project-root (expand-file-name "me/projects/.hidden/" jgy-workspace-directory)))
      (should (equal (mapcar #'car (jgy-workspace--projects)) '("demo")))
      ;; 新项目要能在缓存之后被找到。
      (jgy-workspace-test--write "me/projects/later/project.md" "")
      (should (jgy-workspace-project-dir "later")))))

(ert-deftest jgy-workspace-agent-and-perspective-roots-agree ()
  (jgy-workspace-test--with-workspace
    (jgy-workspace-test--write "me/projects/demo/project.md" "")
    (jgy-workspace-test--write "me/projects/mapped/project.md" "")
    (let* ((outside (make-temp-file "jgy-root" t))
           (jgy-workspace-project-roots `(("mapped" . ,outside))))
      (unwind-protect
          (dolist (id '("demo" "mapped"))
            (let ((default-directory (expand-file-name (concat "me/projects/" id "/")
                                                       jgy-workspace-directory)))
              (should (equal (jgy-workspace-agent-root) (jgy-workspace-perspective-root id)))))
        (delete-directory outside t))
      (should (equal (jgy-workspace-perspective-root "mapped")
                     (file-name-as-directory (file-truename outside))))
      (should (equal (jgy-workspace-perspective-workspace "demo") "me")))))

(ert-deftest jgy-workspace-inbox-items ()
  (jgy-workspace-test--with-workspace
    (should (equal (jgy-workspace--inbox-items
                    (jgy-workspace-test--write "me/inbox.md"
                                               (concat "# Inbox\n- [ ] open\n- [x] done\n  - under done\n"
                                                       "- [X] DONE\n  - [ ] also under\n- plain\n  - [ ] sub\n")))
                   '(("open" 2 0) ("plain" 7 0) ("sub" 8 2))))))

(ert-deftest jgy-workspace-create-project-from-template ()
  (jgy-workspace-test--with-workspace
    (let ((file (expand-file-name "me/projects/new-1/project.md" jgy-workspace-directory)))
      (should-error (jgy-workspace--create-project file "new-1" "T") :type 'user-error)
      (should-not (file-exists-p file))
      (jgy-workspace-test--write "project-template.md" "id: {{id}}\ntitle: {{title}}\nstart: {{date}}\n")
      (jgy-workspace--create-project file "new-1" "A {{id}} title")
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                     (format "id: new-1\ntitle: A {{id}} title\nstart: %s\n" (format-time-string "%F"))))
      (should (file-exists-p (expand-file-name "me/projects/new-1/.overlook" jgy-workspace-directory))))))

(ert-deftest jgy-workspace-new-project-id ()
  (jgy-workspace-test--with-workspace
    (jgy-workspace-test--write "project-template.md" "")
    (cl-letf (((symbol-function 'persp-names) (lambda () '("main")))
              ((symbol-function 'persp-switch) #'ignore))
      (let ((persp-mode t))
        (dolist (id '("" "Bad" "a_b" "-x" "a b" "main"))
          (should-error (jgy-workspace-open-project id) :type 'user-error))
        (jgy-workspace--check-new-id "ool-123"))
      (should-not (file-exists-p (expand-file-name "me" jgy-workspace-directory))))))

;; 新项目建在所选 workspace，候选取该 workspace 的 .remotes，克隆在切到 perspective 之后。
(ert-deftest jgy-workspace-new-project ()
  (jgy-workspace-test--with-workspace
    (jgy-workspace-test--write "project-template.md" "---\nid: {{id}}\n---\n")
    (jgy-workspace-test--write "me/projects/.keep" "")
    (jgy-workspace-test--write "okj/projects/.keep" "")
    (let ((candidates '(("g/svc" "svc" "git@host:g/svc.git" "Service")))
          events)
      (cl-letf (((symbol-function 'persp-names) (lambda () '("main")))
                ((symbol-function 'persp-switch) (lambda (name) (push (list 'switch name) events)))
                ((symbol-function 'find-file) (lambda (file) (push (list 'find file) events)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt names &rest _)
                   (should (equal (sort (copy-sequence names) #'string<) '("me" "okj")))
                   "okj"))
                ((symbol-function 'read-string) (lambda (&rest _) "T"))
                ((symbol-function 'jgy-workspace--clone-candidates)
                 (lambda (root)
                   (should (equal root (expand-file-name "okj/projects/svc-fix/" (jgy-workspace--base))))
                   candidates))
                ((symbol-function 'completing-read-multiple)
                 (lambda (_prompt names _pred match &rest _)
                   (should (equal names candidates))
                   (should (equal (funcall (plist-get completion-extra-properties :annotation-function)
                                           "g/svc")
                                  "  Service"))
                   (should (funcall match ""))
                   (should (funcall match "g/svc"))
                   (should-not (funcall match "g/svc,nope"))
                   '("g/svc")))
                ((symbol-function 'jgy-workspace--clone-entries)
                 (lambda (root entries register)
                   (should register)
                   (push (list 'clone entries root) events))))
        (jgy-workspace-new-project "svc-fix")
        (let* ((root (expand-file-name "okj/projects/svc-fix/" (jgy-workspace--base)))
               (file (expand-file-name "project.md" root)))
          (should (equal (nreverse events)
                         `((switch "svc-fix") (find ,file)
                           (clone (((path . "svc") (url . "git@host:g/svc.git"))) ,root))))
          (should-error (jgy-workspace-new-project "svc-fix") :type 'user-error)
          (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer)))))))

;; 没有 .remotes 时新项目照建，只跳过 clone。
(ert-deftest jgy-workspace-new-project-without-remotes ()
  (jgy-workspace-test--with-workspace
    (jgy-workspace-test--write "project-template.md" "---\nid: {{id}}\n---\n")
    (jgy-workspace-test--write "me/projects/.keep" "")
    (let (switched)
      (cl-letf (((symbol-function 'persp-names) (lambda () '("main")))
                ((symbol-function 'persp-switch) (lambda (name) (setq switched name)))
                ((symbol-function 'find-file) #'ignore)
                ((symbol-function 'read-string) (lambda (&rest _) "T"))
                ((symbol-function 'completing-read-multiple)
                 (lambda (&rest _) (error "Should not ask for repositories"))))
        (jgy-workspace-new-project "solo")
        (should (equal switched "solo"))
        (should (file-exists-p (expand-file-name "me/projects/solo/project.md"
                                                 jgy-workspace-directory)))))))

;; 候选合并 .remotes 各行，按协议取 URL，去掉已存在或已登记的路径。
(ert-deftest jgy-workspace-clone-candidates ()
  (jgy-workspace-test--with-workspace
    (jgy-workspace-test--write "me/.remotes" "# comment\ngithub owner\n\ngitlab git.example.com  # company\n")
    (let* ((file (jgy-workspace-test--write
                  "me/projects/demo/project.md"
                  "---\nrepos: [\n  {\"path\": \"registered\", \"url\": \"u\"}\n  ]\n---\n"))
           (root (file-name-directory file))
           calls)
      (make-directory (expand-file-name "present" root))
      (should (equal (jgy-workspace--remotes root)
                     '(("github" "owner") ("gitlab" "git.example.com"))))
      (cl-letf (((symbol-function 'jgy-workspace--cli-output)
                 (lambda (program &rest args)
                   (push (cons program args) calls)
                   (pcase (list program (car args))
                     ('("gh" "config") "https\n")
                     ('("glab" "config") "ssh\n")
                     ('("gh" "repo")
                      "[{\"nameWithOwner\":\"owner/app\",\"url\":\"https://github.com/owner/app\",\"sshUrl\":\"git@github.com:owner/app.git\",\"description\":\"App\"},
                        {\"nameWithOwner\":\"owner/present\",\"url\":\"https://github.com/owner/present\",\"sshUrl\":\"s\",\"description\":\"\"}]")
                     ('("glab" "api")
                      "[{\"path_with_namespace\":\"g/sub/svc\",\"path\":\"svc\",\"ssh_url_to_repo\":\"git@git.example.com:g/sub/svc.git\",\"http_url_to_repo\":\"h\",\"description\":null}]
[{\"path_with_namespace\":\"g/registered\",\"path\":\"registered\",\"ssh_url_to_repo\":\"r\",\"http_url_to_repo\":\"h\",\"description\":null}]")))))
        (should (equal (jgy-workspace--clone-candidates root)
                       '(("owner/app" "app" "https://github.com/owner/app.git" "App")
                         ("g/sub/svc" "svc" "git@git.example.com:g/sub/svc.git" nil))))
        (should (member '("gh" "repo" "list" "owner" "--no-archived" "--limit" "1000"
                          "--json" "nameWithOwner,url,sshUrl,description")
                        calls)))
      (should-error (jgy-workspace--remotes (expand-file-name "okj/projects/x/" jgy-workspace-directory))
                    :type 'user-error)
      (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer)))))

;; 先按 perspective 找项目，即使当前 buffer 是别的项目的文件；不是项目的 perspective 再按 buffer 所在文件夹和 project-roots。
(ert-deftest jgy-workspace-visit-project-md ()
  (jgy-workspace-test--with-workspace
    (let* ((card (jgy-workspace-test--write "okj/projects/demo/project.md" ""))
           (other (jgy-workspace-test--write "okj/projects/other/project.md" ""))
           (emacs (jgy-workspace-test--write "me/projects/emacs/project.md" ""))
           (jgy-workspace-project-roots `(("emacs" . ,temporary-file-directory)))
           (default-directory temporary-file-directory)
           (persp-mode t)
           (name "demo"))
      (cl-letf (((symbol-function 'persp-current-name) (lambda () name))
                ((symbol-function 'find-file) #'identity))
        (should (equal (jgy-workspace-visit-project-md) (file-truename card)))
        (let ((default-directory (file-name-directory other)))
          (should (equal (jgy-workspace-visit-project-md) (file-truename card)))
          (setq name "main")
          (should (equal (jgy-workspace-visit-project-md) (file-truename other))))
        (should (equal (jgy-workspace-visit-project-md) (file-truename emacs)))))))

(ert-deftest jgy-workspace-repos-roundtrip ()
  (jgy-workspace-test--with-workspace
    (let* ((file (jgy-workspace-test--write "me/projects/demo/project.md" jgy-workspace-test--card))
           (root (file-name-directory file))
           (repos '(((path . "app") (url . "ssh://host/a b.git")))))
      (should-not (jgy-workspace--read-repos root))
      (jgy-workspace--write-repos root repos)
      (should (equal (jgy-workspace--read-repos root) repos))
      (jgy-workspace--register-repo root "app" "ssh://host/a b.git")
      (should (equal (jgy-workspace--read-repos root) repos))
      (should-error (jgy-workspace--register-repo root "app" "different") :type 'user-error)
      (with-current-buffer (find-file-noselect file)
        (should (equal (save-excursion
                         (let ((region (jgy-workspace--repos-region)))
                           (concat (buffer-substring-no-properties (point-min) (car region))
                                   (buffer-substring-no-properties (cdr region) (point-max)))))
                       jgy-workspace-test--card))
        (let ((text (buffer-string)))
          (jgy-workspace--write-repos root repos)
          (should (equal text (buffer-string))))
        (goto-char (point-max))
        (insert "unsaved")
        (should-error (jgy-workspace--write-repos root nil) :type 'user-error)
        (should (buffer-modified-p))
        (set-buffer-modified-p nil)
        (kill-buffer)))))

(ert-deftest jgy-workspace-repos-path-validation ()
  (jgy-workspace-test--with-workspace
    (let ((root jgy-workspace-directory))
      (dolist (path '("../outside" "/tmp/outside" "~/.emacs.d" "." "a/../../b" "a/.git" ""))
        (should-error (jgy-workspace--validate-repos `(((path . ,path) (url . "x"))) root)
                      :type 'user-error))
      (should-error (jgy-workspace--validate-repos
                     '(((path . "a") (url . "x")) ((path . "a/b") (url . "y"))) root)
                    :type 'user-error)
      (make-symbolic-link temporary-file-directory (expand-file-name "link" root))
      (should-error (jgy-workspace--validate-repos '(((path . "link/escape") (url . "x"))) root)
                    :type 'user-error))))

(ert-deftest jgy-workspace-repos-malformed ()
  (jgy-workspace-test--with-workspace
    (dolist (value '("null" "{}" "[broken]" "[{\"path\":\"../bad\",\"url\":\"x\"}]"))
      (let* ((file (jgy-workspace-test--write "me/projects/demo/project.md"
                                               (concat "---\nrepos: " value "\n---\n")))
             (root (file-name-directory file)))
        (should-error (jgy-workspace--read-repos root))
        (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer))))))

(ert-deftest jgy-workspace-repos-local-clone ()
  (require 'magit-process)
  ;; Exercise real asynchronous Git: success registers, failure stops the queue,
  ;; existing non-repo directories survive, and retry only clones missing paths.
  (jgy-workspace-test--with-workspace
    (let* ((file (jgy-workspace-test--write "me/projects/demo/project.md" jgy-workspace-test--card))
           (root (file-name-directory file))
           (source (expand-file-name "origin/app" jgy-workspace-directory))
           processes)
      (should (zerop (call-process "git" nil nil nil "init" "--bare" source)))
      (should (zerop (call-process "git" nil nil nil "-C" source "remote" "add" "origin" source)))
      (cl-letf (((symbol-function 'magit-run-git-async)
                 (lambda (&rest args)
                   (let ((proc (make-process :name "workspace-test-git" :buffer nil
                                             :command (cons "git" args) :sentinel #'ignore)))
                     (push proc processes)
                     proc))))
        (jgy-workspace-clone-repo "o/app" root `(("o/app" "app" ,source nil)))
        (while (seq-some #'process-live-p processes) (accept-process-output nil 0.05))
        (should (file-directory-p (expand-file-name "app/.git" root)))
        (should (equal (jgy-workspace--read-repos root) `(((path . "app") (url . ,source)))))
        (make-directory (expand-file-name "existing" root))
        (jgy-workspace--write-repos
         root `(((path . "app") (url . ,source))
                ((path . "existing") (url . ,source))
                ((path . "nested/new") (url . ,source))))
        (jgy-workspace-restore-repos root)
        (while (seq-some #'process-live-p processes) (accept-process-output nil 0.05))
        (should (= (length processes) 2))
        (should-not (file-exists-p (expand-file-name "existing/.git" root)))
        (should (file-directory-p (expand-file-name "nested/new/.git" root)))
        (jgy-workspace--clone-entries
         root `(((path . "failure") (url . ,(concat source "-missing")))
                ((path . "never") (url . ,source))) t)
        (while (seq-some #'process-live-p processes) (accept-process-output nil 0.05))
        (should-not (file-exists-p (expand-file-name "never" root)))
        (should (= (length (jgy-workspace--read-repos root)) 3))
        (jgy-workspace--clone-entries root `(((path . "old") (url . ,source))))
        (while (seq-some #'process-live-p processes) (accept-process-output nil 0.05))
        (jgy-workspace-register-repos root)
        (should (= (length (jgy-workspace--read-repos root)) 4)))
      (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer)))))

;;; jgy-workspace-test.el ends here
