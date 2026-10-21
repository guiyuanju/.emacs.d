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

(ert-deftest overlook-perspectives-current-first-then-recent ()
  (let ((overlook-perspective-switch-times
         `(("one" . ,(- (float-time) 7200))
           ("two" . ,(float-time))
           ("three" . ,(- (float-time) 60)))))
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
                     (overlook-test--line-of "stray")))
          (goto-char (point-min))
          (search-forward "two")
          (should (eq (get-text-property (line-beginning-position) 'face)
                      'overlook-heading-current)))
      (mapc #'kill-buffer (list alpha beta stray)))))

(ert-deftest overlook-agent-shown-in-several-perspectives-sits-under-its-project ()
  (let ((alpha (overlook-test--agent "alpha"))
        (overlook-perspective-order 'backend))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,alpha) ("two" ,alpha)) "one"
          (let ((overlook-perspective-root-function
                 (lambda (name) (and (equal name "two") "/project/"))))
            (overlook--render)
            (should (equal (overlook-agent-perspective alpha) "two"))
            (should (< (overlook-test--line-of "two") (overlook-test--line-of "alpha")))
            (goto-char (point-min))
            (search-forward "alpha")
            (should-not (search-forward "alpha" nil t))))
      (kill-buffer alpha))))

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

(ert-deftest overlook-perspective-filter-hides-unless-current-or-needing-you ()
  (let ((alpha (overlook-test--agent "alpha"))
        (overlook-perspective-filter (lambda (name) (equal name "one")))
        (overlook-perspective-order 'backend))
    (unwind-protect
        (overlook-test-with-dashboard `(("one") ("two") ("three") ("four" ,alpha)) "three"
          (should (string-search "one" (buffer-string)))
          (should-not (string-search "two" (buffer-string)))
          (should (string-search "three" (buffer-string)))
          (should-not (string-search "four" (buffer-string)))
          (with-current-buffer alpha (setq overlook-agent-status 'waiting))
          (overlook--render)
          (should (string-search "four" (buffer-string))))
      (kill-buffer alpha))))

(ert-deftest overlook-empty-orphan-perspective-is-left-out ()
  (let ((alpha (overlook-test--agent "alpha"))
        (overlook-orphan-perspective "main")
        (overlook-perspective-order 'backend))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,alpha) ("main")) "one"
          (should-not (string-search "main" (buffer-string)))
          (should (string-suffix-p "project\n\n" (buffer-string)))
          (setq overlook-test--current "main")
          (overlook--render)
          (should (string-search "main" (buffer-string))))
      (kill-buffer alpha))))

(ert-deftest overlook-orphans-sit-under-the-orphan-perspective ()
  (let ((alpha (overlook-test--agent "alpha"))
        (beta (overlook-test--agent "beta"))
        (overlook-orphan-perspective "main"))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,alpha) ("main")) "one"
          (should (> (overlook-test--line-of "beta") (overlook-test--line-of "main")))
          (goto-char (point-min))
          (search-forward "beta")
          (save-window-excursion (overlook-visit))
          (should (equal overlook-test--current "main")))
      (kill-buffer alpha)
      (kill-buffer beta))))

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

