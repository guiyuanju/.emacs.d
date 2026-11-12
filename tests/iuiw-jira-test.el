;;; iuiw-jira-test.el --- Jira ticket checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'iuiw-jira)
(require 'overlook)

(defmacro iuiw-jira-test--with-card (text &rest body)
  "Run BODY with a workspace holding project demo of card TEXT, and an empty cache."
  (declare (indent 1))
  `(let* ((iuiw-workspace-directory (file-name-as-directory (make-temp-file "iuiw-jira" t)))
          (iuiw-workspace-project-roots nil)
          (iuiw-workspace--cache nil)
          (iuiw-jira--tickets (make-hash-table :test #'equal))
          (file (expand-file-name "work/projects/demo/project.md" iuiw-workspace-directory)))
     (make-directory (file-name-directory file) t)
     (write-region ,text nil file nil 'silent)
     (unwind-protect (progn ,@body)
       (delete-directory iuiw-workspace-directory t))))

(defun iuiw-jira-test--fresh (key plist)
  "Cache PLIST as ticket KEY, fetched now."
  (puthash key (cons (float-time) plist) iuiw-jira--tickets))

(ert-deftest iuiw-jira-test-parse-field ()
  (iuiw-jira-test--with-card "---\nstatus: active\njira: [ABC-1, \"ABC-2\"]\n---\n"
    (should (equal (plist-get (iuiw-workspace--card "demo") :jira) '("ABC-1" "ABC-2")))))

(ert-deftest iuiw-jira-test-no-field-no-rows ()
  (iuiw-jira-test--with-card "---\nid: abc-1\ntitle: ABC-1 fix\nstatus: active\n---\n"
    (should-not (iuiw-jira--project-rows "demo"))))

(ert-deftest iuiw-jira-test-done-fold ()
  (iuiw-jira-test--with-card "---\nstatus: active\njira: [ABC-1, ABC-2, ABC-3]\n---\n"
    (iuiw-jira-test--fresh "ABC-1" '(:summary "one" :status "Done" :category "done"))
    (iuiw-jira-test--fresh "ABC-2" '(:summary "two" :status "Doing" :category "indeterminate"))
    (iuiw-jira-test--fresh "ABC-3" '(:missing t))
    (cl-letf (((symbol-function 'executable-find) #'ignore))
      (let ((rows (iuiw-jira--project-rows "demo")))
        (should (equal (mapcar #'overlook-row-id rows)
                       '((jira "ABC-2" "demo") (jira "ABC-3" "demo") (jira-done "demo"))))
        (should (overlook-row-folded (nth 2 rows)))
        (should (equal (mapcar #'overlook-row-id (overlook-row-children (nth 2 rows)))
                       '((jira "ABC-1" "demo"))))))))

(ert-deftest iuiw-jira-test-not-ongoing ()
  (iuiw-jira-test--with-card "---\nstatus: done\njira: [ABC-1]\n---\n"
    (should-not (iuiw-jira--project-rows "demo"))))

(ert-deftest iuiw-jira-test-acli-json ()
  (with-temp-buffer
    (insert "[{\"key\":\"ABC-1\",\"fields\":{\"summary\":\"s\",\"assignee\":null,"
            "\"status\":{\"name\":\"Doing\",\"statusCategory\":{\"key\":\"indeterminate\"}}}},null]")
    (should (equal (iuiw-jira--parse (current-buffer))
                   '(("ABC-1" :summary "s" :status "Doing" :category "indeterminate"
                      :assignee nil)))))
  (with-temp-buffer
    (insert "✗ Error")
    (should (eq (iuiw-jira--parse (current-buffer)) :error))))

(ert-deftest iuiw-jira-test-stale ()
  (let ((iuiw-jira--tickets (make-hash-table :test #'equal))
        (iuiw-jira-interval 300))
    (should (iuiw-jira--stale-p "ABC-1"))
    (puthash "ABC-1" (list (float-time)) iuiw-jira--tickets)
    (should-not (iuiw-jira--stale-p "ABC-1"))
    (puthash "ABC-1" (list (- (float-time) 301)) iuiw-jira--tickets)
    (should (iuiw-jira--stale-p "ABC-1"))))

(ert-deftest iuiw-jira-test-write-keys ()
  (iuiw-jira-test--with-card "---\nstatus: active\n---\n\n## Todo\n"
    (iuiw-jira--write-keys file '("ABC-1"))
    (iuiw-jira--write-keys file '("ABC-1" "ABC-2"))
    (kill-buffer (get-file-buffer file))
    (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                   "---\nstatus: active\njira: [ABC-1, ABC-2]\n---\n\n## Todo\n"))))

(ert-deftest iuiw-jira-test-failed-batch-goes-single ()
  (let ((iuiw-jira--tickets (make-hash-table :test #'equal))
        (out (generate-new-buffer " out"))
        (err (generate-new-buffer " err"))
        fetched)
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 1))
              ((symbol-function 'iuiw-jira--fetch)
               (lambda (keys singly) (setq fetched (list keys singly)))))
      (iuiw-jira--fetched nil '("ABC-1" "ABC-2") nil out err))
    (should (equal fetched '(("ABC-1") ("ABC-2"))))
    (kill-buffer out)
    (kill-buffer err)))

;;; iuiw-jira-test.el ends here
