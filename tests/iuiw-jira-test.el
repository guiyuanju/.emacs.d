;;; iuiw-jira-test.el --- Jira ticket checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'iuiw-jira)

(defmacro iuiw-jira-test--with-card (text &rest body)
  "Run BODY with a workspace holding project demo of card TEXT."
  (declare (indent 1))
  `(let* ((iuiw-workspace-directory (file-name-as-directory (make-temp-file "iuiw-jira" t)))
          (iuiw-workspace-project-roots nil)
          (iuiw-workspace--cache nil)
          (file (expand-file-name "work/projects/demo/project.md" iuiw-workspace-directory)))
     (make-directory (file-name-directory file) t)
     (write-region ,text nil file nil 'silent)
     (unwind-protect (progn ,@body)
       (delete-directory iuiw-workspace-directory t))))

(ert-deftest iuiw-jira-test-parse-field ()
  (iuiw-jira-test--with-card "---\nstatus: active\njira: [ABC-1, \"ABC-2\"]\n---\n"
    (should (equal (plist-get (iuiw-workspace--card "demo") :jira) '("ABC-1" "ABC-2")))))

(ert-deftest iuiw-jira-test-write-keys ()
  (iuiw-jira-test--with-card "---\nstatus: active\n---\n\n## Todo\n"
    (iuiw-jira--write-keys file '("ABC-1"))
    (iuiw-jira--write-keys file '("ABC-1" "ABC-2"))
    (kill-buffer (get-file-buffer file))
    (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                   "---\nstatus: active\njira: [ABC-1, ABC-2]\n---\n\n## Todo\n"))))

;;; iuiw-jira-test.el ends here
