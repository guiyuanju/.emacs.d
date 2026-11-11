;;; overlook-data-test.el --- Semantic query boundaries -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'overlook-data)
(require 'overlook-remote-model)

(ert-deftest overlook-data-builtins-do-not-read-display-segments ()
  (cl-letf (((symbol-function 'overlook-row-segments)
             (lambda (&rest _) (ert-fail "Business query read display segments"))))
    (dolist (key '((project . "demo") (closed-project "demo")
                   (section "Projects") (project-status "waiting")))
      (let ((data (overlook-remote--row-data (overlook-row :id key :content "ignored"))))
        (should (stringp (plist-get data :title)))
        (should (stringp (plist-get data :resourceId)))))))

(ert-deftest overlook-data-agent-identity-survives-buffer-renaming ()
  (let ((buffer (generate-new-buffer " *data-agent*")))
    (unwind-protect
        (let ((id (overlook-data-agent-id buffer)))
          (with-current-buffer buffer
            (rename-buffer " *data-agent-renamed*" t)
            (fundamental-mode))
          (should (equal id (overlook-data-agent-id buffer)))
          (should (equal id (overlook-data-id (cons 'agent buffer)))))
      (kill-buffer buffer))))

(ert-deftest overlook-data-queries-agent-without-a-view ()
  (let ((buffer (generate-new-buffer " *semantic-agent*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local overlook-agent-identity '((agent . "claude")
                                                  (title . (lambda () "Full title"))))
            (setq-local overlook-agent-status 'working
                        overlook-agent-turn '(100 . 180)))
          (let ((data (overlook-data (cons 'agent buffer))))
            (should (equal (plist-get data :title) "Full title"))
            (should (= (plist-get data :durationSeconds) 80))
            (should-not (plist-member data :duration))))
      (kill-buffer buffer))))

(ert-deftest overlook-data-extension-provider-receives-key-only ()
  (let ((overlook-data-functions
         (list (lambda (key)
                 (when (equal key '(external . "one"))
                   '(:kind "text" :title "Extension"))))))
    (should (equal (plist-get (overlook-data '(external . "one")) :title) "Extension"))
    (should-not (overlook-data '(external . "missing")))))

(ert-deftest overlook-data-project-identity-survives-opening-and-closing ()
  (should (equal (overlook-data-id '(project . "demo"))
                 (overlook-data-id '(closed-project "demo")))))

(ert-deftest overlook-data-saved-identity-ignores-title-changes ()
  (should (equal (overlook-data-id '(saved (agent . "claude") (root . "/work/")
                                         (session . "one") (title . "Before")))
                 (overlook-data-id '(saved (agent . "claude") (root . "/work/")
                                         (session . "one") (title . "After"))))))

(provide 'overlook-data-test)

(ert-deftest overlook-data-persona-keeps-identity-separate-from-session-title ()
  (require 'overlook-agent-courier)
  (let ((buffer (generate-new-buffer " *persona-data*")))
    (unwind-protect
        (cl-letf (((symbol-function 'overlook-courier-persona)
                   (lambda (name) (and (equal name "reviewer")
                                       '(:name "reviewer" :engine "codex" :description "Reviews code"))))
                  ((symbol-function 'overlook-courier-persona-of)
                   (lambda (id) (and (equal id "reviewer-2") "reviewer")))
                  ((symbol-function 'overlook-courier-persona-instances) (lambda (_) nil)))
          (with-current-buffer buffer
            (setq-local overlook-agent-courier-id "reviewer-2"
                        overlook-agent-identity '((agent . "codex")
                                                  (title . (lambda () "Architecture")))
                        overlook-agent-status 'idle))
          (let ((data (overlook-data (cons 'agent buffer))))
            (should (equal (plist-get data :title) "Architecture"))
            (should (equal (plist-get data :persona) "reviewer"))
            (should (equal (plist-get data :description) "Reviews code")))
          (let ((data (overlook-data '(persona . "reviewer"))))
            (should (equal (plist-get data :kind) "persona"))
            (should (equal (plist-get data :status) "offline"))
            (should (equal (plist-get data :provider) "codex"))))
      (kill-buffer buffer))))
