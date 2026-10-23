;;; iuiw-elfeed-ai.el --- Summarize elfeed entries with an LLM -*- lexical-binding: t; -*-

;;; Commentary:
;; elfeed-show 里按 a 总结当前文章：先抓原文（缓存在 :link-content，与 elfeed 的
;; f 共用），抓不到就用 RSS 内容；总结存进条目 metadata，之后打开文章直接显示。
;; elfeed-search 里按 a 给当前行（或 visual 选中的行）写一句话总结，显示在行尾；
;; 按 A 在右侧窗口把当前过滤出的条目汇总，有关注重点时按重点排；C-u A 先改重点。
;; 后端：claude 和 codex 走 CLI（订阅额度），deepseek 走 gptel（API key），汇总时流式输出。
;; C-u a 临时换后端；gA 改默认。

;;; Code:

(require 'cl-lib)
(require 'dom)
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
(declare-function org-open-at-point "org")
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-use-tools)
(defvar gptel-include-reasoning)
(defvar org-return-follows-link)

(defgroup iuiw-elfeed-ai nil
  "Summarize elfeed entries with an LLM."
  :group 'elfeed)

(defcustom iuiw-elfeed-ai-backend 'deepseek
  "Backend used to summarize."
  :type '(choice (const claude) (const codex) (const deepseek)))

(defcustom iuiw-elfeed-ai-models
  '((claude "haiku" "sonnet")
    (codex nil nil)
    (deepseek "deepseek-flash" "deepseek-flash"))
  "Models per backend, as (BACKEND ENTRY-MODEL DIGEST-MODEL).
nil uses the CLI's own default."
  :type '(alist :key-type symbol :value-type (list (choice string (const nil))
                                                   (choice string (const nil)))))

