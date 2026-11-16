;;; iuiw-eww-ai.el --- AI summary and translation in eww pages -*- lexical-binding: t; -*-

;;; Commentary:
;; eww 里按 a 在页面顶部插入 AI 总结，再按一次收起；按 t 在每段下插入中文译文，
;; 翻译中再按停止，译完再按收起。C-u 先选后端并忽略缓存重来。后端、缓存和请求
;; 流程用 iuiw-webkit-ai 的，这里只管从 eww buffer 取段落和往里插文字。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'text-property-search)
(require 'eww)
(require 'iuiw-webkit-ai)

(defface iuiw-eww-ai-summary '((t :inherit font-lock-doc-face))
  "Face of the AI summary in eww pages."
  :group 'iuiw-webkit-ai)

(defface iuiw-eww-ai-translation '((t :inherit shadow))
  "Face of translations in eww pages."
  :group 'iuiw-webkit-ai)

(defvar-local iuiw-eww-ai--blocks nil
  "Vector of (END-MARKER . TEXT) for the paragraphs being translated.")

(defun iuiw-eww-ai--page ()
  "Return the URL and HTML source of the current eww page."
  (unless (derived-mode-p 'eww-mode) (user-error "Not in an eww page"))
  (let ((url (plist-get eww-data :url))
        (html (plist-get eww-data :source)))
    (unless (and url html) (user-error "This page has no HTML source"))
    (cons url html)))

(defun iuiw-eww-ai--width ()
  "Return the column to fill inserted text to."
  (min (window-body-width) (or shr-max-width most-positive-fixnum)))

(defun iuiw-eww-ai--fill (start end &optional prefix)
  "Fill each line between START and END on its own, indenting with PREFIX."
  (let ((fill-column (iuiw-eww-ai--width))
        (fill-prefix prefix)
        (end (copy-marker end)))
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (fill-region-as-paragraph (point) (line-end-position))
        (forward-line 1)))
    (set-marker end nil)))

(defun iuiw-eww-ai--remove (kind)
  "Delete the inserted text of KIND; return non-nil if there was any."
  (let ((inhibit-read-only t) found)
    (save-excursion
      (goto-char (point-min))
      (while-let ((match (text-property-search-forward 'iuiw-eww-ai kind t)))
        (delete-region (prop-match-beginning match) (prop-match-end match))
        (setq found t)))
    found))

(defun iuiw-eww-ai--stop ()
  "Stop the running translation in this buffer, if any."
  (when iuiw-webkit-ai--job
    (setcar (cdr iuiw-webkit-ai--job) t)
    (setq iuiw-webkit-ai--job nil))
  (setq iuiw-eww-ai--blocks nil))

;;;###autoload
(defun iuiw-eww-ai-reset ()
  "Forget the translation of the page shown before; for `eww-after-render-hook'."
  (iuiw-eww-ai--stop))

;;; Summary

(defun iuiw-eww-ai--show-summary (buf url head body)
  "Show HEAD and BODY at the top of BUF if it still shows URL."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (equal (plist-get eww-data :url) url)
        (let ((inhibit-read-only t))
          (iuiw-eww-ai--remove 'summary)
          (save-excursion
            (goto-char (point-min))
            (insert (propertize head 'face '(bold iuiw-eww-ai-summary)) "\n"
                    (propertize body 'face 'iuiw-eww-ai-summary) "\n\n")
            (iuiw-eww-ai--fill (point-min) (point))
            (put-text-property (point-min) (point) 'iuiw-eww-ai 'summary)))))))

;;;###autoload
(defun iuiw-eww-ai-summarize (&optional pick)
  "Show an AI summary at the top of the page, or hide it if shown.
With PICK, ask for a backend and write the summary again."
  (interactive "P")
  (pcase-let ((`(,url . ,html) (iuiw-eww-ai--page))
              (buf (current-buffer)))
    (if (and (not pick) (iuiw-eww-ai--remove 'summary))
        (message "已收起总结")
      (let ((backend (if pick (iuiw-elfeed-ai--read-backend) iuiw-elfeed-ai-backend)))
        (goto-char (point-min))
        (iuiw-webkit-ai--summarize
         url backend html pick
         (lambda (head body) (iuiw-eww-ai--show-summary buf url head body)))))))

;;; Translation

(defun iuiw-eww-ai--blocks ()
  "Return (END-MARKER . TEXT) for each paragraph of the page worth translating.
Paragraphs end at blank lines and before list bullets."
  (let ((bullet (concat "[[:blank:]]*" (regexp-quote shr-bullet)))
        blocks)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "[^[:space:]]" nil t)
        (let ((start (match-beginning 0)))
          (goto-char start)
          (while (and (zerop (forward-line 1))
                      (not (eobp))
                      (not (looking-at-p "[[:blank:]]*$"))
                      (not (looking-at-p bullet))))
          (let* ((end (if (bolp) (1- (point)) (point)))
                 (text (string-trim
                        (replace-regexp-in-string
                         "[[:space:]]+" " "
                         (buffer-substring-no-properties start end)))))
            (unless (or (get-text-property start 'iuiw-eww-ai)
                        (< (length text) 2)
                        (not (string-match-p "[A-Za-z぀-ヿ가-힯]" text)))
              (push (cons (copy-marker end) text) blocks))
            (goto-char (max end (1+ start)))))))
    (vconcat (nreverse blocks))))

(defun iuiw-eww-ai--insert (buf blocks pairs)
  "Insert PAIRS, a list of (INDEX . TRANSLATION), under BLOCKS in BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (eq iuiw-eww-ai--blocks blocks)
        (let ((inhibit-read-only t))
          (save-excursion
            (pcase-dolist (`(,index . ,target) pairs)
              (goto-char (car (aref blocks index)))
              (let ((start (point))
                    (prefix (make-string (current-indentation) ?\s)))
                (insert "\n" prefix (propertize target 'face 'iuiw-eww-ai-translation))
                (iuiw-eww-ai--fill (1+ start) (point) prefix)
                (put-text-property start (point) 'iuiw-eww-ai 'translation)))))))))

;;;###autoload
(defun iuiw-eww-ai-translate (&optional pick)
  "Put a Chinese translation under each paragraph of the page.
Stop a running translation, or remove a shown one.  With PICK, ask for a
backend and translate again without the cache."
  (interactive "P")
  (pcase-let ((`(,url . ,_) (iuiw-eww-ai--page))
              (buf (current-buffer)))
    (cond
     ((and iuiw-webkit-ai--job (equal (car iuiw-webkit-ai--job) url))
      (iuiw-eww-ai--stop)
      (iuiw-eww-ai--remove 'translation)
      (message "翻译已停止"))
     ((and (not pick) (iuiw-eww-ai--remove 'translation))
      (iuiw-eww-ai--stop)
      (message "已收起译文"))
     (t
      (iuiw-eww-ai--remove 'translation)
      (let ((backend (if pick (iuiw-elfeed-ai--read-backend) iuiw-elfeed-ai-backend))
            (blocks (iuiw-eww-ai--blocks)))
        (if (zerop (length blocks))
            (message "这页没有要翻译的段落")
          (setq iuiw-eww-ai--blocks blocks)
          (iuiw-webkit-ai--translate
           url backend (mapcar #'cdr blocks) pick
           (lambda (pairs) (iuiw-eww-ai--insert buf blocks pairs)))))))))

(provide 'iuiw-eww-ai)
;;; iuiw-eww-ai.el ends here
