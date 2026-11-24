;;; overlook-agent-diff-test.el --- Agents' edits as diffs -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-agent-diff)

(defmacro overlook-agent-diff-test--with-agent (agent &rest body)
  "Run BODY with AGENT bound to a fresh agent buffer, killed after."
  (declare (indent 1))
  `(let ((,agent (generate-new-buffer "diff-agent")))
     (unwind-protect
         (progn ,@body)
       (when-let* ((diff (get-buffer (overlook-agent-diff--buffer-name ,agent))))
         (kill-buffer diff))
       (kill-buffer ,agent))))

(defun overlook-agent-diff-test--edit (agent id file old new &optional status)
  "Send AGENT a tool event ID editing FILE from OLD to NEW, of STATUS."
  (overlook-agent-diff--event
   agent (list :type 'tool :id id :status (or status "completed")
               :diffs (list (list :file file :old old :new new)))))

(defun overlook-agent-diff-test--text (agent)
  "Text of AGENT's diff buffer."
  (with-current-buffer (overlook-agent-diff--buffer-name agent)
    (buffer-string)))

(ert-deftest overlook-agent-diff-numbers-a-snippet-edit-by-its-place-in-the-file ()
  (let ((file (make-temp-file "overlook-diff" nil ".txt"
                              (mapconcat (lambda (n) (format "line %d\n" n))
                                         (number-sequence 1 20) ""))))
    (unwind-protect
        (overlook-agent-diff-test--with-agent agent
          ;; The file already holds the edit when the tool call completes.
          (with-temp-file file
            (insert (mapconcat (lambda (n) (if (= n 12) "changed\n" (format "line %d\n" n)))
                               (number-sequence 1 20) "")))
          (overlook-agent-diff-test--edit agent "t1" file "line 12\n" "changed\n")
          (let ((text (overlook-agent-diff-test--text agent)))
            (should (string-match-p (regexp-quote (concat "--- " file)) text))
            (should (string-match-p "^@@ -9,7 \\+9,7 @@" text))
            (should (string-match-p "^-line 12$" text))
            (should (string-match-p "^\\+changed$" text))
            (should (string-match-p "^ line 11$" text))))
      (delete-file file))))

(ert-deftest overlook-agent-diff-falls-back-to-the-snippets ()
  (overlook-agent-diff-test--with-agent agent
    (overlook-agent-diff-test--edit agent "t1" "/nonexistent/file.el" "a\n" "b\n")
    (let ((text (overlook-agent-diff-test--text agent)))
      (should (string-match-p "^-a$" text))
      (should (string-match-p "^\\+b$" text)))))

(ert-deftest overlook-agent-diff-keeps-a-turn-and-starts-afresh-on-the-next ()
  (overlook-agent-diff-test--with-agent agent
    (overlook-agent-diff-test--edit agent "t1" "/nonexistent/a" "a\n" "b\n" "in_progress")
    (should-not (get-buffer (overlook-agent-diff--buffer-name agent)))
    (overlook-agent-diff-test--edit agent "t1" "/nonexistent/a" "a\n" "b\n")
    (overlook-agent-diff-test--edit agent "t1" "/nonexistent/a" "a\n" "b\n")
    (overlook-agent-diff-test--edit agent "t2" "/nonexistent/c" "c\n" "d\n")
    (let ((text (overlook-agent-diff-test--text agent)))
      (should (= 1 (with-temp-buffer
                     (insert text)
                     (how-many "^\\+b$" (point-min) (point-max)))))
      (should (string-match-p "^\\+d$" text)))
    (overlook-agent-diff--event agent '(:type prompt :text "next"))
    ;; The past turn stays until the next edit replaces it.
    (should (string-match-p "^\\+d$" (overlook-agent-diff-test--text agent)))
    (overlook-agent-diff-test--edit agent "t3" "/nonexistent/e" "e\n" "f\n")
    (let ((text (overlook-agent-diff-test--text agent)))
      (should-not (string-match-p "^\\+d$" text))
      (should (string-match-p "^\\+f$" text)))))

(ert-deftest overlook-agent-diff-highlights-the-code-on-the-changed-lines ()
  (overlook-agent-diff-test--with-agent agent
    (overlook-agent-diff-test--edit agent "t1" "/nonexistent/a.el"
                                    "(defun old () nil)\n" "(defun new () t)\n")
    (with-current-buffer (overlook-agent-diff--buffer-name agent)
      (should (eq diff-font-lock-syntax 'hunk-only))
      (font-lock-mode 1)
      (font-lock-ensure)
      (let (faces)
        (dolist (overlay (overlays-in (point-min) (point-max)))
          (push (overlay-get overlay 'face) faces))
        (should (memq 'font-lock-keyword-face (flatten-tree faces)))))))

(ert-deftest overlook-agent-diff-pops-up-only-beside-a-shown-agent ()
  (overlook-agent-diff-test--with-agent agent
    (let (shown)
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (buffer &rest _) (push buffer shown) nil)))
        (overlook-agent-diff-test--edit agent "t1" "/nonexistent/a" "a\n" "b\n")
        (should-not shown)
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (buffer &rest _) (and (eq buffer agent) (selected-window)))))
          (overlook-agent-diff-test--edit agent "t2" "/nonexistent/c" "c\n" "d\n"))
        (should (equal shown (list (get-buffer (overlook-agent-diff--buffer-name agent)))))))))

;;; overlook-agent-diff-test.el ends here
