;;; overlook-test.el --- Tests for the overlook dashboard -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook)
(require 'overlook-agent)
(require 'overlook-project)
(require 'overlook-markers)
(require 'overlook-usage)
(require 'overlook-courier)

(defvar overlook-test--perspectives nil
  "Alist of perspective name to its buffers, for the fake backend.")

(defvar overlook-test--current nil)

(defmacro overlook-test-with-dashboard (perspectives current &rest body)
  "Run BODY in a rendered dashboard over the fake PERSPECTIVES, CURRENT selected.
Agents are listed; usage and repos are not."
  (declare (indent 2))
  `(let* ((overlook-test--perspectives ,perspectives)
          (overlook-test--current ,current)
          (overlook-perspectives-function (lambda () (mapcar #'car overlook-test--perspectives)))
          (overlook-current-perspective-function (lambda () overlook-test--current))
          (overlook-switch-perspective-function (lambda (name) (setq overlook-test--current name)))
          (overlook-perspective-buffers-function
           (lambda (name) (alist-get name overlook-test--perspectives nil nil #'equal)))
          (overlook-perspective-root-function #'ignore)
          (overlook-sections (list #'overlook--perspectives-section))
          (overlook-perspective-functions (list #'overlook-agent--insert))
          (overlook-orphan-functions (list #'overlook-agent--insert-orphans))
          (dashboard (get-buffer-create overlook-buffer-name)))
     (unwind-protect
         (with-current-buffer dashboard
           (overlook-mode)
           (overlook--render)
           ,@body)
       (kill-buffer dashboard))))

(defun overlook-test--agent (name)
  "A fake agent buffer called NAME."
  (with-current-buffer (generate-new-buffer name)
    (setq overlook-agent-identity `((agent . ,name) (root . "/project/")))
    (current-buffer)))

(defun overlook-test--line-of (text)
  "Line number of the first line containing TEXT."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (line-number-at-pos)))

(ert-deftest overlook-perspectives-current-first-then-frecency ()
  (let ((overlook-perspective-visits
         `(("one" 1 . ,(float-time))
           ("two" 5 . ,(- (float-time) 7200))
           ("three" 9 . ,(float-time)))))
    (overlook-test-with-dashboard '(("one") ("two") ("three") ("four")) "three"
      (should (< (overlook-test--line-of "three") (overlook-test--line-of "two")
                 (overlook-test--line-of "one") (overlook-test--line-of "four"))))
    (let ((overlook-perspective-order 'backend))
      (overlook-test-with-dashboard '(("one") ("two") ("three") ("four")) "three"
        (should (< (overlook-test--line-of "one") (overlook-test--line-of "two")
                   (overlook-test--line-of "three") (overlook-test--line-of "four")))))))

(ert-deftest overlook-sections-follow-hook-depth ()
  (let ((overlook-sections nil)
        (overlook-usage--rows '(("claude" ("5h" 10 nil))))
        (dashboard (get-buffer-create overlook-buffer-name)))
    (add-hook 'overlook-sections #'overlook--perspectives-section)
    (add-hook 'overlook-sections #'overlook-usage--section -50)
    (add-hook 'overlook-sections
              (lambda () (overlook-insert-section "Todo" (lambda () (insert "x\n"))))
              50)
    (unwind-protect
        (with-current-buffer dashboard
          (overlook-mode)
          (overlook--render)
          (let ((text (buffer-string)))
            (should (string-search "Usage" text))
            (should (string-search "Todo" text))
            (should (< (string-search "Usage" text) (string-search "Todo" text)))))
      (kill-buffer dashboard))))

(ert-deftest overlook-agents-sit-under-their-perspective ()
  (let ((alpha (overlook-test--agent "alpha"))
        (beta (overlook-test--agent "beta"))
        (stray (overlook-test--agent "stray"))
        (overlook-perspective-order 'backend))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,alpha) ("two" ,beta)) "two"
          (should (< (overlook-test--line-of "one")
                     (overlook-test--line-of "alpha")
                     (overlook-test--line-of "two")
                     (overlook-test--line-of "beta")
                     (overlook-test--line-of "other")
                     (overlook-test--line-of "stray")))
          (goto-char (point-min))
          (search-forward "two")
          (should (eq (get-text-property (line-beginning-position) 'face)
                      'overlook-heading-current)))
      (mapc #'kill-buffer (list alpha beta stray)))))

(ert-deftest overlook-perspective-annotation-after-heading ()
  (let ((overlook-perspective-annotation (lambda (name) (and (equal name "one") "me")))
        (overlook-perspective-order 'backend))
    (overlook-test-with-dashboard '(("one") ("two")) "two"
      (goto-char (point-min))
      (search-forward "one me")
      (should (eq (get-text-property (1- (point)) 'face) 'shadow))
      (should (equal (get-text-property (point) 'overlook-item) '(perspective . "one")))
      (search-forward "two")
      (should (eolp)))))

(ert-deftest overlook-other-heading-only-with-orphans ()
  (let ((alpha (overlook-test--agent "alpha")))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,alpha)) "one"
          (should-not (string-search "other" (buffer-string))))
      (kill-buffer alpha))))

(ert-deftest overlook-redraw-keeps-point-on-its-row ()
  (let ((alpha (overlook-test--agent "alpha"))
        (beta (overlook-test--agent "beta")))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,alpha) ("two" ,beta)) "one"
          (goto-char (point-min))
          (search-forward "beta")
          (should (equal (overlook-item-at-point) (cons 'agent beta)))
          ;; A new agent above it shifts every line down.
          (let ((gamma (overlook-test--agent "gamma")))
            (unwind-protect
                (progn
                  (setf (alist-get "one" overlook-test--perspectives nil nil #'equal)
                        (list alpha gamma))
                  (overlook--render)
                  (should (equal (overlook-item-at-point) (cons 'agent beta))))
              (kill-buffer gamma))))
      (mapc #'kill-buffer (list alpha beta)))))

(ert-deftest overlook-heading-switches-perspective ()
  (overlook-test-with-dashboard '(("one") ("two")) "one"
    (goto-char (point-min))
    (search-forward "two")
    (overlook-visit)
    (should (equal overlook-test--current "two"))))

(ert-deftest overlook-heading-navigation-wraps ()
  (overlook-test-with-dashboard '(("one") ("two")) "one"
    (goto-char (point-min))
    (overlook-next-heading)
    (should (equal (overlook-item-at-point) '(perspective . "one")))
    (overlook-next-heading)
    (should (equal (overlook-item-at-point) '(perspective . "two")))
    (overlook-next-heading)
    (should (equal (overlook-item-at-point) '(perspective . "one")))))

(ert-deftest overlook-attention-stops-at-waiting-agents ()
  (let ((alpha (overlook-test--agent "alpha"))
        (beta (overlook-test--agent "beta")))
    (with-current-buffer beta (setq overlook-agent-status 'waiting))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,alpha ,beta)) "one"
          (goto-char (point-min))
          (overlook-next-attention)
          (should (equal (overlook-item-at-point) (cons 'agent beta))))
      (mapc #'kill-buffer (list alpha beta)))))

(ert-deftest overlook-agent-notifies-when-it-needs-you ()
  (let* ((agent (overlook-test--agent "claude"))
         (sent nil)
         (overlook-agent-notify t)
         (overlook-agent-notify-function (lambda (title body) (push (cons title body) sent)))
         (overlook-perspective-buffers-function
          (lambda (name) (and (equal name "checkout") (list agent))))
         (overlook-perspectives-function (lambda () (list "checkout")))
         (overlook-current-perspective-function #'ignore))
    (unwind-protect
        (with-current-buffer agent
          (overlook-agent-report 'working)
          (should-not sent)
          (overlook-agent-report 'attention)
          (should (equal sent '(("claude needs you" . "checkout"))))
          (let ((overlook-agent-notify nil))
            (overlook-agent-report 'finished))
          (should (= (length sent) 1)))
      (kill-buffer agent))))

(ert-deftest overlook-agent-saved-survive-a-restart ()
  (let* ((overlook-agent-saved-file (make-temp-file "overlook-agents"))
         (agent (overlook-test--agent "claude"))
         (pending '((agent . "codex") (root . "/other/") (session . "s2") (perspective . "two")))
         (overlook-agent-saved (list pending))
         (overlook-agent--saved-written nil)
         (overlook-agent--saved-loaded nil)
         (overlook-perspectives-function (lambda () (list "one")))
         (overlook-current-perspective-function (lambda () "one"))
         (overlook-perspective-buffers-function (lambda (_) (list agent))))
    (unwind-protect
        (progn
          (with-current-buffer agent
            (push '(session . (lambda () "s1")) overlook-agent-identity))
          (overlook-agent-save)
          (should (equal (overlook-agent--to-save) overlook-agent--saved-written))
          (setq overlook-agent-saved nil)
          (overlook-agent--load-saved)
          (should (equal overlook-agent-saved (list pending)))
          (kill-buffer agent)
          (setq overlook-agent--saved-loaded nil)
          (overlook-agent--load-saved)
          (should (equal (mapcar (lambda (saved) (alist-get 'session saved)) overlook-agent-saved)
                         '("s1" "s2")))
          (should (equal (alist-get 'perspective (car overlook-agent-saved)) "one")))
      (when (buffer-live-p agent) (kill-buffer agent))
      (delete-file overlook-agent-saved-file))))

(ert-deftest overlook-agent-saved-rows-resume-their-session ()
  (let* ((kept '((agent . "claude") (root . "/tmp/") (session . "s1") (perspective . "one")))
         (lost '((agent . "codex") (root . "/tmp/") (session . "s2") (perspective . "gone")))
         (overlook-agent-saved (list kept lost))
         (started nil)
         (resumed nil)
         (overlook-agent-start-function
          (lambda (name root &rest args)
            (setq started (cons name (cons root args)))
            (setq resumed (overlook-test--agent name)))))
    (unwind-protect
        (overlook-test-with-dashboard '(("one")) "one"
          (should (< (overlook-test--line-of "one")
                     (overlook-test--line-of "claude saved")
                     (overlook-test--line-of "other")
                     (overlook-test--line-of "codex saved")))
          (goto-char (point-min))
          (search-forward "claude saved")
          (should (equal (overlook-item-at-point) (cons 'saved kept)))
          (overlook-agent--resume kept)
          (should (equal started '("claude" "/tmp/" nil "s1")))
          (should (equal overlook-agent-saved (list lost))))
      (when resumed (kill-buffer resumed)))))

(ert-deftest overlook-agent-start-resumes-the-saved-session ()
  (let* ((overlook-agent-saved
          (list '((agent . "claude") (root . "/tmp/") (session . "s1") (perspective . "one"))))
         (overlook-agent-root-function (lambda () "/tmp/"))
         (started nil)
         (resumed nil)
         (overlook-agent-start-function
          (lambda (name root &rest args)
            (setq started (cons name (cons root args)))
            (setq resumed (overlook-test--agent name)))))
    (unwind-protect
        (save-window-excursion
          (overlook-agent-start "codex")
          (should (equal started '("codex" "/tmp/")))
          (overlook-agent-start "claude")
          (should (equal started '("claude" "/tmp/" nil "s1")))
          (should-not overlook-agent-saved))
      (dolist (buffer (overlook-agent-buffers)) (kill-buffer buffer)))))

(ert-deftest overlook-courier-spawns-and-reports-back ()
  (let* ((courier--agents (make-hash-table :test #'equal))
         (overlook-agent-changed-hook nil)
         (overlook-agent-environment-functions nil)
         (overlook-agent-turn-start-hook nil)
         (overlook-agent-turn-end-hook nil)
         (overlook-agent-row-marks nil)
         (courier-changed-hook nil)
         (courier-spawn-function nil)
         (overlook-perspectives-function #'ignore)
         (overlook-current-perspective-function #'ignore)
         (prompts nil)
         (environments nil)
         (overlook-agent-start-function
          (lambda (name root &rest args)
            (push (cons overlook-agent-environment args) environments)
            (with-current-buffer (generate-new-buffer name)
              (setq overlook-agent-identity
                    `((agent . ,name) (root . ,root)
                      (submit . ,(lambda (text) (push (cons name text) prompts)))
                      (ready . always)
                      (reply . ,(lambda () (format "%s says done" name)))))
              (current-buffer))))
         (root (file-name-as-directory (expand-file-name "shop" (make-temp-file "courier" t))))
         (parent nil))
    (make-directory root)
    (unwind-protect
        (progn
          (overlook-courier-mode 1)
          (setq parent (overlook-agent--launch "claude" root))
          (should (equal (buffer-local-value 'overlook-courier-id parent) "claude@shop"))
          (should (member "COURIER_ID=claude@shop" (car (car environments))))
          (let* ((id (courier-spawn "codex" root "review it" "claude@shop"))
                 (child (courier-agent-buffer (courier-agent id))))
            (should (equal id "codex@shop"))
            (should (equal (cdr (car environments)) '(t)))
            (should (string-search "← claude@shop" (overlook-courier--mark child)))
            (courier-deliver)
            (should (string-suffix-p "review it" (alist-get "codex" prompts nil nil #'equal)))
            (with-current-buffer child
              (overlook-agent-report 'working)
              (overlook-agent-report 'finished))
            (courier-deliver)
            (should (string-search "codex says done" (alist-get "claude" prompts nil nil #'equal)))))
      (overlook-courier-mode -1)
      (dolist (buffer (overlook-agent-buffers)) (kill-buffer buffer))
      (delete-directory (file-name-directory (directory-file-name root)) t))))

(ert-deftest overlook-project-parses-git-status ()
  (should (equal (overlook-project--parse
                  "## main...origin/main [ahead 1]\0 M src/a.el\0?? b\0"
                  "3\t1\tsrc/a.el\0")
                 '("main" ("src/a.el" " M" 3 1) ("b" "??"))))
  (should (equal (overlook-project--parse "## feature/x\0") '("feature/x")))
  (should (equal (overlook-project--parse "## No commits yet on main\0?? a\0")
                 '("main" ("a" "??"))))
  (should (equal (overlook-project--parse "## HEAD (no branch)\0") '("detached"))))

(ert-deftest overlook-project-finds-root-and-nested-repos ()
  (let ((root (make-temp-file "overlook-project" t)))
    (unwind-protect
        (progn
          (dolist (dir '(".git" "api/.git" "web/.git" "notes"))
            (make-directory (expand-file-name dir root) t))
          (should (equal (mapcar (lambda (dir) (file-relative-name dir root))
                                 (overlook-project-repos root))
                         '("./" "api/" "web/"))))
      (delete-directory root t))))

(defmacro overlook-test-with-marked-project (root &rest body)
  "Run BODY with ROOT bound to a marked folder of repos api/ and web/."
  (declare (indent 1))
  `(let ((,root (file-name-as-directory (file-truename (make-temp-file "overlook-project" t))))
         (project-find-functions (list #'overlook-markers-try #'project-try-vc)))
     (unwind-protect
         (progn
           (dolist (file '(".overlook" "notes/n.md" "api/a.el" "api/ignored" "web/b.el"))
             (make-directory (file-name-directory (expand-file-name file ,root)) t)
             (write-region "" nil (expand-file-name file ,root)))
           (write-region "ignored\n" nil (expand-file-name "api/.gitignore" ,root))
           (dolist (repo '("api" "web"))
             (let ((default-directory (expand-file-name repo ,root)))
               (call-process "git" nil nil nil "init" "-q")))
           ,@body)
       (delete-directory ,root t))))

(ert-deftest overlook-project-marked-folder-holds-its-repos ()
  (overlook-test-with-marked-project root
    (should (equal (project-root (project-current nil (expand-file-name "api/" root))) root))
    (let ((default-directory (expand-file-name "web/" root)))
      (should (equal (overlook-agent-project-root) root)))
    (should (equal (sort (mapcar (lambda (file) (file-relative-name file root))
                                 (project-files (project-current nil root)))
                         #'string<)
                   '(".overlook" "api/.gitignore" "api/a.el" "notes/n.md" "web/b.el")))))

(ert-deftest overlook-project-link-into-marked-folder-belongs-to-it ()
  (overlook-test-with-marked-project root
    (let ((link (make-temp-name (expand-file-name "overlook-link" temporary-file-directory))))
      (make-symbolic-link (expand-file-name "api" root) link)
      (unwind-protect
          (should (equal (project-root (project-current nil link)) root))
        (delete-file link)))))

(ert-deftest overlook-project-eglot-keeps-the-repo ()
  (defvar eglot-lsp-context)
  (overlook-test-with-marked-project root
    (let ((eglot-lsp-context t))
      (should (equal (project-root (project-current nil (expand-file-name "api/" root)))
                     (expand-file-name "api/" root))))))

(ert-deftest overlook-project-unmarked-repo-stays-its-own ()
  (overlook-test-with-marked-project root
    (delete-file (expand-file-name ".overlook" root))
    (should (equal (project-root (project-current nil (expand-file-name "api/" root)))
                   (expand-file-name "api/" root)))))

(ert-deftest overlook-markers-mode-registers-the-backend ()
  (let ((project-find-functions (list #'project-try-vc)))
    (overlook-markers-mode 1)
    (should (eq (car project-find-functions) #'overlook-markers-try))
    (overlook-markers-mode -1)
    (should (equal project-find-functions (list #'project-try-vc)))))

;; Repos sit dimmed under their perspective, names aligned, their changed files under them.
(ert-deftest overlook-project-rows-line-up-before-agents ()
  (let ((root (make-temp-file "overlook-project" t))
        (alpha (overlook-test--agent "alpha"))
        (overlook-project--status (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (dolist (dir '("api/.git" "frontend/.git"))
            (make-directory (expand-file-name dir root) t))
          (dolist (repo '(("api/" "main" ("src/a.el" " M" 3 1) ("b.el" "??"))
                          ("frontend/" "dev")))
            (puthash (file-name-as-directory (expand-file-name (car repo) root))
                     (cons (float-time) (cdr repo)) overlook-project--status))
          (overlook-test-with-dashboard `(("one" ,alpha)) "one"
            (let ((overlook-perspective-root-function (lambda (_) root))
                  (overlook-perspective-functions
                   (list #'overlook-project--insert #'overlook-agent--insert)))
              (overlook--render)
              (let ((api (progn (goto-char (point-min)) (search-forward "api")
                                (buffer-substring-no-properties (line-beginning-position)
                                                                (line-end-position))))
                    (frontend (progn (goto-char (point-min)) (search-forward "frontend")
                                     (buffer-substring-no-properties (line-beginning-position)
                                                                     (line-end-position)))))
                (should (string-match-p "⎇ +api +main \\+3 −1\\'" api))
                (should (string-match-p "⎇ +frontend  dev" frontend))
                (should (= (string-search "main" api) (string-search "dev" frontend))))
              (goto-char (point-min))
              (search-forward "a.el")
              (should (equal (overlook-item-at-point)
                             (list 'repo-file (expand-file-name "api/" root) "src/a.el")))
              (should (string-match-p "a\\.el \\+3 −1 src/\\'"
                                      (buffer-substring-no-properties (line-beginning-position)
                                                                      (line-end-position))))
              (should (< (overlook-test--line-of "b.el new") (overlook-test--line-of "frontend")))
              (goto-char (point-min))
              (search-forward "api")
              (should (eq (get-text-property (point) 'face) 'overlook-project-repo))
              (should (< (overlook-test--line-of "frontend") (overlook-test--line-of "alpha"))))))
      (kill-buffer alpha)
      (delete-directory root t))))

;;; overlook-test.el ends here