(defcustom iuiw-elfeed-ai-max-chars 20000
  "Longest article text sent for one summary."
  :type 'natural)

(defcustom iuiw-elfeed-ai-timeout 180
  "Seconds before a DeepSeek request gives up."
  :type 'natural)

(defcustom iuiw-elfeed-ai-digest-limit 80
  "Most entries sent in one digest."
  :type 'natural)

(defcustom iuiw-elfeed-ai-digest-focus ""
  "What the digest should put first, in plain words; empty for none."
  :type 'string)

(defcustom iuiw-elfeed-ai-oneline-batch 20
  "Most entries sent in one one-line summary request."
  :type 'natural)

(defcustom iuiw-elfeed-ai-oneline-chars 1500
  "Longest text sent per entry for a one-line summary."
  :type 'natural)

(defconst iuiw-elfeed-ai--entry-prompt
  "用中文总结下面这篇文章，给 3 到 6 条要点，每条一行，以「- 」开头，只输出要点。
不要编造原文没有的信息。")

(defconst iuiw-elfeed-ai--oneline-prompt
  "下面是若干篇文章，每篇以「## 编号」开头。为每篇写一句中文总结，不超过 40 字，
说清讲了什么，不要复述标题。每篇输出一行「编号: 总结」，按编号顺序，只输出这些行。
不要编造原文没有的信息。")

(defconst iuiw-elfeed-ai--focus-prompt
  "下面是 RSS 阅读器里的一批条目。我的关注重点：%s
用中文写一份摘要，输出 Org 格式：
先写「* 与关注重点相关」，按相关程度排序，每条「- [[链接][标题]]：两三句，讲了什么、为什么值得看」，
没有相关的就写「- 无」；然后写「* 其他值得看的」，最多 8 条，每条「- [[链接][标题]]：一句话说明」；
最后写「* 其余」，每条一行「- [[链接][标题]]」。
标题不是中文的翻译成中文。只用给出的链接，不要编造内容，只输出 Org 正文。")

(defconst iuiw-elfeed-ai--digest-prompt
  "下面是 RSS 阅读器里的一批条目。用中文写一份摘要，输出 Org 格式：
先写「* 要点」，用 3 到 5 条列出最值得看的内容；
然后每个订阅源一个「* 订阅源名」标题，下面每条一行：「- [[链接][标题]]：一句话说明」。
标题不是中文的翻译成中文。只用给出的链接，不要编造内容，只输出 Org 正文。")

;; 同步模块靠它把总结记进仓库。
(defvar iuiw-elfeed-ai-summary-functions nil
  "Functions called with (ENTRY KIND VALUE) after a summary is stored.
KIND is `summary' with VALUE (BACKEND . TEXT), or `oneline' with VALUE a string.")

;;; Backends

(defun iuiw-elfeed-ai--model (backend digest)
  "Return BACKEND's model, for a digest when DIGEST is non-nil."
  (let ((models (alist-get backend iuiw-elfeed-ai-models)))
    (if digest (nth 1 models) (nth 0 models))))

(defun iuiw-elfeed-ai--run (command input callback &optional output-file)
  "Run COMMAND with INPUT on stdin, then call CALLBACK with (TEXT ERROR).
TEXT is read from OUTPUT-FILE when given, else from stdout."
  (let* ((default-directory temporary-file-directory)
         (out (generate-new-buffer " *iuiw-elfeed-ai*"))
         (err (generate-new-buffer " *iuiw-elfeed-ai-err*"))
         (proc (make-process
                :name "iuiw-elfeed-ai" :buffer out :stderr err
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

(defvar iuiw-elfeed-ai--deepseek nil
  "The gptel DeepSeek backend, created on first use.")

(defvar iuiw-deepseek-api-key)

(defun iuiw-elfeed-ai--deepseek-key ()
  "Return the DeepSeek API key from local.el, auth-source or the login shell."
  (or (bound-and-true-p iuiw-deepseek-api-key)
      (ignore-errors (gptel-api-key-from-auth-source "api.deepseek.com"))
      (getenv "DEEPSEEK_API_KEY")
      (and (require 'exec-path-from-shell nil t)
           (cdr (assoc "DEEPSEEK_API_KEY"
                       (exec-path-from-shell-getenvs '("DEEPSEEK_API_KEY")))))
      (user-error "No DeepSeek key: set iuiw-deepseek-api-key in local.el")))

(defun iuiw-elfeed-ai--gptel (model input callback &optional on-chunk)
  "Send INPUT to DeepSeek MODEL through gptel, then call CALLBACK.
With ON-CHUNK, stream and call it with each piece of text as it arrives."
  (require 'gptel)
  (iuiw-elfeed-ai--deepseek-key)
  (let* ((gptel-backend
          (or iuiw-elfeed-ai--deepseek
              (setq iuiw-elfeed-ai--deepseek
                    (gptel-make-deepseek
                     "DeepSeek" :key #'iuiw-elfeed-ai--deepseek-key
                     :curl-args (lambda ()
                                  (list "--max-time"
                                        (number-to-string iuiw-elfeed-ai-timeout)))))))
         (gptel-model (intern model))
         (gptel-use-tools nil)
         (gptel-include-reasoning nil))
    (if on-chunk
        (let ((parts nil))
          (gptel-request input
            :system nil :stream t
            :callback (lambda (response info)
                        (cond ((stringp response)
                               (push response parts)
                               (funcall on-chunk response))
                              ((eq response t)
                               (funcall callback (apply #'concat (nreverse parts)) nil))
                              ((null response)
                               (funcall callback nil (plist-get info :status)))))))
      (gptel-request input
        :system nil
        :callback (lambda (response info)
                    (cond ((stringp response) (funcall callback (string-trim response) nil))
                          ((null response) (funcall callback nil (plist-get info :status)))))))))

(defun iuiw-elfeed-ai--request (backend digest input callback &optional on-chunk)
  "Send INPUT to BACKEND, then call CALLBACK with (TEXT ERROR).
DIGEST picks the digest model.  ON-CHUNK gets streamed text where the
backend can stream; CALLBACK still gets the whole text."
  (let ((model (iuiw-elfeed-ai--model backend digest)))
    ;; 这里常在进程回调里运行，报错会被吞掉，所以转给 CALLBACK。
    (condition-case err
        (pcase backend
          ('claude
           (iuiw-elfeed-ai--run
            `("claude" "-p" ,@(and model (list "--model" model))
              "--no-session-persistence" "--tools" "" "--strict-mcp-config"
              "--setting-sources" "")
            input callback))
          ('codex
           (let ((file (make-temp-file "iuiw-elfeed-ai-")))
             (iuiw-elfeed-ai--run
              `("codex" "exec" ,@(and model (list "--model" model))
                "--skip-git-repo-check" "--ephemeral" "--sandbox" "read-only"
                "--color" "never" "--output-last-message" ,file "-")
              input callback file)))
          ('deepseek (iuiw-elfeed-ai--gptel model input callback on-chunk))
          (_ (user-error "Unknown backend: %s" backend)))
      (error (funcall callback nil (error-message-string err))))))

(defun iuiw-elfeed-ai--read-backend ()
  "Ask for a backend."
  (intern (completing-read "Backend: " '("claude" "codex" "deepseek") nil t nil nil
                           (symbol-name iuiw-elfeed-ai-backend))))

;;;###autoload
(defun iuiw-elfeed-ai-set-backend (backend)
  "Use BACKEND to summarize from now on."
  (interactive (list (iuiw-elfeed-ai--read-backend)))
  (setq iuiw-elfeed-ai-backend backend)
  (message "elfeed AI: %s" backend))

;;; Text

(defun iuiw-elfeed-ai--html-text (html &optional readable)
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

(defun iuiw-elfeed-ai--rss-text (entry)
  "Return ENTRY's feed content as plain text."
  (let ((content (elfeed-deref (elfeed-entry-content entry))))
    (cond ((null content) "")
          ((eq (elfeed-entry-content-type entry) 'html) (iuiw-elfeed-ai--html-text content))
          (t (string-trim content)))))

(defun iuiw-elfeed-ai--article (entry callback)
  "Call CALLBACK with ENTRY's article text, or nil when it can't be fetched."
  (let ((cached (elfeed-deref (elfeed-meta entry :link-content)))
        (link (elfeed-entry-link entry)))
    (cond
     (cached (funcall callback (iuiw-elfeed-ai--html-text cached t)))
     ((not link) (funcall callback nil))
     (t (elfeed-curl-retrieve
         link
         (lambda (success)
           (let ((html (and success (buffer-string))))
             (when html (setf (elfeed-meta entry :link-content) (elfeed-ref html)))
             (funcall callback (and html (iuiw-elfeed-ai--html-text html t))))))))))

;;; Entry summary

(defface iuiw-elfeed-ai-summary-face '((t :inherit font-lock-doc-face))
  "Face of the summary in elfeed-show.")

(defun iuiw-elfeed-ai--show-buffers (entry)
  "Return live elfeed-show buffers showing ENTRY."
  (cl-remove-if-not (lambda (buf)
                      (with-current-buffer buf
                        (and (derived-mode-p 'elfeed-show-mode)
                             (eq elfeed-show-entry entry))))
                    (buffer-list)))

(defvar iuiw-elfeed-ai--pending (make-hash-table :test #'eq :weakness 'key)
  "Entries being summarized, mapped to (BACKEND . STATUS).")

(defun iuiw-elfeed-ai--set-status (entry status &optional summary)
  "Show STATUS for ENTRY, or store SUMMARY when STATUS is nil, then redraw."
  (if status
      (puthash entry status iuiw-elfeed-ai--pending)
    (remhash entry iuiw-elfeed-ai--pending)
    (when summary
      (setf (elfeed-meta entry :iuiw-ai-summary) summary)
      (run-hook-with-args 'iuiw-elfeed-ai-summary-functions entry 'summary summary)))
  (dolist (buf (iuiw-elfeed-ai--show-buffers entry))
    (with-current-buffer buf
      (let ((pos (point)))
        (elfeed-show-refresh)
        (goto-char (min pos (point-max)))))))

(defun iuiw-elfeed-ai-insert-summary ()
  "Insert the summary, or its progress, above the entry content."
  (when-let* ((summary (or (gethash elfeed-show-entry iuiw-elfeed-ai--pending)
                           (elfeed-meta elfeed-show-entry :iuiw-ai-summary)))
              (pos (text-property-any (point-min) (point-max) 'elfeed-entry-content t)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char pos)
        (insert (propertize (format "\nAI 总结（%s）\n" (car summary))
                            'face 'elfeed-show-header-face)
                (propertize (cdr summary) 'face 'iuiw-elfeed-ai-summary-face)
                "\n")))))

;;;###autoload
(defun iuiw-elfeed-ai-summarize (&optional pick)
  "Summarize the shown entry; with PICK, ask which backend to use."
  (interactive "P" elfeed-show-mode)
  (let ((entry elfeed-show-entry)
        (backend (if pick (iuiw-elfeed-ai--read-backend) iuiw-elfeed-ai-backend)))
    (when (gethash entry iuiw-elfeed-ai--pending)
      (user-error "Already summarizing this entry"))
    (iuiw-elfeed-ai--set-status entry (cons backend "抓取原文…"))
    (iuiw-elfeed-ai--article
     entry
     (lambda (article)
       (let* ((rss (iuiw-elfeed-ai--rss-text entry))
              (full (and article (> (length article) (max 500 (length rss)))))
              (text (if full article rss))
              (note (if full "" "（仅基于 RSS 摘要）\n")))
         (if (string-empty-p text)
             (progn (iuiw-elfeed-ai--set-status entry nil)
                    (message "elfeed AI: no text to summarize"))
           (iuiw-elfeed-ai--set-status entry (cons backend "生成中…"))
           (iuiw-elfeed-ai--request
            backend nil
            (format "%s\n\n标题：%s\n\n%s" iuiw-elfeed-ai--entry-prompt
                    (elfeed-entry-title entry)
                    (truncate-string-to-width text iuiw-elfeed-ai-max-chars))
            (lambda (summary error)
              (iuiw-elfeed-ai--set-status
               entry nil (and summary (cons backend (concat note summary))))
              (unless summary
                (message "elfeed AI (%s) failed: %s" backend error))))))))))

;;; One-line summary

(defface iuiw-elfeed-ai-oneline-face '((t :inherit shadow))
  "Face of the one-line summary in elfeed-search.")

(defvar iuiw-elfeed-ai--oneline-pending (make-hash-table :test #'eq :weakness 'key)
  "Entries waiting for a one-line summary.")

(defun iuiw-elfeed-ai-print-entry (entry)
  "Print ENTRY like elfeed does, then its one-line summary."
  (elfeed-search-print-entry--default entry)
  (when-let* ((text (if (gethash entry iuiw-elfeed-ai--oneline-pending) "…"
                      (elfeed-meta entry :iuiw-ai-oneline))))
    (insert "  " (propertize text 'face 'iuiw-elfeed-ai-oneline-face))))

(defun iuiw-elfeed-ai-oneline-eldoc (&rest _)
  "Return the one-line summary of the entry at point, for eldoc."
  (when-let* ((entry (elfeed-search-selected t)))
    (elfeed-meta entry :iuiw-ai-oneline)))

(defun iuiw-elfeed-ai--redraw (entries)
  "Redraw ENTRIES in the search buffer."
  (when-let* ((buf (get-buffer "*elfeed-search*")))
    (with-current-buffer buf
      (apply #'elfeed-search-update-entry entries))))

(defun iuiw-elfeed-ai--oneline-text (entry callback)
  "Call CALLBACK with the text to summarize ENTRY from."
  (let ((summary (cdr (elfeed-meta entry :iuiw-ai-summary)))
        (rss (iuiw-elfeed-ai--rss-text entry)))
    (cond (summary (funcall callback summary))
          ((>= (length rss) 300) (funcall callback rss))
          (t (iuiw-elfeed-ai--article
              entry (lambda (article) (funcall callback (or article rss))))))))

(defun iuiw-elfeed-ai--parse-oneline (text)
  "Return TEXT's「编号: 总结」lines as an alist of (NUMBER . SUMMARY)."
  (let (lines)
    (dolist (line (split-string text "\n" t) lines)
      (when (string-match "\\`[ \t#]*\\([0-9]+\\)[.:：、．)）]+[ \t]*\\(.+\\)" line)
        (push (cons (string-to-number (match-string 1 line))
                    (string-trim (match-string 2 line)))
              lines)))))

(defun iuiw-elfeed-ai--oneline-request (backend entries texts)
  "Ask BACKEND for one-line summaries of ENTRIES from TEXTS, then store them."
  (iuiw-elfeed-ai--request
   backend nil
   (with-output-to-string
     (princ iuiw-elfeed-ai--oneline-prompt)
     (cl-loop for entry in entries for text in texts for i from 1
              do (princ (format "\n\n## %d\n标题：%s\n%s" i (elfeed-entry-title entry)
                                (truncate-string-to-width
                                 (or text "") iuiw-elfeed-ai-oneline-chars)))))
   (lambda (reply error)
     (let ((lines (and reply (iuiw-elfeed-ai--parse-oneline reply))))
       (cl-loop for entry in entries for i from 1
                do (remhash entry iuiw-elfeed-ai--oneline-pending)
                (when-let* ((line (alist-get i lines)))
                  (setf (elfeed-meta entry :iuiw-ai-oneline) line)
                  (run-hook-with-args 'iuiw-elfeed-ai-summary-functions
                                      entry 'oneline line)))
       (iuiw-elfeed-ai--redraw entries)
       (unless lines
         (message "elfeed AI (%s) failed: %s" backend (or error "no summary")))))))

(defun iuiw-elfeed-ai--oneline-batch (backend entries)
  "Collect the texts of ENTRIES, then summarize them with BACKEND."
  (let ((texts (make-list (length entries) nil))
        (left (length entries)))
    (cl-loop for entry in entries for cell on texts
             do (let ((cell cell))
                  (iuiw-elfeed-ai--oneline-text
                   entry
                   (lambda (text)
                     (setcar cell text)
                     (when (zerop (cl-decf left))
                       (iuiw-elfeed-ai--oneline-request backend entries texts))))))))

;;;###autoload
(defun iuiw-elfeed-ai-oneline (&optional pick)
  "Summarize the selected entries in one line each; with PICK, ask for a backend."
  (interactive "P" elfeed-search-mode)
  (let ((backend (if pick (iuiw-elfeed-ai--read-backend) iuiw-elfeed-ai-backend))
        (entries (cl-remove-if (lambda (entry) (gethash entry iuiw-elfeed-ai--oneline-pending))
                               (elfeed-search-selected))))
    (unless entries (user-error "No entry to summarize"))
    (when (use-region-p) (deactivate-mark))
    (dolist (entry entries) (puthash entry t iuiw-elfeed-ai--oneline-pending))
    (iuiw-elfeed-ai--redraw entries)
    (dolist (batch (seq-partition entries iuiw-elfeed-ai-oneline-batch))
      (iuiw-elfeed-ai--oneline-batch backend batch))))

;;; Digest

(defvar-local iuiw-elfeed-ai--digest-args nil
  "The (BACKEND ENTRIES FILTER) of the digest in this buffer.")

(defun iuiw-elfeed-ai-digest-open ()
  "Follow the link at point in another window, keeping the digest on the side."
  (interactive)
  (let ((buf (current-buffer))
        (pos (point)))
    (select-window (or (get-mru-window nil nil t) (selected-window)))
    (with-current-buffer buf
      (save-excursion (goto-char pos) (org-open-at-point)))))

(defun iuiw-elfeed-ai-digest-regenerate ()
  "Write this digest again."
  (interactive)
  (unless iuiw-elfeed-ai--digest-args
    (user-error "This digest was loaded from a file; press A in elfeed for a new one"))
  (apply #'iuiw-elfeed-ai--digest iuiw-elfeed-ai--digest-args))

(defun iuiw-elfeed-ai-digest-edit-focus ()
  "Change the focus, then write this digest again."
  (interactive)
  (iuiw-elfeed-ai--read-focus)
  (iuiw-elfeed-ai-digest-regenerate))

(define-derived-mode iuiw-elfeed-ai-digest-mode org-mode "Elfeed Digest"
  "Read an Elfeed digest and follow its entry links."
  (setq-local org-return-follows-link t)
  (read-only-mode 1))

(define-key iuiw-elfeed-ai-digest-mode-map (kbd "RET") #'iuiw-elfeed-ai-digest-open)
(define-key iuiw-elfeed-ai-digest-mode-map (kbd "<return>") #'iuiw-elfeed-ai-digest-open)

(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) iuiw-elfeed-ai-digest-mode-map
    (kbd "RET") #'iuiw-elfeed-ai-digest-open
    (kbd "<return>") #'iuiw-elfeed-ai-digest-open
    "q" #'quit-window
    "gr" #'iuiw-elfeed-ai-digest-regenerate
    "e" #'iuiw-elfeed-ai-digest-edit-focus))

(defun iuiw-elfeed-ai--read-focus ()
  "Ask for the digest focus and keep it."
  (setq iuiw-elfeed-ai-digest-focus
        (string-trim (read-string "关注重点（留空不设）: " iuiw-elfeed-ai-digest-focus))))

(defun iuiw-elfeed-ai--digest-input (entries)
  "Return the digest prompt for ENTRIES."
  (with-output-to-string
    (princ (if (string-empty-p iuiw-elfeed-ai-digest-focus)
               iuiw-elfeed-ai--digest-prompt
             (format iuiw-elfeed-ai--focus-prompt iuiw-elfeed-ai-digest-focus)))
    (dolist (entry entries)
      (let* ((feed (elfeed-entry-feed entry))
             (text (or (cdr (elfeed-meta entry :iuiw-ai-summary))
                       (elfeed-meta entry :iuiw-ai-oneline)
                       (iuiw-elfeed-ai--rss-text entry))))
        (princ (format "\n\n订阅源：%s\n标题：%s\n链接：%s\n内容：%s"
                       (or (and feed (elfeed-feed-title feed)) "?")
                       (elfeed-entry-title entry)
                       (format "elfeed:%s#%s"
                               (car (elfeed-entry-id entry))
                               (cdr (elfeed-entry-id entry)))
                       (truncate-string-to-width text 400 nil nil "…")))))))

(defun iuiw-elfeed-ai--digest (backend entries filter)
  "Digest ENTRIES with BACKEND into the side window, titled by FILTER."
  (let ((buf (get-buffer-create "*elfeed-digest*"))
        (focus iuiw-elfeed-ai-digest-focus)
        body)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (iuiw-elfeed-ai-digest-mode)
        (setq iuiw-elfeed-ai--digest-args (list backend entries filter))
        (insert (format "#+title: %s · %d 条 · %s\n" filter (length entries) backend)
                (if (string-empty-p focus) "" (format "#+subtitle: 关注：%s\n" focus))
                "\n")
        (setq body (point-marker))
        (insert "生成中…\n")))
    (display-buffer buf '(display-buffer-in-side-window
                          (side . right) (window-width . 0.4)))
    (let ((started nil))
      (cl-flet ((write (text &optional replace)
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (let ((inhibit-read-only t))
                        (save-excursion
                          (when (or replace (not started))
                            (delete-region body (point-max))
                            (setq started t))
                          (goto-char (point-max))
                          (insert text)))))))
        (iuiw-elfeed-ai--request
         backend t (iuiw-elfeed-ai--digest-input entries)
         (lambda (text error)
           (write (if text (concat (string-trim text) "\n") (format "失败：%s\n" error)) t))
         #'write)))))

(defun iuiw-elfeed-ai-digest-request (entries callback)
  "Digest ENTRIES with the default backend, then call CALLBACK with (TEXT ERROR)."
  (iuiw-elfeed-ai--request iuiw-elfeed-ai-backend t
                          (iuiw-elfeed-ai--digest-input entries) callback))

;;;###autoload
(defun iuiw-elfeed-ai-digest (&optional edit-focus)
  "Digest the entries the search buffer shows in a side window.
With EDIT-FOCUS, change the focus first."
  (interactive "P" elfeed-search-mode)
  (let ((entries (seq-take elfeed-search-entries iuiw-elfeed-ai-digest-limit)))
    (unless entries (user-error "No entries under this filter"))
    (when edit-focus (iuiw-elfeed-ai--read-focus))
    (iuiw-elfeed-ai--digest iuiw-elfeed-ai-backend entries elfeed-search-filter)))

(add-hook 'elfeed-show-update-hook #'iuiw-elfeed-ai-insert-summary)
(setq elfeed-search-print-entry-function #'iuiw-elfeed-ai-print-entry)
(add-hook 'elfeed-search-mode-hook
          (lambda ()
            (add-hook 'eldoc-documentation-functions #'iuiw-elfeed-ai-oneline-eldoc nil t)
            (eldoc-mode 1)))

(provide 'iuiw-elfeed-ai)
;;; iuiw-elfeed-ai.el ends here
