;;; iuiw-jp-list.el --- jp-notes 的单词表 -*- lexical-binding: t; -*-

;;; Commentary:

;; `iuiw-jp-list' 把 jp-notes-data 里的条目列成一张表：日期、标题、读音、类型、标签、释义。
;; 条目和 front matter 来自 `jp ls -json'，释义取正文第一行，直接读文件。

;;; Code:

(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(defgroup iuiw-jp nil
  "jp-notes, the Japanese notes."
  :group 'applications)

(defcustom iuiw-jp-program
  (or (executable-find "jp")
      (expand-file-name "bin/jp" (string-trim (shell-command-to-string "go env GOPATH"))))
  "Path of the jp-notes command."
  :type 'file
  :group 'iuiw-jp)

(defvar-local iuiw-jp-list--filters nil
  "Filters of the list, each (KIND . VALUE): KIND is `type', `tag' or `search'.")

(defvar-local iuiw-jp-list--matches nil
  "Alist of a search text to the ids `jp search' found for it.")

(defun iuiw-jp-list--dir ()
  "The jp-notes data repository."
  (file-name-as-directory
   (expand-file-name (or (getenv "JP_NOTES_DIR") "~/jp-notes-data"))))

(defun iuiw-jp-list--json (&rest args)
  "Output of jp with ARGS, parsed as JSON."
  (with-temp-buffer
    (let ((status (apply #'call-process iuiw-jp-program nil t nil args)))
      (unless (zerop status)
        (user-error "jp %s: %s" (car args) (string-trim (buffer-string))))
      (goto-char (point-min))
      (json-parse-buffer :object-type 'alist :array-type 'list :null-object nil))))

(defun iuiw-jp-list--file (id)
  "File of entry ID."
  (expand-file-name (concat id ".md") (iuiw-jp-list--dir)))

(defun iuiw-jp-list--gloss (entry)
  "First line of ENTRY's body that is not its title, without list or heading marks."
  (with-temp-buffer
    (ignore-errors (insert-file-contents (iuiw-jp-list--file (alist-get 'id entry))))
    (goto-char (point-min))
    (when (and (alist-get 'meta entry) (looking-at "---[ \t]*\n"))
      (forward-line 1)
      (re-search-forward "^---[ \t]*$" nil 'move)
      (forward-line 1))
    (let ((title (alist-get 'title entry)) gloss)
      (while (and (not gloss) (not (eobp)))
        (let ((line (string-trim
                     (replace-regexp-in-string
                      "\\`[ \t]*\\(?:#+\\|[-*+]\\)[ \t]+" ""
                      (buffer-substring-no-properties (point) (line-end-position))))))
          (unless (or (string-empty-p line) (equal line title))
            (setq gloss line)))
        (forward-line 1))
      (or gloss ""))))

(defun iuiw-jp-list--date (id)
  "MM-DD from ID's file name when `jp add' made it, else from its mtime."
  (if (string-match "/?\\([0-9]\\{4\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)-[0-9]\\{6\\}\\(?:-[0-9]+\\)?\\'" id)
      (format "%s-%s" (match-string 2 id) (match-string 3 id))
    (if-let* ((attributes (file-attributes (iuiw-jp-list--file id))))
        (format-time-string "%m-%d" (file-attribute-modification-time attributes))
      "")))

(defun iuiw-jp-list--keep-p (entry)
  "Non-nil when ENTRY passes every filter."
  (seq-every-p
   (pcase-lambda (`(,kind . ,value))
     (pcase kind
       ('type (equal value (alist-get 'type entry)))
       ('tag (member value (alist-get 'tags entry)))
       ('search (member (alist-get 'id entry)
                        (alist-get value iuiw-jp-list--matches nil nil #'equal)))))
   iuiw-jp-list--filters))

(defun iuiw-jp-list--refresh ()
  "Read the entries again and fill the table."
  (let ((entries (iuiw-jp-list--json "ls" "-json")))
    (setq iuiw-jp-list--matches
          (mapcar (lambda (text)
                    (cons text (mapcar (lambda (entry) (alist-get 'id entry))
                                       (iuiw-jp-list--json "search" "-json" text))))
                  (seq-keep (pcase-lambda (`(,kind . ,value)) (and (eq kind 'search) value))
                            iuiw-jp-list--filters)))
    (setq tabulated-list-entries
          (mapcar (lambda (entry)
                    (let ((id (alist-get 'id entry)))
                      (list id
                            (vector (iuiw-jp-list--date id)
                                    (or (alist-get 'title entry) "")
                                    (or (alist-get 'reading (alist-get 'meta entry)) "")
                                    (or (alist-get 'type entry) "")
                                    (string-join (alist-get 'tags entry) ",")
                                    (iuiw-jp-list--gloss entry)))))
                  (seq-filter #'iuiw-jp-list--keep-p entries)))
    (setq mode-name
          (concat "jp"
                  (mapconcat (pcase-lambda (`(,kind . ,value)) (format " %s:%s" kind value))
                             iuiw-jp-list--filters "")))))

(defun iuiw-jp-list--sort-date (a b)
  "Non-nil when entry A sorts before B by date, then by id."
  (let ((da (aref (cadr a) 0)) (db (aref (cadr b) 0)))
    (if (equal da db) (string< (car a) (car b)) (string< da db))))

(define-derived-mode iuiw-jp-list-mode tabulated-list-mode "jp"
  "Table of the jp-notes entries."
  (setq tabulated-list-format
        [("日期" 5 iuiw-jp-list--sort-date)
         ("标题" 14 t)
         ("读音" 14 t)
         ("类型" 8 t)
         ("标签" 10 t)
         ("释义" 0 nil)])
  (setq tabulated-list-sort-key '("日期" . t))
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'iuiw-jp-list--refresh nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun iuiw-jp-list ()
  "Show the jp-notes entries in a table, newest first."
  (interactive)
  (let ((buffer (or (seq-find (lambda (buffer)
                                (eq (buffer-local-value 'major-mode buffer) 'iuiw-jp-list-mode))
                              (buffer-list))
                    (generate-new-buffer "*jp-notes*"))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'iuiw-jp-list-mode) (iuiw-jp-list-mode))
      (iuiw-jp-list--refresh)
      (tabulated-list-print t))
    (pop-to-buffer-same-window buffer)))

(defun iuiw-jp-list-open ()
  "Open the entry at point in another window."
  (interactive)
  (if-let* ((id (tabulated-list-get-id)))
      (find-file-other-window (iuiw-jp-list--file id))
    (user-error "No entry here")))

(defun iuiw-jp-list--set-filters (filters)
  "Show the entries that pass FILTERS."
  (setq iuiw-jp-list--filters filters)
  (iuiw-jp-list--refresh)
  (tabulated-list-print t))

(defun iuiw-jp-list-filter ()
  "Narrow the list to a type or a tag, on top of the filters already set."
  (interactive)
  (let* ((entries (iuiw-jp-list--json "ls" "-json"))
         (choices (delete-dups
                   (append (seq-keep (lambda (entry)
                                       (when-let* ((type (alist-get 'type entry))
                                                   ((not (string-empty-p type))))
                                         (concat "type:" type)))
                                     entries)
                           (mapcan (lambda (entry)
                                     (mapcar (lambda (tag) (concat "tag:" tag))
                                             (alist-get 'tags entry)))
                                   entries))))
         (choice (completing-read "Filter: " choices nil t)))
    (string-match "\\`\\([^:]+\\):\\(.*\\)\\'" choice)
    (iuiw-jp-list--set-filters
     (append iuiw-jp-list--filters
             (list (cons (intern (match-string 1 choice)) (match-string 2 choice)))))))

(defun iuiw-jp-list-search (text)
  "Narrow the list to entries containing TEXT anywhere in their file."
  (interactive (list (read-string "Search jp: ")))
  (unless (string-empty-p text)
    (iuiw-jp-list--set-filters (append iuiw-jp-list--filters (list (cons 'search text))))))

(defun iuiw-jp-list-clear ()
  "Show every entry again."
  (interactive)
  (iuiw-jp-list--set-filters nil))

(define-key iuiw-jp-list-mode-map (kbd "RET") #'iuiw-jp-list-open)
(define-key iuiw-jp-list-mode-map "/" #'iuiw-jp-list-filter)
(define-key iuiw-jp-list-mode-map "s" #'iuiw-jp-list-search)
(define-key iuiw-jp-list-mode-map "c" #'iuiw-jp-list-clear)

(provide 'iuiw-jp-list)
;;; iuiw-jp-list.el ends here
