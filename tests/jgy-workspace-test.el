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

;; 新项目建在所选 workspace，克隆源取该 workspace 的 repos/，克隆在切到 perspective 之后。
(ert-deftest jgy-workspace-new-project ()
  (jgy-workspace-test--with-workspace
    (jgy-workspace-test--write "project-template.md" "id: {{id}}\n")
    (jgy-workspace-test--write "me/projects/.keep" "")
    (jgy-workspace-test--write "okj/projects/.keep" "")
    (jgy-workspace-test--write "okj/repos/svc/.git/HEAD" "")
    (jgy-workspace-test--write "me/repos/blog/.git/HEAD" "")
    (let ((jgy-workspace-code-directories nil)
          events)
      (cl-letf (((symbol-function 'persp-names) (lambda () '("main")))
                ((symbol-function 'persp-switch) (lambda (name) (push (list 'switch name) events)))
                ((symbol-function 'find-file) (lambda (file) (push (list 'find file) events)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt names &rest _)
                   (should (equal (sort (copy-sequence names) #'string<) '("me" "okj")))
                   "okj"))
                ((symbol-function 'read-string) (lambda (&rest _) "T"))
                ((symbol-function 'completing-read-multiple)
                 (lambda (_prompt sources _pred match &rest _)
                   (should (equal (mapcar (lambda (dir) (file-name-nondirectory (directory-file-name dir)))
                                          sources)
                                  '("svc")))
                   (should (funcall match ""))
                   (should (funcall match (car sources)))
                   (should-not (funcall match (concat (car sources) ",nope")))
                   sources))
                ((symbol-function 'jgy-workspace-clone-repo)
                 (lambda (repo root)
                   (push (list 'clone (file-name-nondirectory (directory-file-name repo)) root) events))))
        (jgy-workspace-new-project "svc-fix")
        (let* ((root (expand-file-name "okj/projects/svc-fix/" (jgy-workspace--base)))
               (file (expand-file-name "project.md" root)))
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "id: svc-fix\n"))
          (should (equal (nreverse events)
                         `((switch "svc-fix") (find ,file) (clone "svc" ,root))))
          (should-error (jgy-workspace-new-project "svc-fix") :type 'user-error))))))

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

;;; jgy-workspace-test.el ends here
