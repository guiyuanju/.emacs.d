;;; overlook-test.el --- Tests for the overlook dashboard -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook)
(require 'overlook-agent)
(require 'overlook-project)
(require 'overlook-usage)

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
