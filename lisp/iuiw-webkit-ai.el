;;; iuiw-webkit-ai.el --- AI summary and translation in xwidget-webkit pages -*- lexical-binding: t; -*-

;;; Commentary:
;; xwidget-webkit 里按 a 在页面顶部插入 AI 总结，再按一次收起；按 t 在每段原文下插入
;; 中文译文（双语对照），翻译中再按停止，译完再按收起。C-u 先选后端并忽略缓存重来。
;; 后端和 prompt 用 iuiw-elfeed-ai 的；网址是 elfeed 条目时总结存进条目（随 elfeed
;; 同步），其余总结和所有译文缓存在 `iuiw-webkit-ai-cache-directory'，过期删除。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'xwidget)
(require 'iuiw-elfeed-ai)

(defgroup iuiw-webkit-ai nil
  "AI summary and translation in xwidget-webkit pages."
  :group 'xwidget)

(defcustom iuiw-webkit-ai-cache-directory
  (locate-user-emacs-file "var/webkit-ai/")
  "Directory holding one cache file per page."
  :type 'directory)

(defcustom iuiw-webkit-ai-cache-days 30
  "Days a page's cache is kept after it was last written."
  :type 'natural)

(defcustom iuiw-webkit-ai-batch-chars 3000
  "Most characters sent in one translation request."
  :type 'natural)

(defcustom iuiw-webkit-ai-concurrency 3
  "Most translation requests running at once for a page."
  :type 'natural)

(defconst iuiw-webkit-ai--translate-prompt
  "把下面每段翻译成简体中文。每段以「编号: 」开头，占一行。
每段输出一行「编号: 译文」，按编号顺序，只输出这些行；不要合并、拆分或省略段落，不要解释。
代码、命令、网址保留原文；专有名词首次出现时可在译文后括注原文。")

;;; Cache

(defvar iuiw-webkit-ai--caches (make-hash-table :test #'equal)
  "Page key mapped to its plist of :summary and :translations.")

(defvar iuiw-webkit-ai--pruned nil
  "When the cache directory was last pruned.")

(defun iuiw-webkit-ai--key (url)
  "Return the cache key of URL, without its fragment."
  (replace-regexp-in-string "#.*\\'" "" url))

(defun iuiw-webkit-ai--file (key)
  "Return the cache file of page KEY."
  (expand-file-name (concat (sha1 key) ".eld") iuiw-webkit-ai-cache-directory))

(defun iuiw-webkit-ai--prune ()
  "Delete page caches not written for `iuiw-webkit-ai-cache-days', at most daily."
  (unless (and iuiw-webkit-ai--pruned
               (< (- (float-time) iuiw-webkit-ai--pruned) 86400))
    (setq iuiw-webkit-ai--pruned (float-time))
    (let ((limit (- (float-time) (* iuiw-webkit-ai-cache-days 86400))))
      (dolist (file (ignore-errors
                      (directory-files iuiw-webkit-ai-cache-directory t "\\.eld\\'")))
        (when (< (float-time (file-attribute-modification-time (file-attributes file)))
                 limit)
          (delete-file file)))
      (maphash (lambda (key _)
                 (unless (file-exists-p (iuiw-webkit-ai--file key))
                   (remhash key iuiw-webkit-ai--caches)))
               iuiw-webkit-ai--caches))))

