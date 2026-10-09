;;; jgy-log.el --- Syntax highlighting for log files -*- lexical-binding: t; -*-

;;; Commentary:
;; 只做高亮的日志模式，编辑行为与 `text-mode' 相同。

;;; Code:

(defconst jgy-log-font-lock-keywords
  `((,(concat "\\<[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}"
              "\\(?:[ T][0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\(?:[.,][0-9]+\\)?"
              "\\(?:Z\\|[+-][0-9]\\{2\\}:?[0-9]\\{2\\}\\)?\\)?")
     . font-lock-comment-face)
    ("\\<\\(?:FATAL\\|CRITICAL\\|ERROR\\|SEVERE\\|EMERGENCY\\|ALERT\\)\\>" . 'error)
    ("\\<\\(?:WARN\\|WARNING\\)\\>" . 'warning)
    ("\\<\\(?:INFO\\|NOTICE\\)\\>" . 'success)
    ("\\<\\(?:DEBUG\\|TRACE\\|FINE\\|FINER\\|FINEST\\)\\>" . 'shadow)
    ("\\<[[:alnum:]_.$]*\\(?:Exception\\|Error\\)\\>" . font-lock-type-face)
    ("^\\s-+at \\(.*\\)$" 1 'shadow)
    ("\\<Traceback (most recent call last):" . 'error)
    ("\\[[^]\n]*\\]" . font-lock-constant-face)
    ("\"[^\"\n]*\"" . font-lock-string-face)
    ("\\<[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\>"
     . font-lock-constant-face)
    ("\\<[0-9]+\\(?:\\.[0-9]+\\)?\\>" . 'font-lock-number-face)))

;;;###autoload
(define-derived-mode jgy-log-mode text-mode "Log"
  "Major mode highlighting timestamps, levels and stack traces in log files."
  (setq-local font-lock-defaults '(jgy-log-font-lock-keywords t)))

(provide 'jgy-log)
;;; jgy-log.el ends here
