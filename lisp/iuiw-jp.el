;;; iuiw-jp.el --- jp-notes 的 gptel 工具 -*- lexical-binding: t; -*-

;;; Commentary:

;; 人设 jp（~/workspace/me/personas/jp/，engine 为 gptel）用这两个工具查和记日语笔记。
;; 工具经 `jp' 命令读写 jp-notes-data 仓库，异步运行：jp add 会推送到 GitHub，不能卡住 Emacs。
;; 同时注册人设用的 DeepSeek 后端。

;;; Code:

(require 'gptel)
(require 'gptel-openai-extras)
(require 'iuiw-jp-list)

(defvar iuiw-deepseek-api-key)

(defcustom iuiw-jp-search-limit 1500
  "Most characters of search results handed to the model."
  :type 'natnum
  :group 'gptel)

(defvar iuiw-jp--queue nil
  "Calls of `iuiw-jp--start' waiting, oldest first, as argument lists.")

(defvar iuiw-jp--running nil
  "Non-nil while a jp process runs.")

(defun iuiw-jp--run (callback args &optional input)
  "Run jp with ARGS, feeding it INPUT, then call CALLBACK with its output.
One jp runs at a time: the model calls tools in parallel, and two jp
processes would contend for the repository's git index."
  (setq iuiw-jp--queue (append iuiw-jp--queue (list (list callback args input))))
  (unless iuiw-jp--running (iuiw-jp--next)))

(defun iuiw-jp--next ()
  "Start the oldest queued jp call, if any."
  (if-let* ((call (pop iuiw-jp--queue)))
      (progn (setq iuiw-jp--running t)
             (condition-case err
                 (apply #'iuiw-jp--start call)
               (error (setq iuiw-jp--running nil)
                      (funcall (car call) (format "Error: %s" (error-message-string err)))
                      (iuiw-jp--next))))
    (setq iuiw-jp--running nil)))

(defun iuiw-jp--start (callback args input)
  "Start jp with ARGS and INPUT; give CALLBACK its output, then run the next call."
  (let* ((out (generate-new-buffer " *jp-tool*"))
         (proc (make-process
                :name "jp" :buffer out :connection-type 'pipe
                :command (cons iuiw-jp-program args)
                :sentinel
                (lambda (proc _event)
                  (unless (process-live-p proc)
                    (let ((text (with-current-buffer out (string-trim (buffer-string))))
                          (status (process-exit-status proc)))
                      (kill-buffer out)
                      (unwind-protect
                          (funcall callback (if (zerop status)
                                                (if (string-empty-p text) "(no output)" text)
                                              (format "Error (exit %d): %s" status text)))
                        (iuiw-jp--next))))))))
    (when input (process-send-string proc input))
    (process-send-eof proc)))

(defun iuiw-jp--search (callback text &optional type)
  "Give CALLBACK the lines of entries containing TEXT, of TYPE if non-nil."
  (iuiw-jp--run (lambda (output)
                  (funcall callback
                           (cond ((string= output "(no output)") "No entries match.")
                                 ((> (length output) iuiw-jp-search-limit)
                                  (concat (substring output 0 iuiw-jp-search-limit) "\n…(truncated)"))
                                 (t output))))
                `("search" ,@(and type (not (string-empty-p type)) (list "-type" type)) ,text)))

(defun iuiw-jp--add (callback type title body &optional tags reading)
  "Add an entry and give CALLBACK its id."
  (iuiw-jp--run callback
                `("add" ,@(and tags (not (string-empty-p tags)) (list "-tags" tags))
                  ,type ,title
                  ,@(and reading (not (string-empty-p reading)) (list (concat "reading=" reading))))
                body))

(gptel-make-tool
 :name "jp_search" :category "jp-notes" :async t
 :function #'iuiw-jp--search
 :description "Search the Japanese notes for a word or grammar point. Returns matching lines as `id: line`."
 :args '((:name "text" :type string :description "Text to find, e.g. the dictionary form of a word")
         (:name "type" :type string :optional t :description "Only entries of this type: word, grammar or expression")))

(gptel-make-tool
 :name "jp_add" :category "jp-notes" :async t
 :function #'iuiw-jp--add
 :description "Add one entry to the Japanese notes. Returns its id."
 :args '((:name "type" :type string :description "word, grammar or expression")
         (:name "title" :type string :description "Dictionary form of the word, or the standard form of the grammar point")
         (:name "body" :type string :description "Meaning, usage and examples, in Markdown")
         (:name "tags" :type string :description "Comma-separated, starting with the JLPT level N5-N1, estimated for words outside the JLPT lists")
         (:name "reading" :type string :optional t :description "Reading in kana, for words")))

(defun iuiw-jp--deepseek-key ()
  "The DeepSeek API key from local.el, auth-source or the environment."
  (or (bound-and-true-p iuiw-deepseek-api-key)
      (ignore-errors (gptel-api-key-from-auth-source "api.deepseek.com"))
      (getenv "DEEPSEEK_API_KEY")
      (user-error "No DeepSeek key: set iuiw-deepseek-api-key in local.el")))

(unless (ignore-errors (gptel-get-backend "DeepSeek"))
  (gptel-make-deepseek "DeepSeek" :key #'iuiw-jp--deepseek-key))

(provide 'iuiw-jp)
;;; iuiw-jp.el ends here
