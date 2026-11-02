;;; iuiw-webkit-furigana.el --- Furifont furigana in xwidget-webkit pages -*- lexical-binding: t; -*-

;;; Commentary:
;; 把 Furifont 官网的用户脚本注入 xwidget-webkit 页面，给汉字注假名。脚本用到的
;; GM_* 接口在这里补上：菜单命令记在 window.__iuiwFuri.menu 里，请求改用 fetch。
;; 开着 `iuiw-webkit-furigana' 时，每个页面加载完都注入一次，脚本自己只在日语页面启用。

;;; Code:

(require 'xwidget)

(defvar iuiw-webkit-furigana nil
  "Non-nil to set the Japanese text of xwidget-webkit pages in Furifont.")

(defvar iuiw-webkit-furigana-script-url "https://furifont.antfu.me/furifont.user.js"
  "Where the Furifont userscript is downloaded from.")

(defvar iuiw-webkit-furigana-script-file
  (locate-user-emacs-file "var/furifont.user.js")
  "Local copy of the Furifont userscript.")

(defvar iuiw-webkit-furigana-refresh-days 7
  "Days after which the local userscript is downloaded again.")

(defvar iuiw-webkit-furigana--script nil
  "The userscript wrapped for injection, read once from the local copy.")

(defconst iuiw-webkit-furigana--prelude
  "if(!window.__iuiwFuri){window.__iuiwFuri={menu:{}};(function(){
var GM_getValue=function(k,d){return k==='checked'?String(Date.now()):d;};
var GM_setValue=function(){};
var GM_registerMenuCommand=function(n,f){window.__iuiwFuri.menu[n]=f;};
var GM_xmlhttpRequest=function(o){fetch(o.url).then(function(r){
return o.responseType==='arraybuffer'?r.arrayBuffer():r.text();})
.then(function(b){o.onload({response:b});},o.onerror);};\n"
  "Opens the wrapper giving the userscript the GM_* functions it calls.")

(defconst iuiw-webkit-furigana--toggle-js
  "(function(on){var f=window.furifont,live=!!(f&&!f.sheet.disabled);
if(live!==on)window.__iuiwFuri.menu['Furifont Sans']();})(%s)"
  "Turns Furifont on or off in the page, after the userscript is in.")

(defun iuiw-webkit-furigana--download (then)
  "Download the userscript, then call THEN with non-nil on success."
  (make-directory (file-name-directory iuiw-webkit-furigana-script-file) t)
  (let ((tmp (expand-file-name (concat iuiw-webkit-furigana-script-file ".part"))))
    (make-process
     :name "iuiw-furifont-script" :noquery t :buffer nil
     :command (list "curl" "-fsSL" "-o" tmp iuiw-webkit-furigana-script-url)
     :sentinel (lambda (proc _event)
                 (unless (process-live-p proc)
                   (let ((ok (zerop (process-exit-status proc))))
                     (if ok
                         (progn (rename-file tmp iuiw-webkit-furigana-script-file t)
                                (setq iuiw-webkit-furigana--script nil))
                       (ignore-errors (delete-file tmp))
                       (message "Furifont 脚本下载失败"))
                     (funcall then ok)))))))

(defun iuiw-webkit-furigana--with-script (then)
  "Call THEN with the wrapped userscript, downloading it if needed."
  (let ((file iuiw-webkit-furigana-script-file))
    (if (not (file-exists-p file))
        (iuiw-webkit-furigana--download
         (lambda (ok) (when ok (iuiw-webkit-furigana--with-script then))))
      (when (> (- (float-time) (float-time (file-attribute-modification-time
                                            (file-attributes file))))
               (* iuiw-webkit-furigana-refresh-days 86400))
        (iuiw-webkit-furigana--download #'ignore))
      (funcall then
               (or iuiw-webkit-furigana--script
                   (setq iuiw-webkit-furigana--script
                         (concat iuiw-webkit-furigana--prelude
                                 (with-temp-buffer
                                   (insert-file-contents file)
                                   (buffer-string))
                                 "\n})();}")))))))

(defun iuiw-webkit-furigana--apply (xw &optional force)
  "Put the userscript into XW; with FORCE, also turn Furifont on or off to match."
  (iuiw-webkit-furigana--with-script
   (lambda (script)
     (when (xwidget-live-p xw)
       (xwidget-webkit-execute-script xw script)
       (when force
         (xwidget-webkit-execute-script
          xw (format iuiw-webkit-furigana--toggle-js
                     (if iuiw-webkit-furigana "true" "false"))))))))

(defun iuiw-webkit-furigana--on-load (xwidget type)
  "Put the userscript into XWIDGET when its page of TYPE event finishes loading."
  (when (and iuiw-webkit-furigana
             (eq type 'load-changed)
             (equal (nth 3 last-input-event) "load-finished"))
    (iuiw-webkit-furigana--apply xwidget)))

;;;###autoload
(defun iuiw-webkit-furigana-toggle ()
  "Turn Furifont furigana on or off for this and later xwidget-webkit pages."
  (interactive)
  (let ((xw (xwidget-webkit-current-session)))
    (unless xw (user-error "Not in an xwidget-webkit page"))
    (setq iuiw-webkit-furigana (not iuiw-webkit-furigana))
    (iuiw-webkit-furigana--apply xw t)
    (message "网页假名：%s" (if iuiw-webkit-furigana "开" "关"))))

(declare-function iuiw-furigana-mode "iuiw-ui")

;;;###autoload
(defun iuiw-furigana-toggle ()
  "Toggle furigana for web pages in xwidget-webkit, else for Emacs text."
  (interactive)
  (if (derived-mode-p 'xwidget-webkit-mode)
      (iuiw-webkit-furigana-toggle)
    (call-interactively #'iuiw-furigana-mode)))

(advice-add 'xwidget-webkit-callback :after #'iuiw-webkit-furigana--on-load)

(provide 'iuiw-webkit-furigana)
;;; iuiw-webkit-furigana.el ends here
