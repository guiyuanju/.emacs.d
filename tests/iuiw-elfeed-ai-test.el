;;; iuiw-elfeed-ai-test.el --- Digest navigation tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'iuiw-elfeed-ai)
(require 'evil)

(ert-deftest iuiw-elfeed-digest-input-links-to-entry ()
  (let ((entry (elfeed-entry--create :id '("feed" . "entry")
                                    :title "Title" :link "https://example.org")))
    (cl-letf (((symbol-function 'iuiw-elfeed-ai--rss-text) (lambda (_) "Text")))
      (should (string-match-p "链接：elfeed:feed#entry"
                              (iuiw-elfeed-ai--digest-input (list entry)))))))

(ert-deftest iuiw-elfeed-digest-enter-opens-entry-in-evil-states ()
  (let ((entry (elfeed-entry--create :id '("feed" . "entry")))
        (elfeed-db t) (elfeed-db-entries (make-hash-table :test #'equal)) opened)
    (puthash (elfeed-entry-id entry) entry elfeed-db-entries)
    (with-temp-buffer
      (iuiw-elfeed-ai-digest-mode)
      (let ((inhibit-read-only t)) (insert "- [[elfeed:feed#entry][Title]]\n"))
      (goto-char 8)
      (evil-local-mode 1)
      (cl-letf (((symbol-function 'elfeed-db-get-entry)
                 (lambda (id) (should (equal id '("feed" . "entry"))) entry))
                ((symbol-function 'elfeed-show-entry) (lambda (value) (setq opened value))))
        (let ((digest (current-buffer)))
          (dolist (state '(normal motion insert))
            (dolist (key '("RET" "<return>"))
              ;; 打开链接会选中另一个窗口，每次都回到摘要 buffer 再按键。
              (with-current-buffer digest
                (evil-change-state state)
                (setq opened nil)
                (call-interactively (key-binding (kbd key)))
                (should (eq opened entry))))))))))
