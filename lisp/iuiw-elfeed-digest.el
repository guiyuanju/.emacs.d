;;; iuiw-elfeed-digest.el --- The daily elfeed digest task -*- lexical-binding: t; -*-

;;; Commentary:
;; `iuiw-daily' 的任务 elfeed-digest：看板和通知只读摘要文件，启动时不加载 elfeed；
;; 生成和显示摘要时才加载。先 require elfeed，让 init.el 里 `:after elfeed' 的包按顺序加载，
;; 直接 require 它们会在加载中途触发 `:after'，同一个文件被加载两次。

;;; Code:

(require 'iuiw-daily)

(declare-function iuiw-elfeed-sync--run-digest "iuiw-elfeed-sync")
(declare-function iuiw-elfeed-ai-digest-mode "iuiw-elfeed-ai")

(defun iuiw-elfeed-digest-since ()
  "Return when the latest digest was written, or a day ago if none was."
  (or (when-let* ((file (iuiw-daily-latest 'elfeed-digest)))
        (with-temp-buffer
          (insert-file-contents file)
          (when (re-search-forward "^#\\+until: \\([0-9.]+\\)" nil t)
            (string-to-number (match-string 1)))))
      (- (float-time) 86400)))

(defun iuiw-elfeed-digest--run (done)
  "Update the feeds, then write today's digest and call DONE."
  (require 'elfeed)
  (require 'iuiw-elfeed-sync)
  (iuiw-elfeed-sync--run-digest done))

(defun iuiw-elfeed-digest--describe (file)
  "The notification text for digest FILE."
  (concat (with-temp-buffer
            (insert-file-contents file)
            (when (re-search-forward "^#\\+subtitle: \\(.*\\)" nil t)
              (match-string 1)))
          " · 在 elfeed 里按 gd 查看"))

(defun iuiw-elfeed-digest--points (file)
  "Return the items under \"* 要点\" in digest FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (when (re-search-forward "^\\* 要点[ \t]*$" nil t)
      (let ((end (save-excursion (if (re-search-forward "^\\* " nil t) (match-beginning 0) (point-max))))
            points)
        (while (re-search-forward "^- \\(.+\\)" end t)
          (push (match-string 1) points))
        (nreverse points)))))

(defun iuiw-elfeed-digest--show (file)
  "Show digest FILE in a side window."
  (require 'elfeed)
  (require 'iuiw-elfeed-ai)
  (let ((buf (get-buffer-create "*elfeed-digest*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents file)
        (iuiw-elfeed-ai-digest-mode)))
    (select-window (display-buffer buf '(display-buffer-in-side-window
                                         (side . right) (window-width . 0.4))))))

;;;###autoload
(defun iuiw-elfeed-digest-open ()
  "Show the latest digest in a side window."
  (interactive)
  (iuiw-daily-open 'elfeed-digest))

(iuiw-daily-define 'elfeed-digest
                   :title "Elfeed 摘要"
                   :directory (lambda () (iuiw-sync-file "digest"))
                   :extension "org"
                   :run #'iuiw-elfeed-digest--run
                   :describe #'iuiw-elfeed-digest--describe
                   :points #'iuiw-elfeed-digest--points
                   :open #'iuiw-elfeed-digest--show)

(provide 'iuiw-elfeed-digest)
;;; iuiw-elfeed-digest.el ends here
