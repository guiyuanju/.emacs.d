;;; jgy-elfeed-ai.el --- Summarize elfeed entries with an LLM -*- lexical-binding: t; -*-

;;; Commentary:
;; elfeed-show 里按 a 总结当前文章：先抓原文（缓存在 :link-content，与 elfeed 的
;; f 共用），抓不到就用 RSS 内容；总结存进条目 metadata，之后打开文章直接显示。
;; elfeed-search 里按 a 把当前过滤出的条目汇总成一份按订阅源分组的摘要。
;; 后端：claude 和 codex 走 CLI（订阅额度），deepseek 走 gptel（API key）。
;; C-u a 临时换后端；M-x jgy/elfeed-ai-set-backend 改默认。

;;; Code:

(require 'cl-lib)
(require 'dom)
(require 'seq)
(require 'subr-x)
(require 'elfeed)
(require 'elfeed-show)
(require 'elfeed-search)
(require 'elfeed-link)

(declare-function eww-readable-dom "eww")
(declare-function gptel-make-deepseek "gptel-openai-extras")
(declare-function gptel-request "gptel-request")
(declare-function gptel-api-key-from-auth-source "gptel-request")
(declare-function exec-path-from-shell-getenvs "exec-path-from-shell")
(declare-function evil-define-key* "evil-core")
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-use-tools)
(defvar gptel-include-reasoning)
(defvar org-return-follows-link)

(defgroup jgy-elfeed-ai nil
  "Summarize elfeed entries with an LLM."
  :group 'elfeed)

(defcustom jgy-elfeed-ai-backend 'deepseek
  "Backend used to summarize."
  :type '(choice (const claude) (const codex) (const deepseek)))

(defcustom jgy-elfeed-ai-models
  '((claude "haiku" "sonnet")
    (codex nil nil)
    (deepseek "deepseek-v4-flash" "deepseek-v4-flash"))
  "Models per backend, as (BACKEND ENTRY-MODEL DIGEST-MODEL).
nil uses the CLI's own default."
  :type '(alist :key-type symbol :value-type (list (choice string (const nil))
                                                   (choice string (const nil)))))

(defcustom jgy-elfeed-ai-max-chars 20000
  "Longest article text sent for one summary."
  :type 'natural)

(defcustom jgy-elfeed-ai-digest-limit 80
  "Most entries sent in one digest."
  :type 'natural)

(defconst jgy-elfeed-ai--entry-prompt
  "用中文总结下面这篇文章，给 3 到 6 条要点，每条一行，以「- 」开头，只输出要点。
不要编造原文没有的信息。")

(defconst jgy-elfeed-ai--digest-prompt
  "下面是 RSS 阅读器里的一批条目。用中文写一份摘要，输出 Org 格式：
先写「* 要点」，用 3 到 5 条列出最值得看的内容；
然后每个订阅源一个「* 订阅源名」标题，下面每条一行：「- [[链接][标题]]：一句话说明」。
标题不是中文的翻译成中文。只用给出的链接，不要编造内容，只输出 Org 正文。")

;;; Backends

(defun jgy-elfeed-ai--model (backend digest)
  "Return BACKEND's model, for a digest when DIGEST is non-nil."
  (let ((models (alist-get backend jgy-elfeed-ai-models)))
    (if digest (nth 1 models) (nth 0 models))))

(defun jgy-elfeed-ai--run (command input callback &optional output-file)
  "Run COMMAND with INPUT on stdin, then call CALLBACK with (TEXT ERROR).
TEXT is read from OUTPUT-FILE when given, else from stdout."
  (let* ((default-directory temporary-file-directory)
         (out (generate-new-buffer " *jgy-elfeed-ai*"))
         (err (generate-new-buffer " *jgy-elfeed-ai-err*"))
         (proc (make-process
                :name "jgy-elfeed-ai" :buffer out :stderr err
                :command command :connection-type 'pipe :noquery t
                :sentinel
                (lambda (proc _event)
                  (unless (process-live-p proc)
                    (let ((text (string-trim
                                 (if output-file
                                     (with-temp-buffer
                                       (ignore-errors (insert-file-contents output-file))
                                       (buffer-string))
                                   (with-current-buffer out (buffer-string)))))
                          (msg (string-trim (with-current-buffer err (buffer-string)))))
                      (when output-file (ignore-errors (delete-file output-file)))
                      (kill-buffer out)
                      (kill-buffer err)
                      (if (and (zerop (process-exit-status proc))
                               (not (string-empty-p text)))
                          (funcall callback text nil)
                        (funcall callback nil
                                 (car (last (split-string
                                             (if (string-empty-p msg) text msg)
                                             "\n" t)))))))))))
    (process-send-string proc input)
    (process-send-eof proc)))

(defvar jgy-elfeed-ai--deepseek nil
  "The gptel DeepSeek backend, created on first use.")

(defvar jgy/deepseek-api-key)

(defun jgy-elfeed-ai--deepseek-key ()
  "Return the DeepSeek API key from local.el, auth-source or the login shell."
  (or (bound-and-true-p jgy/deepseek-api-key)
      (ignore-errors (gptel-api-key-from-auth-source "api.deepseek.com"))
      (getenv "DEEPSEEK_API_KEY")
      (and (require 'exec-path-from-shell nil t)
           (cdr (assoc "DEEPSEEK_API_KEY"
                       (exec-path-from-shell-getenvs '("DEEPSEEK_API_KEY")))))
      (user-error "No DeepSeek key: set jgy/deepseek-api-key in local.el")))

(defun jgy-elfeed-ai--gptel (model input callback)
  "Send INPUT to DeepSeek MODEL through gptel, then call CALLBACK."
  (require 'gptel)
  (jgy-elfeed-ai--deepseek-key)
  (let* ((gptel-backend
          (or jgy-elfeed-ai--deepseek
              (setq jgy-elfeed-ai--deepseek
                    (gptel-make-deepseek "DeepSeek" :key #'jgy-elfeed-ai--deepseek-key))))
         (gptel-model (intern model))
         (gptel-use-tools nil)
         (gptel-include-reasoning nil))
    (gptel-request input
      :system nil
      :callback (lambda (response info)
                  (cond ((stringp response) (funcall callback (string-trim response) nil))
                        ((null response) (funcall callback nil (plist-get info :status))))))))

(defun jgy-elfeed-ai--request (backend digest input callback)
  "Send INPUT to BACKEND, then call CALLBACK with (TEXT ERROR).
DIGEST picks the digest model."
  (let ((model (jgy-elfeed-ai--model backend digest)))
    (pcase backend
      ('claude
       (jgy-elfeed-ai--run
        `("claude" "-p" ,@(and model (list "--model" model))
          "--no-session-persistence" "--tools" "" "--strict-mcp-config"
          "--setting-sources" "")
        input callback))
      ('codex
       (let ((file (make-temp-file "jgy-elfeed-ai-")))
         (jgy-elfeed-ai--run
          `("codex" "exec" ,@(and model (list "--model" model))
            "--skip-git-repo-check" "--ephemeral" "--sandbox" "read-only"
            "--color" "never" "--output-last-message" ,file "-")
          input callback file)))
      ('deepseek (jgy-elfeed-ai--gptel model input callback))
      (_ (user-error "Unknown backend: %s" backend)))))

(defun jgy-elfeed-ai--read-backend ()
  "Ask for a backend."
  (intern (completing-read "Backend: " '("claude" "codex" "deepseek") nil t nil nil
                           (symbol-name jgy-elfeed-ai-backend))))

;;;###autoload
(defun jgy/elfeed-ai-set-backend (backend)
  "Use BACKEND to summarize from now on."
  (interactive (list (jgy-elfeed-ai--read-backend)))
  (setq jgy-elfeed-ai-backend backend)
  (message "elfeed AI: %s" backend))

;;; Text

(defun jgy-elfeed-ai--html-text (html &optional readable)
  "Return plain text of HTML, the main article only when READABLE."
  (with-temp-buffer
    (insert html)
    (let ((dom (libxml-parse-html-region (point-min) (point-max))))
      (when readable
        (require 'eww)
        (setq dom (or (ignore-errors (eww-readable-dom dom)) dom)))
      (let (parts)
        (named-let walk ((node dom))
          (cond ((stringp node) (push node parts))
                ((memq (dom-tag node) '(script style noscript)))
                (t (mapc #'walk (dom-children node)))))
        (string-trim (replace-regexp-in-string
                      "[ \t\n\r]+" " " (mapconcat #'identity (nreverse parts) " ")))))))

(defun jgy-elfeed-ai--rss-text (entry)
  "Return ENTRY's feed content as plain text."
  (let ((content (elfeed-deref (elfeed-entry-content entry))))
    (cond ((null content) "")
          ((eq (elfeed-entry-content-type entry) 'html) (jgy-elfeed-ai--html-text content))
          (t (string-trim content)))))

(defun jgy-elfeed-ai--article (entry callback)
  "Call CALLBACK with ENTRY's article text, or nil when it can't be fetched."
  (let ((cached (elfeed-deref (elfeed-meta entry :link-content)))
        (link (elfeed-entry-link entry)))
    (cond
     (cached (funcall callback (jgy-elfeed-ai--html-text cached t)))
     ((not link) (funcall callback nil))
     (t (elfeed-curl-retrieve
         link
         (lambda (success)
           (let ((html (and success (buffer-string))))
             (when html (setf (elfeed-meta entry :link-content) (elfeed-ref html)))
             (funcall callback (and html (jgy-elfeed-ai--html-text html t))))))))))

;;; Entry summary

(defface jgy-elfeed-ai-summary-face '((t :inherit font-lock-doc-face))
  "Face of the summary in elfeed-show.")

(defun jgy-elfeed-ai--show-buffers (entry)
  "Return live elfeed-show buffers showing ENTRY."
  (cl-remove-if-not (lambda (buf)
                      (with-current-buffer buf
                        (and (derived-mode-p 'elfeed-show-mode)
                             (eq elfeed-show-entry entry))))
                    (buffer-list)))

(defvar jgy-elfeed-ai--pending (make-hash-table :test #'eq :weakness 'key)
  "Entries being summarized, mapped to (BACKEND . STATUS).")

(defun jgy-elfeed-ai--set-status (entry status &optional summary)
  "Show STATUS for ENTRY, or store SUMMARY when STATUS is nil, then redraw."
  (if status
      (puthash entry status jgy-elfeed-ai--pending)
    (remhash entry jgy-elfeed-ai--pending)
    (when summary (setf (elfeed-meta entry :jgy-ai-summary) summary)))
  (dolist (buf (jgy-elfeed-ai--show-buffers entry))
    (with-current-buffer buf
      (let ((pos (point)))
        (elfeed-show-refresh)
        (goto-char (min pos (point-max)))))))

(defun jgy-elfeed-ai-insert-summary ()
  "Insert the summary, or its progress, above the entry content."
  (when-let* ((summary (or (gethash elfeed-show-entry jgy-elfeed-ai--pending)
                           (elfeed-meta elfeed-show-entry :jgy-ai-summary)))
              (pos (text-property-any (point-min) (point-max) 'elfeed-entry-content t)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char pos)
        (insert (propertize (format "\nAI 总结（%s）\n" (car summary))
                            'face 'elfeed-show-header-face)
                (propertize (cdr summary) 'face 'jgy-elfeed-ai-summary-face)
                "\n")))))

;;;###autoload
(defun jgy/elfeed-ai-summarize (&optional pick)
  "Summarize the shown entry; with PICK, ask which backend to use."
  (interactive "P" elfeed-show-mode)
  (let ((entry elfeed-show-entry)
        (backend (if pick (jgy-elfeed-ai--read-backend) jgy-elfeed-ai-backend)))
    (when (gethash entry jgy-elfeed-ai--pending)
      (user-error "Already summarizing this entry"))
    (jgy-elfeed-ai--set-status entry (cons backend "抓取原文…"))
    (jgy-elfeed-ai--article
     entry
     (lambda (article)
       (let* ((rss (jgy-elfeed-ai--rss-text entry))
              (full (and article (> (length article) (max 500 (length rss)))))
              (text (if full article rss))
              (note (if full "" "（仅基于 RSS 摘要）\n")))
         (if (string-empty-p text)
             (progn (jgy-elfeed-ai--set-status entry nil)
                    (message "elfeed AI: no text to summarize"))
           (jgy-elfeed-ai--set-status entry (cons backend "生成中…"))
           (jgy-elfeed-ai--request
            backend nil
            (format "%s\n\n标题：%s\n\n%s" jgy-elfeed-ai--entry-prompt
                    (elfeed-entry-title entry)
                    (truncate-string-to-width text jgy-elfeed-ai-max-chars))
            (lambda (summary error)
              (jgy-elfeed-ai--set-status
               entry nil (and summary (cons backend (concat note summary))))
              (unless summary
                (message "elfeed AI (%s) failed: %s" backend error))))))))))

;;; Digest

(define-derived-mode jgy-elfeed-ai-digest-mode org-mode "Elfeed Digest"
  "Read an Elfeed digest and follow its entry links."
  (setq-local org-return-follows-link t)
  (read-only-mode 1))

(define-key jgy-elfeed-ai-digest-mode-map (kbd "RET") #'org-open-at-point)
(define-key jgy-elfeed-ai-digest-mode-map (kbd "<return>") #'org-open-at-point)

(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) jgy-elfeed-ai-digest-mode-map
    (kbd "RET") #'org-open-at-point
    (kbd "<return>") #'org-open-at-point))

(defun jgy-elfeed-ai--digest-input (entries)
  "Return the digest prompt for ENTRIES."
  (with-output-to-string
    (princ jgy-elfeed-ai--digest-prompt)
    (dolist (entry entries)
      (let* ((feed (elfeed-entry-feed entry))
             (summary (cdr (elfeed-meta entry :jgy-ai-summary)))
             (text (if (and summary (string-prefix-p "- " summary)) summary
                     (jgy-elfeed-ai--rss-text entry))))
        (princ (format "\n\n订阅源：%s\n标题：%s\n链接：%s\n内容：%s"
                       (or (and feed (elfeed-feed-title feed)) "?")
                       (elfeed-entry-title entry)
                       (format "elfeed:%s#%s"
                               (car (elfeed-entry-id entry))
                               (cdr (elfeed-entry-id entry)))
                       (truncate-string-to-width text 400 nil nil "…")))))))

;;;###autoload
(defun jgy/elfeed-ai-digest (&optional pick)
  "Digest the entries the search buffer shows; with PICK, ask for a backend."
  (interactive "P" elfeed-search-mode)
  (let* ((backend (if pick (jgy-elfeed-ai--read-backend) jgy-elfeed-ai-backend))
         (entries (seq-take elfeed-search-entries jgy-elfeed-ai-digest-limit))
         (filter elfeed-search-filter)
         (buf (get-buffer-create "*elfeed-digest*")))
    (unless entries (user-error "No entries under this filter"))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (jgy-elfeed-ai-digest-mode)
        (insert (format "#+title: %s · %d 条 · %s\n\n生成中…\n" filter (length entries) backend)))
      (read-only-mode 1))
    (display-buffer buf)
    (jgy-elfeed-ai--request
     backend t (jgy-elfeed-ai--digest-input entries)
     (lambda (text error)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (goto-char (point-min))
             (forward-line 2)
             (delete-region (point) (point-max))
             (insert (or text (format "失败：%s\n" error)))
             (goto-char (point-min)))))))))

(add-hook 'elfeed-show-update-hook #'jgy-elfeed-ai-insert-summary)

(provide 'jgy-elfeed-ai)
;;; jgy-elfeed-ai.el ends here
