;;; iuiw-playground.el --- Saved code snippets for any language -*- lexical-binding: t; -*-

;;; Commentary:
;; 仿 go-playground / rust-playground：一个命令新建片段并打开，C-c C-c 运行，
;; 片段按语言存在 `iuiw-playground-directory' 下，以后能再打开。
;; 都用 quickrun 运行；Go 和 Rust 建成模块 / Cargo 项目，在片段目录里跑整个项目。
;; 源文件仍和模板一样的片段视为没用过，关掉它的 buffer 时删掉。

;;; Code:

(require 'seq)

(declare-function quickrun "quickrun")
(defvar quickrun-option-default-directory)

(defvar iuiw-playground-directory (expand-file-name "~/playground/")
  "Directory holding one subdirectory per language of snippets.")

(defvar iuiw-playground-languages
  '(("go" :modes (go-mode go-ts-mode) :file "main.go"
     :init "go mod init playground" :exec "go mod tidy && go run ."
     :template "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println($0)\n}\n")
    ("rust" :modes (rust-mode rust-ts-mode) :file "src/main.rs"
     :init "cargo init --name playground --vcs none --quiet" :exec "cargo run --quiet"
     :template "fn main() {\n    println!(\"{}\", $0);\n}\n")
    ("python" :modes (python-mode python-ts-mode) :file "main.py"
     :template "print($0)\n")
    ("elisp" :modes (emacs-lisp-mode) :file "main.el"
     :template ";;; -*- lexical-binding: t; -*-\n\n(message \"%S\" $0)\n")
    ("javascript" :modes (js-mode js-ts-mode) :file "main.js"
     :template "console.log($0);\n")
    ("java" :modes (java-mode java-ts-mode) :file "Main.java" :exec "java Main.java"
     :template "public class Main {\n    public static void main(String[] args) {\n        System.out.println($0);\n    }\n}\n")
    ("shell" :modes (sh-mode bash-ts-mode) :file "main.sh"
     :template "#!/usr/bin/env bash\n\n$0\n"))
  "Languages as (NAME . PLIST).
:file is the source file inside the snippet directory, :template its
initial text with $0 marking point.  :init runs once in a new snippet
directory; :exec, when present, replaces quickrun's command for the language.")

(defvar iuiw-playground--last-language nil)

(defun iuiw-playground--language (name)
  "Return the plist of language NAME."
  (cdr (assoc name iuiw-playground-languages)))

(defun iuiw-playground--read-language ()
  "Read a language, defaulting to the current buffer's or the last one."
  (let ((default (or (car (seq-find (lambda (language)
                                      (apply #'derived-mode-p
                                             (plist-get (cdr language) :modes)))
                                    iuiw-playground-languages))
                     iuiw-playground--last-language)))
    (completing-read (format-prompt "Language" default)
                     (mapcar #'car iuiw-playground-languages) nil t nil nil default)))

(defun iuiw-playground--snippet-directory (&optional file)
  "Return the snippet directory containing FILE, or nil.
FILE defaults to the current buffer's file."
  (when-let* ((file (or file buffer-file-name))
              (relative (file-relative-name file iuiw-playground-directory))
              ((not (string-prefix-p ".." relative)))
              (parts (split-string relative "/"))
              ((> (length parts) 2)))
    (file-name-as-directory
     (expand-file-name (concat (nth 0 parts) "/" (nth 1 parts))
                       iuiw-playground-directory))))

(defun iuiw-playground--directory-language (directory)
  "Return the language name of snippet DIRECTORY."
  (car (split-string (file-relative-name directory iuiw-playground-directory) "/")))

(defun iuiw-playground--template-text (plist)
  "Return the template of language PLIST without its $0 marker."
  (string-replace "$0" "" (plist-get plist :template)))

(defun iuiw-playground--untouched-p (directory)
  "Return non-nil when DIRECTORY's source file still equals its template."
  (when-let* ((plist (iuiw-playground--language
                      (iuiw-playground--directory-language directory)))
              (file (expand-file-name (plist-get plist :file) directory))
              ((file-exists-p file)))
    (with-temp-buffer
      (insert-file-contents file)
      (equal (buffer-string) (iuiw-playground--template-text plist)))))

(defun iuiw-playground--visited-p (directory &optional except)
  "Return non-nil when a buffer other than EXCEPT visits a file in DIRECTORY."
  (seq-some (lambda (buffer)
              (and (not (eq buffer except))
                   (when-let* ((file (buffer-file-name buffer)))
                     (string-prefix-p directory file))))
            (buffer-list)))

(defun iuiw-playground--snippet-directories ()
  "Return all snippet directories, newest first."
  (sort (seq-mapcat (lambda (language)
                      (let ((root (expand-file-name (car language) iuiw-playground-directory)))
                        (when (file-directory-p root)
                          (seq-filter #'file-directory-p
                                      (directory-files root t "\\`[^.]")))))
                    iuiw-playground-languages)
        (lambda (a b) (string> (file-name-nondirectory a) (file-name-nondirectory b)))))

