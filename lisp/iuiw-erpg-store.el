;;; iuiw-erpg-store.el --- erpg data repository -*- lexical-binding: t; -*-

;;; Commentary:
;; 读写 erpg 数据仓库：模型档案、preset、角色卡、战役、状态和对白记录。
;; 格式见仓库的 README.md。

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup iuiw-erpg nil
  "Role-play with LLMs through OpenRouter."
  :group 'applications)

(defcustom iuiw-erpg-directory "~/erpg/"
  "Root of the erpg data repository."
  :type 'directory)

(defcustom iuiw-erpg-remote "https://github.com/guiyuanju/erpg.git"
  "Where `iuiw-erpg-setup' clones the data repository from."
  :type 'string)

(defun iuiw-erpg-file (&rest parts)
  "Path of PARTS under `iuiw-erpg-directory'."
  (expand-file-name (string-join parts "/") iuiw-erpg-directory))

(defun iuiw-erpg--read (file)
  "Contents of FILE, or nil when it is missing."
  (when (file-readable-p file)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (buffer-string))))

(defun iuiw-erpg-parse (text)
  "Plist of TEXT's front matter as keyword keys and string values, plus :body."
  (let (fields (body text))
    (when (string-match "\\`---[ \t]*\n\\(\\(?:.*\n\\)*?\\)---[ \t]*\\(?:\n\\|\\'\\)" text)
      (setq body (substring text (match-end 0)))
      (dolist (line (split-string (match-string 1 text) "\n" t))
        (when (string-match "\\`\\([a-z-]+\\):\\(.*\\)\\'" line)
          (let* ((key (intern (concat ":" (match-string 1 line))))
                 (value (string-trim (replace-regexp-in-string
                                      "\\(?:\\`\\|[ \t]\\)#.*" "" (match-string 2 line)))))
            (unless (string-empty-p value)
              (setq fields (plist-put fields key value)))))))
    (plist-put fields :body (string-trim body))))

(defun iuiw-erpg-split (value)
  "VALUE split at commas into trimmed, non-empty strings."
  (and value (split-string value "[,，、]" t "[ \t]+")))

(defmacro iuiw-erpg-with-file (file &rest body)
  "Write what BODY inserts to FILE as UTF-8."
  (declare (indent 1))
  `(let ((coding-system-for-write 'utf-8-unix))
     (with-temp-file ,file ,@body)))

(defun iuiw-erpg--number (value default)
  "VALUE read as a number, or DEFAULT."
  (if (and value (string-match-p "\\`[0-9]+\\'" value)) (string-to-number value) default))

;;; Models and presets

(defun iuiw-erpg-models ()
  "The model profiles in models.eld, as ((ALIAS . PLIST) ...)."
  (when-let* ((text (iuiw-erpg--read (iuiw-erpg-file "models.eld"))))
    (mapcar (lambda (entry) (cons (symbol-name (car entry)) (cdr entry)))
            (car (read-from-string text)))))

(defun iuiw-erpg-model (alias)
  "Profile of model ALIAS, an error when unknown."
  (or (alist-get alias (iuiw-erpg-models) nil nil #'equal)
      (user-error "No model %s in models.eld; add one with M-x iuiw-erpg-add-model" alias)))

(defun iuiw-erpg-combos ()
  "The model combinations in combos.eld, as ((NAME . PLIST) ...).
PLIST maps :narrator, :voice and :recorder to lists of model aliases."
  (when-let* ((text (iuiw-erpg--read (iuiw-erpg-file "combos.eld"))))
    (mapcar (lambda (entry) (cons (symbol-name (car entry)) (cdr entry)))
            (car (read-from-string text)))))

(defun iuiw-erpg-combo (name)
  "Combination NAME, an error when unknown."
  (or (alist-get name (iuiw-erpg-combos) nil nil #'equal)
      (user-error "No combo %s in combos.eld" name)))

(defun iuiw-erpg-save-models (models)
  "Write MODELS, as ((ALIAS . PLIST) ...), to models.eld."
  (iuiw-erpg-with-file (iuiw-erpg-file "models.eld")
    (insert ";; 模型档案：(别名 :id \"OpenRouter 模型 id\" [:prefill t] [:params (:temperature 1.0 :max_tokens 1500)]\n"
            ";;          [:provider (:data_collection \"allow\")])，:provider 代替默认的不留存数据\n"
            ";; 用 M-x iuiw-erpg-add-model 从 OpenRouter 的模型列表挑选加入。\n")
    (let ((print-length nil) (print-level nil))
      (pp (mapcar (lambda (m) (cons (intern (car m)) (cdr m))) models) (current-buffer)))))

(defun iuiw-erpg-preset (name)
  "Sections of preset NAME as an alist of (SECTION . TEXT), empty ones left out."
  (let ((text (or (iuiw-erpg--read (iuiw-erpg-file "presets" (concat name ".md")))
                  (user-error "No preset %s" name)))
        sections)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "^## +\\([a-z-]+\\)[ \t]*$" nil t)
        (let ((section (match-string 1))
              (start (1+ (line-end-position)))
              (end (save-excursion
                     (if (re-search-forward "^## +[a-z-]+[ \t]*$" nil t)
                         (line-beginning-position)
                       (point-max)))))
          (let ((body (string-trim (buffer-substring-no-properties (min start end) end))))
            (unless (string-empty-p body)
              (push (cons section body) sections))))))
    (nreverse sections)))

;;; Cards

(defun iuiw-erpg-card-names ()
  "Names of all character cards."
  (mapcar #'file-name-base (directory-files (iuiw-erpg-file "cards") nil "\\.md\\'")))

(defun iuiw-erpg-card (name)
  "Card NAME as a plist.
Its keys are :name, :age (a number), :voice, :model, :avatar and :body."
  (let* ((text (or (iuiw-erpg--read (iuiw-erpg-file "cards" (concat name ".md")))
                   (user-error "No card %s" name)))
         (card (iuiw-erpg-parse text))
         (age (iuiw-erpg--number (plist-get card :age) nil)))
    (unless age
      (user-error "Card %s has no age; age is required" name))
    (list :name name :age age
          :voice (not (member (plist-get card :voice) '("false" "no" "nil")))
          :model (plist-get card :model)
          :avatar (plist-get card :avatar)
          :body (plist-get card :body))))

(defun iuiw-erpg-minor-p (card)
  "Non-nil when CARD is under 18."
  (< (plist-get card :age) 18))

;;; Campaigns

(defun iuiw-erpg-campaign-ids ()
  "Ids of all campaigns."
  (let ((root (iuiw-erpg-file "campaigns")))
    (seq-filter (lambda (id) (file-exists-p (expand-file-name (concat id "/campaign.md") root)))
                (and (file-directory-p root)
                     (directory-files root nil "\\`[^.]")))))

(defun iuiw-erpg-campaign (id)
  "Campaign ID as a plist: its fields, :id, :dir and :body."
  (let* ((dir (iuiw-erpg-file "campaigns" id))
         (fields (iuiw-erpg-parse (or (iuiw-erpg--read (expand-file-name "campaign.md" dir))
                                      (user-error "No campaign %s" id)))))
    (append (list :id id :dir (file-name-as-directory dir)
                  :cast (iuiw-erpg-split (plist-get fields :cast))
                  :narrator (iuiw-erpg-split (plist-get fields :narrator))
                  :voice (iuiw-erpg-split (plist-get fields :voice))
                  :recorder (iuiw-erpg-split (plist-get fields :recorder))
                  :depth (iuiw-erpg--number (plist-get fields :depth) 4))
            fields)))

(defconst iuiw-erpg-facts-heading "## 自动记录"
  "Heading in state.md above the facts the recorder keeps.")

(defun iuiw-erpg-state-file (campaign)
  "CAMPAIGN's state.md."
  (expand-file-name "state.md" (plist-get campaign :dir)))

(defun iuiw-erpg-state (campaign)
  "CAMPAIGN's state as a plist.
:present and :facts are lists of strings, :body the user's notes."
  (let* ((state (iuiw-erpg-parse (or (iuiw-erpg--read (iuiw-erpg-state-file campaign)) "")))
         (body (plist-get state :body))
         (split (string-match (concat "^" (regexp-quote iuiw-erpg-facts-heading) "[ \t]*$") body))
         (facts (and split (substring body (match-end 0)))))
    (list :present (if (plist-member state :present)
                       (iuiw-erpg-split (plist-get state :present))
                     (plist-get campaign :cast))
          :body (string-trim (substring body 0 split))
          :facts (and facts
                      (cl-loop for line in (split-string facts "\n" t)
                               when (string-match "\\`- +\\(.+\\)" line)
                               collect (string-trim (match-string 1 line)))))))

(defun iuiw-erpg-write-state (campaign state)
  "Write STATE, a plist as `iuiw-erpg-state' returns, as CAMPAIGN's state.md."
  (iuiw-erpg-with-file (iuiw-erpg-state-file campaign)
    (insert "---\npresent: " (string-join (plist-get state :present) ", ") "\n---\n")
    (unless (string-empty-p (plist-get state :body))
      (insert (plist-get state :body) "\n"))
    (when (plist-get state :facts)
      (insert "\n" iuiw-erpg-facts-heading "\n")
      (dolist (fact (plist-get state :facts))
        (insert "- " fact "\n")))))

(defun iuiw-erpg-set-present (campaign names)
  "Record NAMES as who is present in CAMPAIGN, keeping the rest of the state."
  (iuiw-erpg-write-state campaign (plist-put (iuiw-erpg-state campaign) :present names)))

;;; Log

;; An entry is a plist: :role is "user", "director", "narrator", "voice" or
;; "record"; :swipes a vector of texts with :index the one shown; optional
;; :name, :model, :time, :hidden for replies that are kept but never sent,
;; and :recorded on narrator replies the recorder has read.

(defun iuiw-erpg-log-file (campaign)
  "CAMPAIGN's log file."
  (expand-file-name "log.jsonl" (plist-get campaign :dir)))

(defun iuiw-erpg-log-read (campaign)
  "CAMPAIGN's log entries, oldest first."
  (when-let* ((text (iuiw-erpg--read (iuiw-erpg-log-file campaign))))
    (mapcar (lambda (line)
              (json-parse-string line :object-type 'plist :array-type 'array
                                 :false-object nil :null-object nil))
            (split-string text "\n" t))))

(defun iuiw-erpg-log-write (campaign entries)
  "Replace CAMPAIGN's log with ENTRIES."
  (iuiw-erpg-with-file (iuiw-erpg-log-file campaign)
    (dolist (entry entries)
      (insert (json-serialize
               (cl-loop for (key value) on entry by #'cddr
                        when value append (list key value)))
              "\n"))))

(defun iuiw-erpg-entry (role text &rest props)
  "A new log entry of ROLE saying TEXT, with extra PROPS."
  (append (list :role role :swipes (vector text) :index 0 :time (float-time)) props))

(defun iuiw-erpg-entry-text (entry)
  "The text ENTRY shows."
  (aref (plist-get entry :swipes) (plist-get entry :index)))

(defun iuiw-erpg-entry-set-text (entry text)
  "Make ENTRY show TEXT in place of its current swipe."
  (let ((swipes (copy-sequence (plist-get entry :swipes))))
    (aset swipes (plist-get entry :index) text)
    (plist-put entry :swipes swipes)))

(defun iuiw-erpg-entry-add-swipe (entry text)
  "Add TEXT to ENTRY as a new swipe and show it."
  (let ((swipes (vconcat (plist-get entry :swipes) (vector text))))
    (plist-put (plist-put entry :swipes swipes) :index (1- (length swipes)))))

(provide 'iuiw-erpg-store)
;;; iuiw-erpg-store.el ends here