(ert-deftest overlook-switch-moves-point-to-the-current-perspective ()
  (let ((alpha (overlook-test--agent "alpha")))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,alpha) ("two")) "one"
          (goto-char (point-min))
          (search-forward "alpha")
          (setq overlook-test--current "two")
          (overlook-perspective-switched)
          (overlook--render)
          (should (equal (overlook-item-at-point) '(perspective . "two")))
          (should (bolp))
          ;; Later redraws keep point where it is.
          (search-forward "one")
          (overlook--render)
          (should (equal (overlook-item-at-point) '(perspective . "one"))))
      (kill-buffer alpha))))

(ert-deftest overlook-redraw-keeps-the-window-still ()
  (overlook-test-with-dashboard (mapcar (lambda (i) (list (format "p%02d" i))) (number-sequence 1 60)) "p01"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (delete-other-windows)
      (let ((window (selected-window)))
        (set-window-start window (save-excursion (goto-char (point-min)) (search-forward "p20")
                                                 (line-beginning-position)))
        (goto-char (point-min))
        (search-forward "p25")
        (set-window-point window (point))
        (overlook--render)
        (should (equal (overlook-item-at-point) '(perspective . "p25")))
        (should (= (window-start window) (save-excursion (goto-char (point-min)) (search-forward "p20")
                                                         (line-beginning-position))))
        ;; A row added above the window leaves it showing the same rows.
        (setq overlook-test--perspectives (cons '("p00") overlook-test--perspectives))
        (overlook--render)
        (should (equal (overlook-item-at-point) '(perspective . "p25")))
        (should (= (window-start window) (save-excursion (goto-char (point-min)) (search-forward "p20")
                                                         (line-beginning-position))))))))

(ert-deftest overlook-heading-switches-perspective ()
  (overlook-test-with-dashboard '(("one") ("two")) "one"
    (goto-char (point-min))
    (search-forward "two")
    (overlook-visit)
    (should (equal overlook-test--current "two"))))

(defun overlook-test--hidden-p (text)
  "Whether the first line containing TEXT is folded away."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (invisible-p (line-beginning-position))))

(ert-deftest overlook-tab-folds-a-heading-and-keeps-it-folded ()
  (let ((alpha (overlook-test--agent "alpha"))
        (beta (overlook-test--agent "beta"))
        (overlook-perspective-order 'backend))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,alpha) ("two" ,beta)) "one"
          (goto-char (point-min))
          (search-forward "one")
          (call-interactively #'magit-section-toggle)
          (should (overlook-test--hidden-p "alpha"))
          (should-not (overlook-test--hidden-p "two"))
          (should-not (overlook-test--hidden-p "beta"))
          (overlook--render)
          (should (overlook-test--hidden-p "alpha"))
          (call-interactively #'magit-section-toggle)
          (should-not (overlook-test--hidden-p "alpha")))
      (mapc #'kill-buffer (list alpha beta)))))

(ert-deftest overlook-ret-folds-a-section-title ()
  (overlook-test-with-dashboard '(("one") ("two")) "one"
    (goto-char (point-min))
    (overlook-visit)
    (should (overlook-test--hidden-p "one"))
    (should (overlook-test--hidden-p "two"))))

(ert-deftest overlook-hidden-rows-start-folded-and-nest ()
  (let ((overlook-sections
         (list (lambda ()
                 (overlook-insert-section
                  "Todo"
                  (lambda ()
                    (overlook-insert-row
                     "proj\n"
                     (lambda ()
                       (overlook-insert-row "   now\n")
                       (overlook-insert-row
                        "   2 more\n"
                        (lambda ()
                          (overlook-insert-row "   later\n"
                                               (lambda () (overlook-insert-row "     sub\n")))
                          (overlook-insert-row "   last\n"))
                        t))))))))
        (dashboard (get-buffer-create overlook-buffer-name)))
    (unwind-protect
        (with-current-buffer dashboard
          (overlook-mode)
          (overlook--render)
          (should-not (overlook-test--hidden-p "now"))
          (should-not (overlook-test--hidden-p "2 more"))
          (should (overlook-test--hidden-p "later"))
          (should (overlook-test--hidden-p "sub"))
          (should (overlook-test--hidden-p "last"))
          (goto-char (point-min))
          (search-forward "2 more")
          (call-interactively #'magit-section-toggle)
          (should-not (overlook-test--hidden-p "later"))
          (should-not (overlook-test--hidden-p "last"))
          (search-forward "later")
          (call-interactively #'magit-section-toggle)
          (should (overlook-test--hidden-p "sub"))
          (should-not (overlook-test--hidden-p "last"))
          (overlook--render)
          (should (overlook-test--hidden-p "sub"))
          (should-not (overlook-test--hidden-p "later")))
      (kill-buffer dashboard))))

(ert-deftest overlook-highlights-the-section-at-point ()
  (overlook-test-with-dashboard '(("one") ("two")) "one"
    (goto-char (point-min))
    (search-forward "two")
    (magit-section-update-highlight t)
    (should (eq (get-char-property (point) 'face) 'magit-section-highlight))))

(ert-deftest overlook-highlight-survives-global-font-lock ()
  (let ((was global-font-lock-mode))
    (global-font-lock-mode 1)
    (unwind-protect
        (overlook-test-with-dashboard '(("one") ("two")) "one"
          (goto-char (point-min))
          (search-forward "two")
          (magit-section-update-highlight t)
          (should (eq (get-char-property (point) 'face) 'magit-section-highlight)))
      (global-font-lock-mode (if was 1 -1)))))

(ert-deftest overlook-blank-line-belongs-to-the-section-above ()
  (overlook-test-with-dashboard '(("one") ("two")) "one"
    (goto-char (point-min))
    (search-forward "two")
    (forward-line -1)
    (should (equal (oref (magit-current-section) value) '(perspective . "one")))
    (magit-section-update-highlight t)
    (should (eq (get-char-property (point) 'face) 'magit-section-highlight))))

(ert-deftest overlook-empty-perspective-folds-its-blank-line ()
  (overlook-test-with-dashboard '(("one") ("two")) "one"
    (goto-char (point-min))
    (search-forward "one")
    (let ((section (magit-current-section)))
      (should (oref section content))
      (should-not (invisible-p (oref section content)))
      (magit-section-toggle section)
      (should (invisible-p (oref section content)))
      (should-not (overlook-test--hidden-p "two"))
      (overlook--render)
      (goto-char (point-min))
      (search-forward "one")
      (setq section (magit-current-section))
      (should (invisible-p (oref section content)))
      (magit-section-toggle section)
      (should-not (invisible-p (oref section content))))))

(ert-deftest overlook-highlight-covers-wrap-prefixes ()
  (let ((alpha (overlook-test--agent "alpha")))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,alpha)) "one"
          (goto-char (point-min))
          (search-forward "one")
          (magit-section-update-highlight t)
          (search-forward "alpha")
          (should (eq (get-text-property 0 'face (get-char-property (point) 'wrap-prefix))
                      'magit-section-highlight)))
      (kill-buffer alpha))))

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

(ert-deftest overlook-agent-choices-sit-under-the-row-and-take-keys ()
  (let* ((agent (overlook-test--agent "claude"))
         (asked t)
         (given nil))
    (with-current-buffer agent
      (setq overlook-agent-status 'waiting)
      (setf (alist-get 'choices overlook-agent-identity)
            (lambda () (when asked
                         `(("y" "Allow" ,(lambda () (push "y" given) (setq asked nil)))
                           ("n" "Reject" ,(lambda () (push "n" given))))))))
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,agent)) "one"
          (goto-char (point-min))
          (overlook-next-attention)
          (should (equal (overlook-item-at-point) (cons 'agent agent)))
          ;; The choices line is part of the row, but not a stop of its own.
          (overlook-next-attention)
          (should (= (line-number-at-pos) (overlook-test--line-of "claude")))
          (forward-line 1)
          (should (looking-at-p " *y Allow  n Reject$"))
          (should (equal (overlook-item-at-point) (cons 'agent agent)))
          (search-forward "Reject")
          (backward-char)
          (funcall (keymap-lookup (get-text-property (point) 'keymap) "RET"))
          (should (equal given '("n")))
          (goto-char (point-min))
          (overlook-next-attention)
          (funcall (keymap-lookup (get-text-property (point) 'keymap) "y"))
          (should (equal given '("y" "n")))
          ;; Answered: the agent works again and offers nothing.
          (should (eq (buffer-local-value 'overlook-agent-status agent) 'working))
          (overlook--render)
          (should-not (string-match-p "Allow" (buffer-string)))
          (should-error (overlook-agent-choose agent "y") :type 'user-error))
      (kill-buffer agent))))

(ert-deftest overlook-failed-agents-need-attention ()
  (let ((agent (overlook-test--agent "codex")))
    (unwind-protect
        (progn
          (with-current-buffer agent
            (setq overlook-agent-status 'failed
                  overlook-agent-error "Request failed"))
          (overlook-test-with-dashboard `(("one" ,agent)) "one"
            (goto-char (point-min))
            (overlook-next-attention)
            (should (equal (overlook-item-at-point) (cons 'agent agent)))
            (should (get-text-property (point) 'overlook-attention))
            (should (string-match-p "✖" (buffer-string)))
            (should (string-match-p "Request failed" (buffer-string)))
            (should (string-match-p "1 need you" (overlook-agent--mode-line)))))
      (kill-buffer agent))))

(ert-deftest overlook-agent-notifies-when-it-needs-you ()
  (let* ((agent (overlook-test--agent "claude"))
         (sent nil)
         (overlook-agent-notify t)
         (overlook-agent-notify-function (lambda (title body _buffer) (push (cons title body) sent)))
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
                     (overlook-test--line-of "codex saved")))
          (goto-char (point-min))
          (search-forward "claude saved")
          (should (equal (overlook-item-at-point) (cons 'saved kept)))
          (overlook-agent--resume kept)
          (should (equal started '("claude" "/tmp/" nil "s1")))
          (should (equal overlook-agent-saved (list lost))))
      (when resumed (kill-buffer resumed)))))

;; A fork sits under its parent; one apart from its parent is marked.
(ert-deftest overlook-agent-forks-sit-under-their-parent ()
  (let* ((overlook-agent-forks nil)
         (parent (overlook-test--agent "claude"))
         (child (overlook-test--agent "child"))
         (stray (overlook-test--agent "stray"))
         (saved '((agent . "codex") (root . "/project/") (session . "s4") (perspective . "one")))
         (overlook-agent-saved (list saved))
         (overlook-perspective-order 'backend))
    (with-current-buffer parent
      (push '(session . (lambda () "s1")) overlook-agent-identity))
    (with-current-buffer child
      (push '(session . (lambda () "s2")) overlook-agent-identity)
      (push '(forked-from . (lambda () "s1")) overlook-agent-identity))
    (with-current-buffer stray
      (push '(session . (lambda () "s3")) overlook-agent-identity)
      (push '(forked-from . (lambda () "gone")) overlook-agent-identity))
    (push '("s4" . "s2") overlook-agent-forks)
    (unwind-protect
        (overlook-test-with-dashboard `(("one" ,stray ,child ,parent)) "one"
          (should (equal (overlook-agent--parent "s2") "s1"))
          (should (< (overlook-test--line-of "claude")
                     (overlook-test--line-of "child")
                     (overlook-test--line-of "codex saved")))
          (goto-char (point-min))
          (search-forward "child")
          (should (string-prefix-p "└ " (buffer-substring (line-beginning-position) (point))))
          (search-forward "codex saved")
          (should (string-prefix-p "  └ " (buffer-substring (line-beginning-position) (point))))
          (goto-char (point-min))
          (search-forward "stray")
          (should (looking-at " fork"))
          (should-not (string-search "└" (buffer-substring (line-beginning-position) (point)))))
      (mapc #'kill-buffer (list parent child stray)))))

(ert-deftest overlook-agent-forks-survive-a-restart ()
  (let* ((overlook-agent-saved-file (make-temp-file "overlook-agents"))
         (overlook-agent-forks-file (make-temp-file "overlook-forks"))
         (overlook-agent-forks nil)
         (overlook-agent--forks-written nil)
         (overlook-agent-saved nil)
         (overlook-agent--saved-written nil)
         (overlook-agent--saved-loaded nil)
         (agent (overlook-test--agent "claude")))
    (unwind-protect
        (progn
          (with-current-buffer agent
            (push '(session . (lambda () "s2")) overlook-agent-identity)
            (push '(forked-from . (lambda () "s1")) overlook-agent-identity))
          (overlook-agent-save)
          (kill-buffer agent)
          (setq overlook-agent-forks nil)
          (overlook-agent--load-saved)
          (should (equal overlook-agent-forks '(("s2" . "s1")))))
      (when (buffer-live-p agent) (kill-buffer agent))
      (delete-file overlook-agent-saved-file)
      (delete-file overlook-agent-forks-file))))

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
            (let ((environment (overlook-agent-make-environment name root)))
              (push (cons environment args) environments)
              (with-current-buffer (generate-new-buffer name)
                (setq overlook-agent-identity
                      `((agent . ,name) (root . ,root) (environment . ,environment)
                        (submit . ,(lambda (text) (push (cons name text) prompts)))
                        (ready . always)
                        (reply . ,(lambda () (format "%s says done" name)))))
                (overlook-agent-register (current-buffer) name)
                (current-buffer)))))
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

(ert-deftest overlook-project-folds-a-rename-into-its-new-path ()
  (should (equal (overlook-project--parse
                  "## HEAD (no branch)\0D  old/a.el\0 A new/a.el\0 M b.el\0"
                  "2\t1\t\0old/a.el\0new/a.el\0003\t0\tb.el\0")
                 '("detached" ("new/a.el" " R" 2 1 "old/a.el") ("b.el" " M" 3 0))))
  (should (string-search " ← old/"
                         (overlook-project--file-label '("new/a.el" " R" 2 1 "old/a.el"))))
  (should (equal (overlook-project--old-path "src/x/form/a.el" "src/x/dto/a.el") "form/"))
  (should (equal (overlook-project--old-path "src/a.el" "src/b.el") "a.el"))
  (should (equal (overlook-project--old-path "src/f/a.el" "src/g/b.el") "f/a.el"))
  (should (equal (overlook-project--old-path "a.el" "src/a.el") "a.el"))
  (require 'magit-ediff)
  (let (compared)
    (cl-letf (((symbol-function 'magit-ediff-compare)
               (lambda (&rest args) (setq compared args))))
      (overlook-project-open-file temporary-file-directory '("new/a.el" " R" 2 1 "old/a.el")))
    (should (equal compared '("HEAD" "{worktree}" "old/a.el" "new/a.el")))))

(ert-deftest overlook-project-treats-added-files-as-new ()
  (should (string-search " new" (overlook-project--file-label '("a" " A" 2 0))))
  (should (string-search " new" (overlook-project--file-label '("a" "A " 2 0))))
  (should (string-search " deleted" (overlook-project--file-label '("a" "AD"))))
  ;; Loaded first, or opening a file loads it over the stubs.
  (require 'magit-ediff)
  (let (opened)
    (cl-letf (((symbol-function 'find-file) (lambda (path) (push (list 'visit path) opened)))
              ((symbol-function 'magit-diff-working-tree)
               (lambda (_rev _args files) (push (cons 'diff files) opened)))
              ((symbol-function 'magit-ediff-show-working-tree)
               (lambda (path) (push (list 'ediff path) opened))))
      (dolist (file '(("n" " A") ("u" "??") ("g" "AD") ("m" " M")))
        (overlook-project-open-file temporary-file-directory file)))
    (should (equal (reverse opened)
                   '((visit "n") (visit "u") (diff "g") (ediff "m"))))))

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
      (should (file-equal-p (project-root (project-current nil (expand-file-name "api/" root)))
                     (expand-file-name "api/" root))))))

(ert-deftest overlook-project-unmarked-repo-stays-its-own ()
  (overlook-test-with-marked-project root
    (delete-file (expand-file-name ".overlook" root))
    (should (file-equal-p (project-root (project-current nil (expand-file-name "api/" root)))
                   (expand-file-name "api/" root)))))

(ert-deftest overlook-markers-mode-registers-the-backend ()
  (let ((project-find-functions (list #'project-try-vc)))
    (overlook-markers-mode 1)
    (should (eq (car project-find-functions) #'overlook-markers-try))
    (overlook-markers-mode -1)
    (should (equal project-find-functions (list #'project-try-vc)))))

;; Changed repos sit dimmed under their perspective, names aligned, their changed files
;; under them; clean ones stay hidden.
(ert-deftest overlook-project-rows-line-up-before-agents ()
  (let ((root (make-temp-file "overlook-project" t))
        (alpha (overlook-test--agent "alpha"))
        (overlook-project--status (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (dolist (dir '("api/.git" "frontend/.git" "docs/.git"))
            (make-directory (expand-file-name dir root) t))
          (dolist (repo '(("api/" "main" ("src/a.el" " M" 3 1) ("b.el" "??"))
                          ("frontend/" "dev" ("c.el" " M" 1 0))
                          ("docs/" "main")))
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
                (should-not (string-search "docs" (buffer-string)))
                (should (member (expand-file-name "docs/" root) overlook-project--shown))
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

;; A folder inside a larger repo lists only the changes under it, and only while it has some.
(ert-deftest overlook-project-folder-in-repo-lists-its-changes ()
  (let* ((top (file-name-as-directory (file-truename (make-temp-file "overlook-project" t))))
         (card (expand-file-name "projects/one/" top))
         (overlook-project--status (make-hash-table :test #'equal))
         (overlook-project--reading (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "notes" card) t)
          (let ((default-directory top))
            (call-process "git" nil nil nil "init" "-q")
            (write-region "" nil "other.md")
            (write-region "" nil "projects/one/notes/n.md"))
          (overlook-project--read card)
          (with-timeout (5 (ert-fail "git status timed out"))
            (while (gethash card overlook-project--reading) (accept-process-output nil 0.05)))
          (should (equal (mapcar #'car (cddr (gethash card overlook-project--status)))
                         '("projects/one/")))
          (puthash card (list (float-time) "main" '("projects/one/notes/n.md" " M" 2 0))
                   overlook-project--status)
          (overlook-test-with-dashboard '(("one")) "one"
            (let ((overlook-perspective-root-function (lambda (_) card))
                  (overlook-perspective-functions (list #'overlook-project--insert)))
              (overlook--render)
              (goto-char (point-min))
              (should (string-match-p "⎇ +one +main \\+2"
                                      (progn (search-forward "one  main")
                                             (buffer-substring-no-properties
                                              (line-beginning-position) (line-end-position)))))
              (search-forward "n.md")
              (should (string-match-p "n\\.md \\+2 notes/\\'"
                                      (buffer-substring-no-properties (line-beginning-position)
                                                                      (line-end-position))))
              (puthash card (list (float-time) "main") overlook-project--status)
              (overlook--render)
              (should-not (string-search "⎇" (buffer-string)))
              (should (member card overlook-project--shown)))))
      (delete-directory top t))))

;; With `mark', a changed folder inside a larger repo marks its heading instead of a row.
(ert-deftest overlook-project-folder-in-repo-marks-the-heading ()
  (let* ((top (file-name-as-directory (file-truename (make-temp-file "overlook-project" t))))
         (card (expand-file-name "projects/one/" top))
         (overlook-project-folder-display 'mark)
         (overlook-project--status (make-hash-table :test #'equal))
         (overlook-heading-mark-functions (list #'overlook-project--heading-mark)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" top) t)
          (make-directory card t)
          (puthash card (list (float-time) "main" '("projects/one/n.md" " M" 2 0))
                   overlook-project--status)
          (overlook-test-with-dashboard '(("one")) "one"
            (let ((overlook-perspective-root-function (lambda (_) card))
                  (overlook-perspective-functions (list #'overlook-project--insert)))
              (overlook--render)
              (goto-char (point-min))
              (should (search-forward "one*" nil t))
              (should-not (string-search "⎇" (buffer-string)))
              (should (member card overlook-project--shown))
              (puthash card (list (float-time) "main") overlook-project--status)
              (overlook--render)
              (should-not (string-search "one*" (buffer-string))))))
      (delete-directory top t))))

;; Files past `overlook-project-files' fold into one line that unfolds to list them.
(ert-deftest overlook-project-rest-files-unfold ()
  (let ((root (file-name-as-directory (make-temp-file "overlook-project" t)))
        (overlook-project-files 1)
        (overlook-project--status (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "api/.git" root) t)
          (puthash (expand-file-name "api/" root)
                   (list (float-time) "main" '("a.el" " M" 1 0) '("b.el" " M" 2 0))
                   overlook-project--status)
          (overlook-test-with-dashboard '(("one")) "one"
            (let ((overlook-perspective-root-function (lambda (_) root))
                  (overlook-perspective-functions (list #'overlook-project--insert)))
              (overlook--render)
              (goto-char (point-min))
              (search-forward "…+1")
              (should (invisible-p (save-excursion (search-forward "b.el"))))
              (magit-section-toggle (magit-current-section))
              (should-not (invisible-p (save-excursion (search-forward "b.el")))))))
      (delete-directory root t))))

;; A changed file's diff stays folded under it, Magit's once unfolded.
(ert-deftest overlook-project-file-unfolds-its-diff ()
  (skip-unless (require 'magit nil t))
  (let* ((root (file-name-as-directory (make-temp-file "overlook-project" t)))
         (api (expand-file-name "api/" root))
         (overlook-project--status (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (make-directory api)
          (let ((default-directory api))
            (call-process "git" nil nil nil "init" "-q")
            (write-region "old\n" nil "a.el")
            (call-process "git" nil nil nil "add" "a.el")
            (call-process "git" nil nil nil "-c" "user.name=t" "-c" "user.email=t@t"
                          "commit" "-qm" "init")
            (write-region "new\n" nil "a.el"))
          (puthash api (list (float-time) "main" '("a.el" " M" 1 1)) overlook-project--status)
          (overlook-test-with-dashboard '(("one")) "one"
            (let ((overlook-perspective-root-function (lambda (_) root))
                  (overlook-perspective-functions (list #'overlook-project--insert)))
              (overlook--render)
              (should-not (string-search "+new" (buffer-string)))
              (overlook--render)
              (should-not (string-search "+new" (buffer-string)))
              (goto-char (point-min))
              (search-forward "a.el")
              (call-interactively #'magit-section-toggle)
              (should-not (overlook-test--hidden-p "+new"))
              (should (< (overlook-test--line-of "@@ -1") (overlook-test--line-of "-old")))
              (save-excursion
                (search-forward "+new")
                (should (eq (oref (magit-current-section) type) 'hunk))
                (should-not (get-text-property (point) 'keymap))
                (should (get-text-property (line-beginning-position) 'overlook-action)))
              (goto-char (point-min))
              (search-forward "a.el")
              (call-interactively #'magit-section-toggle)
              (should (overlook-test--hidden-p "+new"))
              (overlook--render)
              (should-not (string-search "+new" (buffer-string))))))
      (delete-directory root t))))

;;; overlook-test.el ends here
