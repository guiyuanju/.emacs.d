;;; iuiw-work-report.el --- A daily report of the day's work -*- lexical-binding: t; -*-

;;; Commentary:
;; `iuiw-daily' 的任务 work-report：iuiw-work-report.py 收集当天的提交、project.md
;; 日志、Claude Code 和 Codex 里的提问和未提交的改动，隐去像密钥的字符串；DeepSeek
;; 据此写日报，存进 okj workspace 的 reports/ 并在那个仓库 commit。材料另存在
;; reports/material/，用来核对日报。

;;; Code:

(require 'cl-lib)
(require 'iuiw-daily)
(require 'iuiw-elfeed-ai)

(defgroup iuiw-work-report nil
  "A daily report of the day's work."
  :group 'convenience)

(defcustom iuiw-work-report-directory "~/workspace/okj/reports/"
  "Directory of the reports, inside a git repository."
  :type 'directory)

(defcustom iuiw-work-report-workspaces '("~/workspace/me" "~/workspace/okj")
  "Workspaces whose project logs, project repositories and agent sessions count."
  :type '(repeat directory))

(defcustom iuiw-work-report-repos '("~/.emacs.d" "~/workspace")
  "Further git repositories whose commits count."
  :type '(repeat directory))

(defcustom iuiw-work-report-backend 'deepseek
  "Backend of `iuiw-elfeed-ai' that writes the report."
  :type '(choice (const claude) (const codex) (const deepseek)))

(defconst iuiw-work-report--script
  (expand-file-name "iuiw-work-report.py" (file-name-directory (or load-file-name buffer-file-name))))

(defconst iuiw-work-report--prompt "\
下面是我 %s 这一天工作留下的痕迹：project.md 的日志、git 提交、和 AI agent 会话里我的提问、\
还没提交的改动。按项目写一份中文日报，让我确认今天做了什么。

要求：
- 只根据材料写，不推测材料里没有的结果；提问只说明在查或在做什么，不当作已完成。
- 同一件事的日志、提交和提问合成一条。
- 提交里的琐碎改动（格式、小修）合并成一句。
- 不写密码、token、客户个人数据。

严格按这个格式输出 Markdown，不要多余的话：

## 要点
- 3 到 6 条，每条一件最重要的事，开头写项目名（如 okj/debug）

## 按项目
### 项目名
- 完成：……
- 进行中：……
- 调查 / 讨论：……
（没有的类别省略）

## 需要确认
- 只有提问、没有提交或日志的事，问我结果如何；没有就写「无」

材料：

%s")

(defun iuiw-work-report--material (date callback)
  "Collect the material of DATE, then call CALLBACK with (TEXT ERROR)."
  (let ((buf (generate-new-buffer " *iuiw-work-report*"))
        (default-directory temporary-file-directory))
    (make-process
     :name "iuiw-work-report" :buffer buf :connection-type 'pipe :noquery t
     :command `("python3" "-I" ,iuiw-work-report--script ,date
                ,@(mapcan (lambda (d) (list "--repo" (expand-file-name d))) iuiw-work-report-repos)
                ,@(mapcan (lambda (d) (list "--workspace" (expand-file-name d)))
                          iuiw-work-report-workspaces))
     :sentinel (lambda (proc _event)
                 (unless (process-live-p proc)
                   (let ((out (with-current-buffer buf (string-trim (buffer-string)))))
                     (kill-buffer buf)
                     (if (zerop (process-exit-status proc))
                         (funcall callback out nil)
                       (funcall callback nil (car (last (split-string out "\n" t)))))))))))

(defun iuiw-work-report--write (file text)
  "Write TEXT into FILE."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region text nil file nil 'silent)))

(defun iuiw-work-report--commit (date)
  "Commit DATE's report and material in their repository."
  (let ((default-directory (expand-file-name iuiw-work-report-directory)))
    (call-process "git" nil nil nil "add" "--" (concat date ".md")
                  (concat "material/" date ".md"))
    (call-process "git" nil nil nil "commit" "-q" "-m" (concat "reports: " date)
                  "--" (concat date ".md") (concat "material/" date ".md"))))

(defun iuiw-work-report-generate (date done)
  "Write the report of DATE, a YYYY-MM-DD string.
Then call DONE with an error message, or nil."
  (iuiw-work-report--material
   date
   (lambda (material err)
     (let ((file (expand-file-name (concat date ".md") iuiw-work-report-directory)))
       (cl-flet ((finish (body)
                   (iuiw-work-report--write
                    (expand-file-name (concat "material/" date ".md") iuiw-work-report-directory)
                    (format "# 工作日报材料 %s\n\n%s\n" date material))
                   (iuiw-work-report--write
                    file (format "# 工作日报 %s\n\n%s\n" date body))
                   (iuiw-work-report--commit date)
                   (funcall done nil)))
         (cond
          (err (funcall done err))
          ((string-empty-p material) (finish "## 要点\n- 没有记录到活动"))
          (t (iuiw-elfeed-ai--request
              iuiw-work-report-backend t (format iuiw-work-report--prompt date material)
              (lambda (text err)
                (if text (finish (string-trim text)) (funcall done err)))))))))))

(defun iuiw-work-report--points (file)
  "Return the items under \"## 要点\" in report FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (when (re-search-forward "^## 要点[ \t]*$" nil t)
      (let ((end (save-excursion (if (re-search-forward "^## " nil t) (match-beginning 0) (point-max))))
            points)
        (while (re-search-forward "^- \\(.+\\)" end t)
          (push (match-string 1) points))
        (nreverse points)))))

;;;###autoload
(defun iuiw-work-report (&optional date)
  "Open the latest report; with a prefix argument, write the report of DATE first."
  (interactive (list (when current-prefix-arg
                       (read-string "Date: " (format-time-string "%F")))))
  (if (not date)
      (iuiw-daily-open 'work-report)
    (message "Writing the work report of %s..." date)
    (iuiw-work-report-generate
     date (lambda (err)
            (if err
                (message "Work report failed: %s" err)
              (iuiw-daily-open 'work-report
                               (expand-file-name (concat date ".md") iuiw-work-report-directory)))))))

(iuiw-daily-define 'work-report
                   :title "日报"
                   :directory (lambda () iuiw-work-report-directory)
                   :extension "md"
                   :run (lambda (done) (iuiw-work-report-generate (format-time-string "%F") done))
                   :points #'iuiw-work-report--points
                   :open #'find-file-other-window)

(provide 'iuiw-work-report)
;;; iuiw-work-report.el ends here