(defun iuiw-playground-clean ()
  "Delete snippets whose source file still equals its template.
Snippets visited by a buffer are kept."
  (interactive)
  (let ((count 0))
    (dolist (directory (iuiw-playground--snippet-directories))
      (when (and (iuiw-playground--untouched-p directory)
                 (not (iuiw-playground--visited-p (file-name-as-directory directory))))
        (delete-directory directory t)
        (setq count (1+ count))))
    (when (called-interactively-p 'interactive)
      (message "Deleted %d untouched snippet(s)" count))))

(defun iuiw-playground--clean-on-kill ()
  "Delete this buffer's snippet if untouched and no other buffer visits it."
  (when-let* ((directory (iuiw-playground--snippet-directory))
              ((iuiw-playground--untouched-p directory))
              ((not (iuiw-playground--visited-p directory (current-buffer)))))
    (delete-directory directory t)))

;;;###autoload
(defun iuiw-playground (language &optional name)
  "Create a snippet of LANGUAGE and visit it.
With a prefix argument, ask for a NAME to add to its directory."
  (interactive (list (iuiw-playground--read-language)
                     (when current-prefix-arg
                       (read-string "Snippet name: "))))
  (let* ((plist (iuiw-playground--language language))
         (directory (file-name-as-directory
                     (expand-file-name
                      (concat language "/" (format-time-string "%Y%m%d-%H%M%S")
                              (unless (string-empty-p (or name ""))
                                (concat "-" (replace-regexp-in-string
                                             "[^[:alnum:]_-]+" "-" name))))
                      iuiw-playground-directory)))
         (file (expand-file-name (plist-get plist :file) directory)))
    (make-directory directory t)
    (when-let* ((init (plist-get plist :init)))
      (let ((default-directory directory))
        (unless (zerop (call-process-shell-command init nil "*iuiw-playground-init*"))
          (pop-to-buffer "*iuiw-playground-init*")
          (user-error "`%s' failed in %s" init directory))))
    (make-directory (file-name-directory file) t)
    (setq iuiw-playground--last-language language)
    ;; 不经 save-buffer 写入，免得格式化改动内容，之后认不出没改过的片段。
    (write-region (iuiw-playground--template-text plist) nil file nil 'silent)
    (find-file file)
    (goto-char (1+ (or (string-search "$0" (plist-get plist :template)) 0)))))

;;;###autoload
(defun iuiw-playground-open ()
  "Visit a saved snippet, newest first."
  (interactive)
  (let* ((sorted
          (seq-keep (lambda (directory)
                      (let* ((language (iuiw-playground--directory-language directory))
                             (file (expand-file-name
                                    (plist-get (iuiw-playground--language language) :file)
                                    directory)))
                        (when (file-exists-p file)
                          (cons (concat language "/" (file-name-nondirectory directory))
                                file))))
                    (iuiw-playground--snippet-directories)))
         (choice (completing-read
                  "Snippet: "
                  (lambda (string predicate action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity))
                      (complete-with-action action sorted string predicate)))
                  nil t)))
    (find-file (cdr (assoc choice sorted)))))

(defun iuiw-playground-run ()
  "Save the snippet and run it."
  (interactive)
  (let* ((directory (or (iuiw-playground--snippet-directory)
                        (user-error "Not in a playground snippet")))
         (plist (iuiw-playground--language
                 (iuiw-playground--directory-language directory))))
    (save-buffer)
    (let ((quickrun-option-default-directory directory))
      (if-let* ((command (plist-get plist :exec)))
          ;; 不用临时副本：go run . 会把副本和 main.go 一起编译。
          (quickrun :source `((:command . ,(car (split-string command)))
                              (:exec . ,command)
                              (:tempfile . nil)))
        (quickrun)))))

(defun iuiw-playground-remove ()
  "Delete the current snippet's directory and kill its buffers."
  (interactive)
  (let ((directory (or (iuiw-playground--snippet-directory)
                       (user-error "Not in a playground snippet"))))
    (when (yes-or-no-p (format "Delete %s? " (abbreviate-file-name directory)))
      (dolist (buffer (buffer-list))
        (when-let* ((file (buffer-file-name buffer))
                    ((string-prefix-p directory file)))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory directory t delete-by-moving-to-trash))))

(defvar-keymap iuiw-playground-mode-map
  "C-c C-c" #'iuiw-playground-run
  "C-c C-k" #'iuiw-playground-remove)

(define-minor-mode iuiw-playground-mode
  "Run and delete the playground snippet in this buffer."
  :lighter " Play"
  (if iuiw-playground-mode
      (add-hook 'kill-buffer-hook #'iuiw-playground--clean-on-kill nil t)
    (remove-hook 'kill-buffer-hook #'iuiw-playground--clean-on-kill t)))

(defun iuiw-playground-maybe-enable ()
  "Enable `iuiw-playground-mode' in buffers visiting a snippet."
  (when (iuiw-playground--snippet-directory)
    (iuiw-playground-mode 1)))

(provide 'iuiw-playground)
;;; iuiw-playground.el ends here
