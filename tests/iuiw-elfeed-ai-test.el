;;; iuiw-elfeed-ai-test.el --- Digest navigation tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'iuiw-elfeed-ai)
(require 'evil)
(require 'elfeed-link)

(ert-deftest iuiw-elfeed-digest-input-links-to-entry ()
  (let ((entry (elfeed-entry--create :id '("feed" . "entry")
                                    :title "Title" :link "https://example.org")))
    (cl-letf (((symbol-function 'iuiw-elfeed-ai--rss-text) (lambda (_) "Text")))
      (should (string-match-p "链接：elfeed:feed#entry"
                              (iuiw-elfeed-ai--digest-input (list entry)))))))

(ert-deftest iuiw-elfeed-digest-keys-in-evil-states ()
  (let ((entry (elfeed-entry--create :id '("feed" . "entry") :link "https://example.org"))
        (elfeed-db t) (elfeed-db-entries (make-hash-table :test #'equal)) browsed opened)
    (puthash (elfeed-entry-id entry) entry elfeed-db-entries)
    (with-temp-buffer
      (iuiw-elfeed-ai-digest-mode)
      (let ((inhibit-read-only t)) (insert "- [[elfeed:feed#entry][Title]]\n"))
      (goto-char 8)
      (evil-local-mode 1)
      (cl-letf (((symbol-function 'elfeed-db-get-entry)
                 (lambda (id) (should (equal id '("feed" . "entry"))) entry))
                ((symbol-function 'browse-url) (lambda (url &rest _) (setq browsed url)))
                ((symbol-function 'elfeed-show-entry) (lambda (value) (setq opened value))))
        (let ((digest (current-buffer)))
          (dolist (state '(normal motion insert))
            (dolist (key '("RET" "<return>" "M-RET" "M-<return>"))
              ;; 打开条目会选中另一个窗口，每次都回到摘要 buffer 再按键。
              (with-current-buffer digest
                (evil-change-state state)
                (setq browsed nil opened nil)
                (call-interactively (key-binding (kbd key)))
                (if (string-prefix-p "M-" key)
                    (should (eq opened entry))
                  (should (equal browsed "https://example.org")))))))))))