(defun iuiw-webkit-ai--cache (key)
  "Return the cache plist of page KEY, reading its file the first time."
  (iuiw-webkit-ai--prune)
  (or (gethash key iuiw-webkit-ai--caches)
      (puthash key
               (let* ((file (iuiw-webkit-ai--file key))
                      (data (and (file-exists-p file)
                                 (ignore-errors
                                   (with-temp-buffer
                                     (insert-file-contents file)
                                     (read (current-buffer))))))
                      (table (make-hash-table :test #'equal)))
                 (pcase-dolist (`(,source . ,target) (plist-get data :translations))
                   (puthash source target table))
                 (list :summary (plist-get data :summary) :translations table))
               iuiw-webkit-ai--caches)))

(defun iuiw-webkit-ai--save (key)
  "Write the cache of page KEY to its file."
  (let ((cache (iuiw-webkit-ai--cache key))
        translations)
    (maphash (lambda (source target) (push (cons source target) translations))
             (plist-get cache :translations))
    (make-directory iuiw-webkit-ai-cache-directory t)
    (with-temp-file (iuiw-webkit-ai--file key)
      (let ((print-length nil) (print-level nil))
        (prin1 (list :url key :summary (plist-get cache :summary)
                     :translations translations)
               (current-buffer))))))

;;; Page

(defun iuiw-webkit-ai--session ()
  "Return the xwidget of the current buffer and its URL."
  (let ((xw (and (derived-mode-p 'xwidget-webkit-mode) (xwidget-webkit-current-session))))
    (unless xw (user-error "Not in an xwidget-webkit page"))
    (cons xw (xwidget-webkit-uri xw))))

(defun iuiw-webkit-ai--js (xw script &optional callback)
  "Run SCRIPT in XW if it is still alive, then call CALLBACK with its result."
  (when (xwidget-live-p xw)
    (xwidget-webkit-execute-script xw script callback)))

(defun iuiw-webkit-ai--elfeed-entry (url)
  "Return the elfeed entry whose link is URL, or nil."
  (with-elfeed-db-visit (entry _feed)
			(when (or (equal (elfeed-entry-link entry) url)
				  (equal (cdr (elfeed-entry-id entry)) url))
			  (elfeed-db-return entry))))

;;; Summary

(defconst iuiw-webkit-ai--summary-js
  "(function(url,head,body){
if(location.href!==url)return;
var o=document.querySelector('.iuiw-ai-sum');
if(!o){o=document.createElement('div');o.className='iuiw-ai-sum';
o.style.cssText='margin:12px;padding:12px 16px;border-left:4px solid #c9a227;border-radius:6px;background:rgba(201,162,39,.12);font:15px/1.6 -apple-system,sans-serif;color:inherit;position:relative;z-index:2147483647';
document.body.insertBefore(o,document.body.firstChild);}
o.textContent='';
var h=document.createElement('div');h.style.fontWeight='bold';h.textContent=head;
var b=document.createElement('div');b.style.whiteSpace='pre-wrap';b.textContent=body;
o.appendChild(h);o.appendChild(b);window.scrollTo(0,0);})(%s,%s,%s)")

(defun iuiw-webkit-ai--show-summary (xw url head body)
  "Show HEAD and BODY in the summary box of XW if it still shows URL."
  (iuiw-webkit-ai--js xw (format iuiw-webkit-ai--summary-js
                                 (json-encode url) (json-encode head) (json-encode body))))

;;;###autoload
(defun iuiw-webkit-ai-summarize (&optional pick)
  "Show an AI summary at the top of the page, or hide it if shown.
With PICK, ask for a backend and write the summary again."
  (interactive "P")
  (pcase-let* ((`(,xw . ,url) (iuiw-webkit-ai--session))
               (backend (if pick (iuiw-elfeed-ai--read-backend) iuiw-elfeed-ai-backend)))
    (iuiw-webkit-ai--js
     xw (format "(function(force){var o=document.querySelector('.iuiw-ai-sum');
if(o&&!force){o.remove();return '';}return document.documentElement.outerHTML;})(%s)"
                (if pick "true" "false"))
     (lambda (html)
       (unless (string-empty-p (or html ""))
         (iuiw-webkit-ai--summarize xw url backend html pick))))))

(defun iuiw-webkit-ai--summarize (xw url backend html fresh)
  "Summarize HTML of URL in XW with BACKEND, reusing a stored summary unless FRESH."
  (let* ((key (iuiw-webkit-ai--key url))
         (entry (iuiw-webkit-ai--elfeed-entry url))
         (stored (and (not fresh)
                      (if entry
                          (elfeed-meta entry :iuiw-ai-summary)
                        (plist-get (iuiw-webkit-ai--cache key) :summary)))))
    (if stored
        (iuiw-webkit-ai--show-summary
         xw url (format "AI 总结（%s）" (car stored)) (cdr stored))
      (let ((text (iuiw-elfeed-ai--html-text html t)))
        (if (string-empty-p text)
            (message "这页没有可总结的文字")
          (iuiw-webkit-ai--show-summary xw url (format "AI 总结（%s）" backend) "生成中…")
          (iuiw-elfeed-ai--request
           backend nil
           (format "%s\n\n%s" iuiw-elfeed-ai--entry-prompt
                   (truncate-string-to-width text iuiw-elfeed-ai-max-chars))
           (lambda (summary error)
             (if (not summary)
		 (iuiw-webkit-ai--show-summary
                  xw url (format "AI 总结（%s）" backend) (format "失败：%s" error))
               (let ((value (cons backend summary)))
		 (if entry
                     (iuiw-elfeed-ai--set-status entry nil value)
                   (plist-put (iuiw-webkit-ai--cache key) :summary value)
                   (iuiw-webkit-ai--save key)))
               (iuiw-webkit-ai--show-summary
		xw url (format "AI 总结（%s）" backend) summary)))))))))

;;; Translation

(defconst iuiw-webkit-ai--collect-js
  "(function(){
var old=document.querySelectorAll('.iuiw-ai-tr');
if(old.length){old.forEach(function(e){e.remove();});return 'null';}
var sel='p,h1,h2,h3,h4,h5,h6,li,blockquote,dt,dd,th,td,figcaption';
var arts=document.querySelectorAll('article');
var root=document.querySelector('main,[role=main]')||(arts.length===1?arts[0]:null);
if(!root||root.innerText.length<500)root=document.body;
var out=[];
root.querySelectorAll(sel).forEach(function(el){
if(el.closest('pre,code,script,style,noscript,nav,aside,footer,.iuiw-ai-sum'))return;
if(el.querySelector(sel))return;
var t=el.innerText.replace(/\\s+/g,' ').trim();
if(t.length<2||!/[A-Za-z\\u3040-\\u30ff\\uac00-\\ud7af]/.test(t))return;
el.setAttribute('data-iuiw-i',out.length);out.push(t);});
return JSON.stringify(out);})()"
  "Remove shown translations, or mark the main blocks and return their texts.")

(defconst iuiw-webkit-ai--insert-js
  "(function(m){for(var i in m){
var el=document.querySelector('[data-iuiw-i=\"'+i+'\"]');
if(!el||el.querySelector('.iuiw-ai-tr'))continue;
var d=document.createElement('span');d.className='iuiw-ai-tr';
d.style.cssText='display:block;margin-top:.3em;color:#8a7f66;font-size:.95em;font-weight:normal';
d.textContent=m[i];el.appendChild(d);}})(%s)")

