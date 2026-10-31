;;; iuiw-erpg-store.el --- erpg data repository -*- lexical-binding: t; -*-

;;; Commentary:
;; 读写 erpg 数据仓库：模型档案、preset、角色卡、战役、状态和剧情。
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

(defun iuiw-erpg-card (name &optional campaign)
  "Card NAME as a plist, CAMPAIGN's own version when it has one.
Its keys are :name, :age (a number), :voice, :model, :avatar and :body."
  (let* ((text (or (and campaign
                        (iuiw-erpg--read (expand-file-name (concat "cards/" name ".md")
                                                           (plist-get campaign :dir))))
                   (iuiw-erpg--read (iuiw-erpg-file "cards" (concat name ".md")))
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

(defconst iuiw-erpg-secret-heading "## 只给叙事者"
  "Heading in campaign.md above what only the narrator is told.")

(defun iuiw-erpg-campaign (id)
  "Campaign ID as a plist: its fields, :id, :dir, :body and :secret.
:prior holds the facts recorded in the main story of the campaign it follows."
  (let* ((dir (iuiw-erpg-file "campaigns" id))
         (fields (iuiw-erpg-parse (or (iuiw-erpg--read (expand-file-name "campaign.md" dir))
                                      (user-error "No campaign %s" id))))
         (body (plist-get fields :body))
         (split (string-match (concat "^" (regexp-quote iuiw-erpg-secret-heading) "[ \t]*$") body))
         (secret (and split (string-trim (substring body (match-end 0)))))
         (follows (plist-get fields :follows)))
    (append (list :id id :dir (file-name-as-directory dir)
                  :body (string-trim (substring body 0 split))
                  :secret secret
                  :prior (and follows
                              (let ((before (list :dir (file-name-as-directory
                                                        (iuiw-erpg-file "campaigns" follows)))))
                                (plist-get (iuiw-erpg-replay
                                            (iuiw-erpg-state before)
                                            (iuiw-erpg-story-read (iuiw-erpg-story-file before)))
                                           :facts)))
                  :cast (iuiw-erpg-split (plist-get fields :cast))
                  :narrator (iuiw-erpg-split (plist-get fields :narrator))
                  :voice (iuiw-erpg-split (plist-get fields :voice))
                  :recorder (iuiw-erpg-split (plist-get fields :recorder))
                  :depth (iuiw-erpg--number (plist-get fields :depth) 4))
            fields)))

(defconst iuiw-erpg-facts-heading "## 自动记录"
  "Heading in state.md above facts kept before the story held them.")

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

;;; Story

;; A story is markdown: each section opens with "### NAME", NAME being 旁白
;; for the narrator, 导演 for a director's note and anything else for the
;; player.  HTML comments in a section are never sent; three kinds mean
;; something: "意图 NAME" a character's intent, "记录" facts the recorder
;; noted, "在场：…" who is present and "叙事者：…" a director's note only
;; the narrator is shown.

(defconst iuiw-erpg-heading-regexp "^### +\\(.+?\\)[ \t]*$"
  "Matches the heading opening a section of a story.")

(defconst iuiw-erpg--comment-regexp "<!--\\(\\(?:.\\|\n\\)*?\\)-->"
  "Matches an HTML comment.")

(defconst iuiw-erpg-main-branch "主线"
  "Name of a campaign's main story among its branches.")

(defun iuiw-erpg-story-file (campaign &optional branch)
  "File of CAMPAIGN's story on BRANCH, the main story when nil."
  (expand-file-name (if (member branch (list nil "" iuiw-erpg-main-branch))
                        "story.md"
                      (concat "branches/" branch ".md"))
                    (plist-get campaign :dir)))

(defun iuiw-erpg-branches (campaign)
  "Names of CAMPAIGN's branches, the main one included, latest played first."
  (let* ((dir (expand-file-name "branches" (plist-get campaign :dir)))
         (files (cons (iuiw-erpg-story-file campaign)
                      (and (file-directory-p dir) (directory-files dir t "\\.md\\'")))))
    (mapcar (lambda (f) (or (iuiw-erpg-file-branch f) iuiw-erpg-main-branch))
            (sort files (lambda (a b)
                          (time-less-p (or (file-attribute-modification-time (file-attributes b)) 0)
                                       (or (file-attribute-modification-time (file-attributes a)) 0)))))))

(defun iuiw-erpg-file-branch (file)
  "The branch whose story is FILE, nil for a main story."
  (when (string-match-p "/branches/[^/]+\\.md\\'" file)
    (file-name-base file)))

(defun iuiw-erpg-file-campaign (file)
  "Id of the campaign FILE belongs to."
  (let ((rel (file-relative-name (expand-file-name file) (iuiw-erpg-file "campaigns"))))
    (when (string-prefix-p "../" rel)
      (user-error "%s is not in a campaign under %s" file iuiw-erpg-directory))
    (car (split-string rel "/"))))

(defun iuiw-erpg--comment-entry (text)
  "The entry a comment saying TEXT makes, or nil when it is only the user's."
  (setq text (string-trim text))
  (cond ((string-match "\\`意图[ \t]+\\([^ \t\n]+\\)" text)
         (list :role "voice" :name (match-string 1 text) :text (string-trim (substring text (match-end 0)))))
        ((string-match "\\`记录" text)
         (list :role "record" :text (string-trim (substring text (match-end 0)))))
        ((string-prefix-p "在场" text)
         (list :role "present" :text text))
        ((string-match "\\`叙事者[：:]" text)
         (list :role "note" :text (string-trim (substring text (match-end 0)))))))

(defun iuiw-erpg-story-entries ()
  "The story in the current buffer as entries, in order.
Each section gives an entry with :start, :body and :end positions, then
one entry per meaningful comment in it."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let (entries)
        (while (re-search-forward iuiw-erpg-heading-regexp nil t)
          (let* ((name (match-string-no-properties 1))
                 (start (match-beginning 0))
                 (body (min (1+ (match-end 0)) (point-max)))
                 (end (save-excursion
                        (goto-char body)
                        (if (re-search-forward iuiw-erpg-heading-regexp nil t)
                            (match-beginning 0)
                          (point-max))))
                 (raw (buffer-substring-no-properties body end))
                 (pos 0)
                 comments)
            (while (string-match iuiw-erpg--comment-regexp raw pos)
              (setq pos (match-end 0))
              (when-let* ((entry (iuiw-erpg--comment-entry (match-string 1 raw))))
                (push entry comments)))
            (push (list :role (pcase name ("旁白" "narrator") ("导演" "director") (_ "user"))
                        :name name
                        :text (string-trim (replace-regexp-in-string iuiw-erpg--comment-regexp "" raw))
                        :start start :body body :end end)
                  entries)
            (setq entries (append comments entries))
            (goto-char end)))
        (nreverse entries)))))

(defun iuiw-erpg-story-read (file)
  "Entries of the story in FILE, nil when it is missing."
  (when-let* ((text (iuiw-erpg--read file)))
    (with-temp-buffer
      (insert text)
      (iuiw-erpg-story-entries))))

(defun iuiw-erpg-replay (state entries)
  "STATE with the 记录 and 在场 comments among ENTRIES applied in order.
A 记录 says \"+ fact\" to add, \"- fact\" to drop, \"= fact\" lines for a
whole new list and \"在场：…\" for who is present."
  (let ((present (plist-get state :present))
        (facts (plist-get state :facts)))
    (dolist (e entries)
      (when (member (plist-get e :role) '("record" "present"))
        (let (whole)
          (dolist (line (split-string (plist-get e :text) "\n" t "[ \t]+"))
            (cond ((string-match "\\`在场[：:]\\(.*\\)" line)
                   (let ((names (string-trim (match-string 1 line))))
                     (setq present (unless (equal names "无") (iuiw-erpg-split names)))))
                  ((string-prefix-p "= " line) (push (substring line 2) whole))
                  ((string-prefix-p "- " line) (setq facts (remove (substring line 2) facts)))
                  ((string-prefix-p "+ " line) (setq facts (append facts (list (substring line 2)))))))
          (when whole (setq facts (nreverse whole))))))
    (list :present present :body (plist-get state :body) :facts facts)))

;; An entry is a plist: :role is "user", "director", "note", "narrator",
;; "voice", "record" or "present"; :text what it says; :name the heading or who intends.

(defun iuiw-erpg-entry (role text &rest props)
  "A new entry of ROLE saying TEXT, with extra PROPS."
  (append (list :role role :text text) props))

(defun iuiw-erpg-entry-text (entry)
  "The text ENTRY says."
  (plist-get entry :text))

(provide 'iuiw-erpg-store)
;;; iuiw-erpg-store.el ends here
