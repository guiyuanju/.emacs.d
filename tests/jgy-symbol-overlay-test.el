;;; jgy-symbol-overlay-test.el --- Project-wide highlight checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'jgy-symbol-overlay)

(ert-deftest jgy-symbol-overlay-spreads-across-project ()
  (let* ((dir (file-name-as-directory (make-temp-file "symbol-overlay" t)))
         (find-file-hook (cons #'jgy-symbol-overlay-inherit find-file-hook))
         (count (lambda (buffer)
                  (with-current-buffer buffer
                    (length (symbol-overlay-get-list 0 "foo")))))
         a b c)
    (unwind-protect
        (progn
          (call-process "git" nil nil nil "init" "-q" dir)
          (dolist (name '("a.el" "b.el" "c.el"))
            (with-temp-file (expand-file-name name dir) (insert "foo bar foo\n")))
          (setq a (find-file-noselect (expand-file-name "a.el" dir))
                b (find-file-noselect (expand-file-name "b.el" dir)))
          (with-current-buffer a
            (goto-char (point-min))
            (jgy-symbol-overlay-put))
          (should (= 2 (funcall count b)))
          (should (equal (buffer-local-value 'symbol-overlay-keywords-alist a)
                         (buffer-local-value 'symbol-overlay-keywords-alist b)))
          (setq c (find-file-noselect (expand-file-name "c.el" dir)))
          (should (= 2 (funcall count c)))
          (with-current-buffer b
            (goto-char (point-min))
            (jgy-symbol-overlay-put))
          (should (= 0 (funcall count a)))
          (should (= 0 (funcall count c))))
      (mapc (lambda (buffer) (when buffer (kill-buffer buffer))) (list a b c))
      (delete-directory dir t))))