(defvar-local iuiw-webkit-ai--job nil
  "The running translation in this buffer, as (URL . DONE-FLAG-CELL).")

;;;###autoload
(defun iuiw-webkit-ai-translate (&optional pick)
  "Put a Chinese translation under each paragraph of the page.
Stop a running translation, or remove a shown one.  With PICK, ask for a
backend and translate again without the cache."
  (interactive "P")
  (pcase-let ((`(,xw . ,url) (iuiw-webkit-ai--session))
              (buf (current-buffer)))
    (if (and iuiw-webkit-ai--job (equal (car iuiw-webkit-ai--job) url))
        (progn (setcar (cdr iuiw-webkit-ai--job) t)
               (setq iuiw-webkit-ai--job nil)
               (iuiw-webkit-ai--js
                xw "document.querySelectorAll('.iuiw-ai-tr').forEach(function(e){e.remove();})")
               (message "翻译已停止"))
      (let ((backend (if pick (iuiw-elfeed-ai--read-backend) iuiw-elfeed-ai-backend)))
        (iuiw-webkit-ai--js
         xw iuiw-webkit-ai--collect-js
         (lambda (result)
           (let ((texts (and result (json-parse-string result :array-type 'list
                                                       :null-object nil))))
             (cond ((equal result "null") (message "已收起译文"))
                   ((null texts) (message "这页没有要翻译的段落"))
                   ((buffer-live-p buf)
                    (with-current-buffer buf
                      (iuiw-webkit-ai--translate xw url backend texts pick)))))))))))

(defun iuiw-webkit-ai--batches (items)
  "Split ITEMS, a list of (INDEX . TEXT), into batches under the size limit."
  (let (batches batch (size 0))
    (dolist (item items)
      (when (and batch (> (+ size (length (cdr item))) iuiw-webkit-ai-batch-chars))
        (push (nreverse batch) batches)
        (setq batch nil size 0))
      (push item batch)
      (cl-incf size (length (cdr item))))
    (when batch (push (nreverse batch) batches))
    (nreverse batches)))

(defun iuiw-webkit-ai--insert (xw pairs)
  "Insert PAIRS, a list of (INDEX . TRANSLATION), into the page of XW."
  (when pairs
    (let ((map (make-hash-table :test #'equal)))
      (pcase-dolist (`(,index . ,target) pairs)
        (puthash (number-to-string index) target map))
      (iuiw-webkit-ai--js xw (format iuiw-webkit-ai--insert-js (json-encode map))))))

(defun iuiw-webkit-ai--translate (xw url backend texts fresh)
  "Translate TEXTS of URL in XW with BACKEND, using the cache unless FRESH."
  (let* ((key (iuiw-webkit-ai--key url))
         (table (plist-get (iuiw-webkit-ai--cache key) :translations))
         (stopped (list nil))
         (same (make-hash-table :test #'equal))
         (cached nil)
         (todo nil)
         (index 0))
    (dolist (text texts)
      (let ((hit (and (not fresh) (gethash text table))))
        (cond (hit (push (cons index hit) cached))
              ((gethash text same) (push index (gethash text same)))
              (t (puthash text (list index) same)
                 (push (cons index text) todo))))
      (cl-incf index))
    (iuiw-webkit-ai--insert xw cached)
    (if (null todo)
        (message "译文来自缓存")
      (let* ((queue (iuiw-webkit-ai--batches (nreverse todo)))
             (total (length queue))
             (done 0)
             (failed 0)
             (buf (current-buffer)))
        (setq iuiw-webkit-ai--job (cons url stopped))
        (cl-labels
            ((finish ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (when (eq (cdr iuiw-webkit-ai--job) stopped)
                     (setq iuiw-webkit-ai--job nil))))
               (message "翻译完成（%s）%s" backend
                        (if (zerop failed) "" (format "，%d 批失败" failed))))
             (next ()
               (when-let* (((not (car stopped)))
                           (batch (pop queue)))
                 (iuiw-elfeed-ai--request
                  backend nil
                  (concat iuiw-webkit-ai--translate-prompt "\n\n"
                          (mapconcat (lambda (item) (format "%d: %s" (car item) (cdr item)))
                                     batch "\n"))
                  (lambda (text error)
                    (unless (car stopped)
                      (cl-incf done)
                      (if (not text)
                          (progn (cl-incf failed)
                                 (message "翻译失败（%s）：%s" backend error))
                        (let (pairs)
                          (pcase-dolist (`(,i . ,target) (iuiw-webkit-ai--parse text batch))
                            (let ((source (cdr (assq i batch))))
                              (puthash source target table)
                              (dolist (j (gethash source same))
                                (push (cons j target) pairs))))
                          (iuiw-webkit-ai--save key)
                          (iuiw-webkit-ai--insert xw pairs)))
                      (if (= done total)
                          (finish)
                        (message "翻译中（%s）%d/%d" backend done total)
                        (next))))))))
          (message "翻译中（%s）0/%d" backend total)
          (dotimes (_ (min iuiw-webkit-ai-concurrency total)) (next)))))))

(defun iuiw-webkit-ai--parse (text batch)
  "Return (INDEX . TRANSLATION) pairs in TEXT for the indexes in BATCH."
  (let (pairs)
    (dolist (line (split-string text "\n" t))
      (when (string-match "\\`\\s-*\\([0-9]+\\)\\s-*[:：]\\s-*\\(.+\\)" line)
        (let ((index (string-to-number (match-string 1 line))))
          (when (assq index batch)
            (push (cons index (string-trim (match-string 2 line))) pairs)))))
    (nreverse pairs)))

(provide 'iuiw-webkit-ai)
;;; iuiw-webkit-ai.el ends here
