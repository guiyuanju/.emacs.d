;;; iuiw-erpg.el --- Role-play with LLMs through OpenRouter -*- lexical-binding: t; -*-

;;; Commentary:
;; 战役的剧情是一个 markdown 文件（主线 story.md，分支在 branches/），每段以「### 名字」开头：
;; 「旁白」是叙事者，「导演」是给叙事者的指令，其余是玩家。直接编辑就是改写历史；
;; C-c C-c 按文件现在的样子跑一轮：在场角色先各自写意图，叙事者再流式写正文。
;; 角色意图和记录员记下的事实是 HTML 注释，不发给叙事者；事实清单由注释依次算出，删掉剧情就一起删掉。
;; 数据在 `iuiw-erpg-directory'，新电脑上 `iuiw-erpg-setup' 一次装好。

;;; Code:

(require 'iuiw-erpg-store)
(require 'iuiw-erpg-llm)
(require 'crm)
(require 'markdown-mode)

(defcustom iuiw-erpg-models-url "https://openrouter.ai/api/v1/models"
  "Where OpenRouter lists its models."
  :type 'string
  :group 'iuiw-erpg)

(defcustom iuiw-erpg-avatar-height 96
  "Height in pixels of the avatars of who is present."
  :type 'natnum
  :group 'iuiw-erpg)

(defvar-local iuiw-erpg--campaign nil "The campaign this buffer plays.")
(defvar-local iuiw-erpg--busy nil "Non-nil while a turn is running.")
(defvar-local iuiw-erpg--narrators nil "Narrator models chosen for this buffer, overriding the campaign's.")
(defvar-local iuiw-erpg--header nil "Overlay showing the title and who is present.")
(defvar-local iuiw-erpg--changes nil "Change group of the narrator's writing, undone as one.")
(defvar-local iuiw-erpg--follow nil "Non-nil when point follows the narrator's writing.")

(defvar-keymap iuiw-erpg-mode-map
  "C-c C-c" '("发送" . iuiw-erpg-send)
  "C-c C-r" '("重写旁白" . iuiw-erpg-regenerate)
  "C-c C-g" '("续写旁白" . iuiw-erpg-continue)
  "C-c C-b" '("从这段分支" . iuiw-erpg-branch)
  "C-c C-o" '("切换分支" . iuiw-erpg-switch-branch)
  "C-c C-v" '("在场角色" . iuiw-erpg-present)
  "C-c C-t" '("state.md" . iuiw-erpg-edit-state)
  "C-c C-m" '("换叙事模型" . iuiw-erpg-narrators)
  "C-c C-l" '("换模型组合" . iuiw-erpg-set-combo)
  "C-c C-p" '("预览本轮发送的内容" . iuiw-erpg-preview)
  "C-c C-w" '("旁白字数" . iuiw-erpg-set-length)
  "C-c C-k" '("停止" . iuiw-erpg-stop)
  "C-c C-s" '("同步仓库" . iuiw-erpg-sync))

(defun iuiw-erpg--header-line ()
  "Keys worth knowing now."
  (let ((key (lambda (k) (propertize k 'face 'help-key-binding))))
    (if iuiw-erpg--busy
        (concat " 生成中…  " (funcall key "C-c C-k") " 停止")
      (concat " " (funcall key "C-c C-c") " 发送  " (funcall key "C-c C-r") " 重写  "
              (funcall key "C-c C-g") " 续写  " (funcall key "C-c C-b") " 分支  "
              (funcall key "C-c C-o") " 切换分支  " (funcall key "C-c C-v") " 在场  " (funcall key "C-c C-p") " 预览  "
              (funcall key "C-c") " 更多"))))

;;;###autoload
(define-derived-mode iuiw-erpg-mode markdown-mode "erpg"
  "Play an erpg campaign by editing its story.

\\{iuiw-erpg-mode-map}"
  (setq-local iuiw-erpg--campaign (iuiw-erpg-campaign (iuiw-erpg-file-campaign buffer-file-name)))
  (setq-local word-wrap-by-category t)
  (setq-local header-line-format '(:eval (iuiw-erpg--header-line)))
  (visual-line-mode 1)
  (rename-buffer (format "erpg:%s%s" (plist-get iuiw-erpg--campaign :id)
                         (if-let* ((branch (iuiw-erpg-file-branch buffer-file-name))) (concat "/" branch) ""))
                 t)
  (when (= (point-min) (point-max))
    (insert "### " (iuiw-erpg-player iuiw-erpg--campaign) "\n\n"))
  (iuiw-erpg--show-header))

;;;###autoload
(add-to-list 'auto-mode-alist
             '("/campaigns/[^/]+/\\(?:story\\|branches/[^/]+\\)\\.md\\'" . iuiw-erpg-mode))

;;; Header

(defun iuiw-erpg--avatar (card height)
  "CARD's avatar at most HEIGHT pixels high, or nil.
An avatar naming an image file under the repository shows as that image
where images can be shown; any other avatar is shown as text."
  (when-let* ((avatar (plist-get card :avatar)))
    (if (not (string-match-p (image-file-name-regexp) avatar))
        avatar
      (let ((file (iuiw-erpg-file avatar)))
        (when (and (display-images-p) (file-readable-p file))
          (propertize "*" 'display (create-image file nil nil :max-height height :ascent 'center)
                      'help-echo file))))))

(defun iuiw-erpg--cast-line (state)
  "Who is present in STATE, with their avatars, or nil when no one is."
  (let* ((campaign iuiw-erpg--campaign)
         (cards (delq nil (mapcar (lambda (name) (ignore-errors (iuiw-erpg-card name campaign)))
                                  (plist-get state :present)))))
    (when cards
      (mapconcat (lambda (card)
                   (concat (or (iuiw-erpg--avatar card iuiw-erpg-avatar-height) "")
                           " " (plist-get card :name)))
                 cards "   "))))

(defun iuiw-erpg--show-header ()
  "Show the title, the branch and who is present above the story."
  (unless (and iuiw-erpg--header (overlay-buffer iuiw-erpg--header))
    (setq iuiw-erpg--header (make-overlay (point-min) (point-min))))
  (let ((branch (iuiw-erpg-file-branch buffer-file-name))
        (cast (iuiw-erpg--cast-line (iuiw-erpg--state))))
    (overlay-put iuiw-erpg--header 'before-string
                 (concat (propertize (or (plist-get iuiw-erpg--campaign :title)
                                         (plist-get iuiw-erpg--campaign :id))
                                     'face 'bold)
                         (when branch (propertize (concat "  · " branch) 'face 'shadow))
                         "\n\n" (when cast (concat cast "\n\n"))))))

;;; Editing the story

(defun iuiw-erpg--state (&optional entries)
  "State now: state.md with the records in ENTRIES, else the story's, replayed."
  (iuiw-erpg-replay (iuiw-erpg-state iuiw-erpg--campaign)
                    (or entries (iuiw-erpg-story-entries))))

(defun iuiw-erpg--save ()
  "Save the story and refresh the header."
  (when (buffer-modified-p)
    (let ((save-silently t)) (save-buffer)))
  (iuiw-erpg--show-header))

(defun iuiw-erpg--comment-at (pos text)
  "Put a comment saying TEXT right after the text before POS."
  (save-excursion
    (goto-char pos)
    (skip-chars-backward " \t\n")
    (insert "\n\n<!-- " text (if (string-search "\n" text) "\n-->" " -->"))))

(defun iuiw-erpg--open-section (name)
  "Start a section NAME at the end of the story.
Returns a marker where its text goes."
  (save-excursion
    (goto-char (point-max))
    (skip-chars-backward " \t\n")
    (delete-region (point) (point-max))
    (insert (if (bobp) "" "\n\n") "### " name "\n\n")
    (point-marker)))

(defun iuiw-erpg--drop-empty-tail ()
  "Remove a last section with nothing written in it."
  (let ((last (car (last (iuiw-erpg-story-entries)))))
    (when (and last (member (plist-get last :role) '("user" "director"))
               (string-empty-p (plist-get last :text)))
      (delete-region (plist-get last :start) (point-max)))))

(defun iuiw-erpg--last-narrator (entries)
  "Index of the narrator's last section in ENTRIES, or nil."
  (cl-position "narrator" entries :key (lambda (e) (plist-get e :role)) :test #'equal :from-end t))

(defun iuiw-erpg--section-end ()
  "End of the section point is in."
  (save-excursion
    (end-of-line)
    (if (re-search-forward iuiw-erpg-heading-regexp nil t) (match-beginning 0) (point-max))))

;;; Turns

(defun iuiw-erpg--combo-aliases (role)
  "Models the campaign's combo gives ROLE, or nil."
  (when-let* ((name (plist-get iuiw-erpg--campaign :combo)))
    (plist-get (iuiw-erpg-combo name) role)))

(defun iuiw-erpg--narrator-aliases ()
  "Narrator models in fallback order."
  (or iuiw-erpg--narrators
      (plist-get iuiw-erpg--campaign :narrator)
      (iuiw-erpg--combo-aliases :narrator)
      (when-let* ((first (car (iuiw-erpg-models)))) (list (car first)))
      (user-error "No models: add one with M-x iuiw-erpg-add-model")))

(defun iuiw-erpg--voice-aliases (card)
  "Models CARD forms its intent with, in fallback order."
  (or (iuiw-erpg-split (plist-get card :model))
      (plist-get iuiw-erpg--campaign :voice)
      (iuiw-erpg--combo-aliases :voice)
      (iuiw-erpg--narrator-aliases)))

(defun iuiw-erpg--recorder-aliases ()
  "Models the recorder uses, in fallback order."
  (or (plist-get iuiw-erpg--campaign :recorder)
      (iuiw-erpg--combo-aliases :recorder)
      (plist-get iuiw-erpg--campaign :voice)
      (iuiw-erpg--combo-aliases :voice)
      (iuiw-erpg--narrator-aliases)))

(defun iuiw-erpg--rejected-file ()
  "Where refused and failed replies of this campaign are kept."
  (iuiw-erpg-file ".cache" "rejected" (concat (plist-get iuiw-erpg--campaign :id) ".md")))

(defun iuiw-erpg--reject (alias text error)
  "Keep the reply TEXT that ALIAS refused with, or its ERROR, out of the story."
  (let ((file (iuiw-erpg--rejected-file))
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (write-region (format "## %s %s %s\n\n%s\n\n" (format-time-string "%F %T") alias
                          (if error "failed" "refused") (if (string-blank-p (or text "")) error text))
                  nil file t 'silent)
    (message "%s %s; trying the next model (M-x iuiw-erpg-rejected)" alias (if error "failed" "refused"))))

(defun iuiw-erpg--recorded (entries)
  "Index in ENTRIES of the last 记录 comment, or -1."
  (or (cl-position "record" entries :key (lambda (e) (plist-get e :role)) :test #'equal :from-end t)
      -1))

(defun iuiw-erpg--unrecorded (entries)
  "Index of the narrator's last section in ENTRIES if the recorder has not read it."
  (let ((last (iuiw-erpg--last-narrator entries)))
    (and last (> last (iuiw-erpg--recorded entries)) last)))

(defun iuiw-erpg--recorder-messages (ctx last)
  "What the recorder is sent for the story in CTX up to entry LAST."
  (let ((entries (plist-get ctx :entries)))
    (list (iuiw-erpg-recorder-message
           (plist-get ctx :campaign) (plist-get ctx :state)
           (iuiw-erpg--story (seq-subseq entries (1+ (iuiw-erpg--recorded entries)) (1+ last)))))))

(defun iuiw-erpg--record (ctx)
  "Have the recorder note facts from replies the user has moved on from.
Its notes go in a 记录 comment after the last of them.  It runs beside the
turn; facts land a turn late, while the story they come from is still in
every prompt."
  (let* ((entries (plist-get ctx :entries))
         (last (iuiw-erpg--unrecorded entries))
         (campaign (plist-get ctx :campaign))
         (state (plist-get ctx :state))
         (buffer (current-buffer)))
    (when last
      (let ((at (copy-marker (plist-get (nth last entries) :end))))
        (iuiw-erpg-request-chain
         (iuiw-erpg--recorder-aliases)
         (iuiw-erpg-recorder-system (plist-get ctx :preset))
         (iuiw-erpg--recorder-messages ctx last)
         :buffer buffer
         :callback
         (lambda (text _alias)
           (let ((record (iuiw-erpg-parse-record text)))
             (cond ((not (buffer-live-p buffer)))
                   ((null record) (message "erpg: the recorder gave no usable answer; it tries again next turn"))
                   (t
                    (with-current-buffer buffer
                      (let ((changes (cdr (iuiw-erpg-apply-record campaign state record))))
                        (iuiw-erpg--comment-at at (string-join (cons "记录" changes) "\n"))
                        (unless iuiw-erpg--busy (iuiw-erpg--save)))))))))))))

(defun iuiw-erpg--context ()
  "The campaign reread from disk with its preset, story, state and cards."
  (let ((campaign (iuiw-erpg-campaign (plist-get iuiw-erpg--campaign :id)))
        (entries (iuiw-erpg-story-entries)))
    (setq iuiw-erpg--campaign campaign)
    (list :campaign campaign
          :entries entries
          :preset (iuiw-erpg-preset (or (plist-get campaign :preset) "default"))
          :state (iuiw-erpg--state entries)
          :cards (iuiw-erpg-cast campaign))))

(defun iuiw-erpg--finish (&optional message)
  "End the turn, showing MESSAGE when given."
  (setq iuiw-erpg--busy nil)
  (force-mode-line-update)
  (when iuiw-erpg--changes
    (accept-change-group iuiw-erpg--changes)
    (undo-amalgamate-change-group iuiw-erpg--changes)
    (setq iuiw-erpg--changes nil))
  (iuiw-erpg--save)
  (when message (message "%s" message)))

(defun iuiw-erpg--voice-cards (ctx)
  "Cards of the characters in CTX who form an intent this turn."
  (let ((campaign (plist-get ctx :campaign))
        (present (plist-get (plist-get ctx :state) :present)))
    (seq-filter (lambda (c)
                  (and (plist-get c :voice)
                       (member (plist-get c :name) present)
                       (member (plist-get c :name) (plist-get campaign :cast))
                       (not (equal (plist-get c :name) (plist-get campaign :player)))))
                (plist-get ctx :cards))))

(defun iuiw-erpg--voices (ctx done)
  "Ask each present character with a voice for its intent, then call DONE.
Intents go in 意图 comments at the end of the story."
  (let* ((campaign (plist-get ctx :campaign))
         (cards (iuiw-erpg--voice-cards ctx))
         (left (length cards))
         (buffer (current-buffer)))
    (if (zerop left)
        (funcall done)
      (message "Characters are deciding: %s"
               (mapconcat (lambda (c) (plist-get c :name)) cards "、"))
      (dolist (card cards)
        (let ((name (plist-get card :name)))
          (iuiw-erpg-request-chain
           (iuiw-erpg--voice-aliases card)
           (iuiw-erpg-voice-system campaign (plist-get ctx :preset) card (plist-get ctx :cards))
           (list (iuiw-erpg-voice-message campaign (plist-get ctx :preset) (plist-get ctx :state)
                                          (plist-get ctx :entries) card))
           :buffer buffer
           :on-fail (lambda (alias text error)
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer (iuiw-erpg--reject alias text error))))
           :callback (lambda (text _alias)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (when (and text iuiw-erpg--busy)
                             (iuiw-erpg--comment-at (point-max)
                                                    (format "意图 %s\n%s" name (string-trim text))))
                           (when (and (zerop (cl-decf left)) iuiw-erpg--busy)
                             (funcall done)))))))))))

(defun iuiw-erpg--intents (entries)
  "Intents formed since the last user or director section in ENTRIES.
They are returned as ((NAME . TEXT) ...)."
  (let ((since (or (cl-position-if (lambda (e) (member (plist-get e :role) '("user" "director")))
                                   entries :from-end t)
                   -1)))
    (cl-loop for e in (nthcdr (1+ since) entries)
             when (equal (plist-get e :role) "voice")
             collect (cons (plist-get e :name) (iuiw-erpg-entry-text e)))))

(defun iuiw-erpg--narrate (ctx mode)
  "Have the narrator write, streaming into the story.
MODE is `new' for a new section, `again' to rewrite the narrator's last
section, or `continue' to extend it."
  (let* ((campaign (plist-get ctx :campaign))
         (preset (plist-get ctx :preset))
         (entries (iuiw-erpg-story-entries))
         (target (unless (eq mode 'new)
                   (or (iuiw-erpg--last-narrator entries) (user-error "No reply yet"))))
         (entry (and target (nth target entries)))
         (before (if target (seq-take entries (if (eq mode 'continue) (1+ target) target)) entries))
         (intents (unless (eq mode 'continue) (iuiw-erpg--intents before)))
         (prefill (alist-get "prefill" preset nil nil #'equal))
         (messages (lambda (alias)
                     (iuiw-erpg-narrator-messages campaign preset (plist-get ctx :state) before intents
                                                  (eq mode 'continue)
                                                  (and (plist-get (iuiw-erpg-model alias) :prefill) prefill))))
         (buffer (current-buffer))
         (heading (and (eq mode 'new) (copy-marker (point-max))))
         (old (and (eq mode 'again) (buffer-substring (plist-get entry :body) (plist-get entry :end))))
         start end)
    ;; Fail before touching the story when the messages cannot be made.
    (funcall messages (car (iuiw-erpg--narrator-aliases)))
    (setq iuiw-erpg--changes (prepare-change-group))
    (activate-change-group iuiw-erpg--changes)
    (setq start (pcase mode
                  ('new (iuiw-erpg--open-section "旁白"))
                  ('again (delete-region (plist-get entry :body) (plist-get entry :end))
                          (save-excursion (goto-char (plist-get entry :body)) (insert "\n") (point-marker)))
                  ('continue (save-excursion (goto-char (plist-get entry :end))
                                             (skip-chars-backward " \t\n")
                                             (point-marker))))
          end (copy-marker start t))
    (iuiw-erpg-request-chain
     (iuiw-erpg--narrator-aliases)
     (iuiw-erpg-narrator-system campaign preset (plist-get ctx :cards))
     messages
     :buffer buffer
     :on-start (lambda (alias)
                 (with-current-buffer buffer
                   (delete-region start end)
                   (when iuiw-erpg--follow (goto-char end))
                   (message "%s is writing" alias)))
     :on-chunk (lambda (text)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (let ((follow (= (point) end)))
                       (save-excursion (goto-char end) (insert text))
                       (when follow (goto-char end))))))
     :on-fail (lambda (alias text error)
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (delete-region start end)
                    (iuiw-erpg--reject alias text error))))
     :callback
     (lambda (text _alias)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (cond ((not iuiw-erpg--busy))
                 ((null text)
                  (pcase mode
                    ('new (delete-region heading (point-max)))
                    ('again (delete-region start end)
                            (save-excursion (goto-char start) (delete-char -1) (insert old))))
                  (iuiw-erpg--finish "No model answered; M-x iuiw-erpg-rejected shows what came back"))
                 (t
                  (save-excursion
                    (unless (eq mode 'continue)
                      (goto-char start)
                      (delete-region start (progn (skip-chars-forward " \t\n" end) (point))))
                    (goto-char end)
                    (delete-region (progn (skip-chars-backward " \t\n" start) (point)) end)
                    (when (and (eq mode 'again) (not (eobp)))
                      (insert "\n\n")))
                  (when (eq mode 'new)
                    (iuiw-erpg--open-section (iuiw-erpg-player campaign))
                    (when iuiw-erpg--follow (goto-char (point-max))))
                  (iuiw-erpg--finish)))))))))

(defun iuiw-erpg--start ()
  "Mark a turn as running, an error when one already is."
  (when iuiw-erpg--busy
    (user-error "A turn is running; C-c C-k stops it"))
  (setq iuiw-erpg--busy t)
  (force-mode-line-update))

(defmacro iuiw-erpg--turn (&rest body)
  "Run BODY as a turn, ending it when BODY signals."
  (declare (indent 0))
  `(progn
     (iuiw-erpg--start)
     (condition-case err
         (progn ,@body)
       (error (setq iuiw-erpg--busy nil)
              (when iuiw-erpg--changes
                (cancel-change-group iuiw-erpg--changes)
                (setq iuiw-erpg--changes nil))
              (signal (car err) (cdr err))))))

;;; Commands

(defun iuiw-erpg-send ()
  "Play a turn on the story as it is now.
Write what you do in the section under your name at the end, or under a
### 导演 heading for a note to the narrator; with nothing new the story goes on."
  (interactive nil iuiw-erpg-mode)
  (iuiw-erpg--turn
    (setq iuiw-erpg--follow (save-excursion
                              (or (not (re-search-forward iuiw-erpg-heading-regexp nil t))
                                  (eobp))))
    (iuiw-erpg--drop-empty-tail)
    (let ((ctx (iuiw-erpg--context))
          (buffer (current-buffer)))
      (iuiw-erpg--save)
      (iuiw-erpg--record ctx)
      (iuiw-erpg--voices ctx (lambda ()
                               (with-current-buffer buffer
                                 (iuiw-erpg--narrate ctx 'new)))))))

(defun iuiw-erpg-regenerate ()
  "Rewrite the narrator's last section; undo brings the old one back."
  (interactive nil iuiw-erpg-mode)
  (iuiw-erpg--turn
    (setq iuiw-erpg--follow nil)
    (iuiw-erpg--narrate (iuiw-erpg--context) 'again)))

(defun iuiw-erpg-continue ()
  "Have the narrator carry on writing its last section."
  (interactive nil iuiw-erpg-mode)
  (iuiw-erpg--turn
    (setq iuiw-erpg--follow nil)
    (iuiw-erpg--narrate (iuiw-erpg--context) 'continue)))

(defun iuiw-erpg-branch (name)
  "Start branch NAME from the story up to the end of the section at point."
  (interactive (list (read-string "Branch name: ")) iuiw-erpg-mode)
  (when (or (string-empty-p name) (string-match-p "[/\\]" name))
    (user-error "Not a usable branch name: %s" name))
  (let ((file (iuiw-erpg-story-file iuiw-erpg--campaign name))
        (text (string-trim-right (buffer-substring-no-properties (point-min) (iuiw-erpg--section-end))))
        (player (iuiw-erpg-player iuiw-erpg--campaign)))
    (when (file-exists-p file) (user-error "Branch %s exists" name))
    (make-directory (file-name-directory file) t)
    (iuiw-erpg-with-file file (insert text "\n\n### " player "\n\n"))
    (iuiw-erpg--visit file)))

(defun iuiw-erpg-switch-branch (branch)
  "Go to BRANCH of this campaign."
  (interactive (list (iuiw-erpg--read-branch iuiw-erpg--campaign)) iuiw-erpg-mode)
  (iuiw-erpg--visit (iuiw-erpg-story-file iuiw-erpg--campaign branch)))

(defun iuiw-erpg-present (names)
  "Set who of the cast is present to NAMES, noted in the story."
  (interactive
   (list (completing-read-multiple
          "Present: " (plist-get iuiw-erpg--campaign :cast) nil t
          (string-join (plist-get (iuiw-erpg--state) :present) ",")))
   iuiw-erpg-mode)
  (iuiw-erpg--comment-at (point-max) (concat "在场：" (if names (string-join names "、") "无")))
  (iuiw-erpg--save)
  (message "Present: %s" (string-join names "、")))

(defun iuiw-erpg-edit-state ()
  "Open the campaign's state.md, notes every model reads each turn."
  (interactive nil iuiw-erpg-mode)
  (find-file-other-window (expand-file-name "state.md" (plist-get iuiw-erpg--campaign :dir))))

(defun iuiw-erpg-rejected ()
  "Show the replies this campaign's models refused or failed with."
  (interactive nil iuiw-erpg-mode)
  (find-file-other-window (iuiw-erpg--rejected-file))
  (goto-char (point-max)))

(defun iuiw-erpg-narrators (aliases)
  "Use model ALIASES, in fallback order, as narrators in this buffer.
No aliases restore the campaign's."
  (interactive
   (list (completing-read-multiple "Narrator models (empty for the campaign's): "
                                   (mapcar #'car (iuiw-erpg-models))))
   iuiw-erpg-mode)
  (setq iuiw-erpg--narrators aliases)
  (message "Narrators: %s" (string-join (iuiw-erpg--narrator-aliases) " → ")))

(defun iuiw-erpg-set-combo (name)
  "Use model combination NAME in this campaign, writing it to campaign.md."
  (interactive
   (list (completing-read "Combo: " (mapcar #'car (iuiw-erpg-combos)) nil t nil nil
                          (plist-get iuiw-erpg--campaign :combo)))
   iuiw-erpg-mode)
  (iuiw-erpg-combo name)
  (iuiw-erpg--set-field "combo" name)
  (message "Combo %s; narrators: %s" name (string-join (iuiw-erpg--narrator-aliases) " → ")))

(defun iuiw-erpg-stop ()
  "Stop the running turn, keeping what was written."
  (interactive nil iuiw-erpg-mode)
  (setq iuiw-erpg--busy nil)
  (iuiw-erpg-abort (current-buffer))
  (iuiw-erpg--finish "Stopped"))

(defun iuiw-erpg--visit (file)
  "Play the story in FILE."
  (find-file file)
  (unless (derived-mode-p 'iuiw-erpg-mode) (iuiw-erpg-mode))
  (goto-char (point-max)))

(defun iuiw-erpg--read-branch (campaign)
  "Ask for one of CAMPAIGN's branches, the latest played first."
  (let ((branches (iuiw-erpg-branches campaign)))
    (if (null (cdr branches))
        (car branches)
      (completing-read "Branch: "
                       (lambda (string pred action)
                         (if (eq action 'metadata)
                             '(metadata (display-sort-function . identity))
                           (complete-with-action action branches string pred)))
                       nil t))))

(defun iuiw-erpg--preview-part (title aliases system messages &optional moving)
  "Insert what model ALIASES are sent as TITLE: SYSTEM, then MESSAGES.
MOVING is the index of the first message that changes from turn to turn,
the last one when nil.  Returns how many characters are sent."
  (let* ((size (+ (length system) (apply #'+ (mapcar #'length messages))))
         (stable (+ (length system)
                    (apply #'+ (mapcar #'length (seq-take messages (or moving (1- (length messages)))))))))
    (insert (propertize (format "━━━━ %s  %s  约 %d 字，开头 %d 字每轮不变、可缓存 ━━━━"
                                title (string-join aliases " → ") size stable)
                        'face 'bold)
            "\n\n" (propertize "[system]" 'face 'font-lock-keyword-face) "\n" system "\n")
    (cl-loop for m in messages for i from 0
             do (insert "\n" (propertize (if (cl-evenp i) "[user]" "[assistant]") 'face 'font-lock-keyword-face)
                        "\n" m "\n"))
    (insert "\n")
    size))

(defun iuiw-erpg-preview ()
  "Show everything the next C-c C-c would send to the models."
  (interactive nil iuiw-erpg-mode)
  (let* ((ctx (iuiw-erpg--context))
         (campaign (plist-get ctx :campaign))
         (preset (plist-get ctx :preset))
         (state (plist-get ctx :state))
         (entries (plist-get ctx :entries))
         (cards (iuiw-erpg--voice-cards ctx))
         (narrators (iuiw-erpg--narrator-aliases))
         (prefill (alist-get "prefill" preset nil nil #'equal))
         (narrator (iuiw-erpg-narrator-messages
                    campaign preset state entries
                    (mapcar (lambda (c) (cons (plist-get c :name) "（这一轮生成的意图）")) cards)
                    nil (and (plist-get (iuiw-erpg-model (car narrators)) :prefill) prefill)))
         (last (iuiw-erpg--unrecorded entries))
         (total 0))
    (with-current-buffer (get-buffer-create (format "*erpg preview %s*" (plist-get campaign :id)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (c cards)
          (cl-incf total (iuiw-erpg--preview-part
                          (concat (plist-get c :name) "的意图") (iuiw-erpg--voice-aliases c)
                          (iuiw-erpg-voice-system campaign preset c (plist-get ctx :cards))
                          (list (iuiw-erpg-voice-message campaign preset state entries c)))))
        (cl-incf total (iuiw-erpg--preview-part
                        "叙事者" narrators
                        (iuiw-erpg-narrator-system campaign preset (plist-get ctx :cards))
                        narrator
                        (when-let* ((depth (alist-get "depth" preset nil nil #'equal)))
                          (cl-position-if (lambda (m) (string-search depth m)) narrator))))
        (when last
          (cl-incf total (iuiw-erpg--preview-part "记录员" (iuiw-erpg--recorder-aliases)
                                                  (iuiw-erpg-recorder-system preset)
                                                  (iuiw-erpg--recorder-messages ctx last))))
        (goto-char (point-min))
        (insert (format "本轮共 %d 次请求，约 %d 字；模型只列 fallback 顺序，实际发给第一个答得上的。\n\n"
                        (+ (length cards) 1 (if last 1 0)) total)))
      (special-mode)
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

(defun iuiw-erpg--set-field (field value)
  "Write FIELD as VALUE into the campaign's front matter."
  (let ((file (expand-file-name "campaign.md" (plist-get iuiw-erpg--campaign :dir))))
    (iuiw-erpg-with-file file
      (insert-file-contents file)
      (goto-char (point-min))
      (if (re-search-forward (concat "^" field ":.*$") nil t)
          (replace-match (concat field ": " value) t t)
        (forward-line 1)
        (insert field ": " value "\n")))
    (setq iuiw-erpg--campaign (iuiw-erpg-campaign (plist-get iuiw-erpg--campaign :id)))))

(defun iuiw-erpg-set-length (length)
  "Have the narrator write LENGTH characters a section, writing it to campaign.md."
  (interactive
   (list (read-string "Characters per section (e.g. 600-1000): " (plist-get iuiw-erpg--campaign :length)))
   iuiw-erpg-mode)
  (iuiw-erpg--set-field "length" length)
  (message "The narrator now writes %s characters a section" length))

;;;###autoload
(defun iuiw-erpg-open (id &optional branch)
  "Play campaign ID, on BRANCH when given, else its main story."
  (interactive
   (let* ((id (completing-read "Campaign: " (iuiw-erpg-campaign-ids) nil t)))
     (list id (iuiw-erpg--read-branch (iuiw-erpg-campaign id)))))
  (iuiw-erpg--visit (iuiw-erpg-story-file (iuiw-erpg-campaign id) branch)))

;;;###autoload
(defun iuiw-erpg-new-campaign (id title cast player)
  "Make campaign ID called TITLE with CAST, the player playing card PLAYER."
  (interactive
   (let ((cards (iuiw-erpg-card-names)))
     (list (read-string "Id (letters, digits, -): ")
           (read-string "Title: ")
           (completing-read-multiple "Cast: " cards nil t)
           (completing-read "Player's card (empty for 「你」): " cards nil t))))
  (let ((dir (iuiw-erpg-file "campaigns" id)))
    (when (file-exists-p dir) (user-error "Campaign %s exists" id))
    (dolist (name (append cast (unless (string-empty-p player) (list player))))
      (iuiw-erpg-card name))
    (make-directory dir t)
    (iuiw-erpg-with-file (expand-file-name "campaign.md" dir)
      (insert "---\n"
              "title: " title "\n"
              "player: " player "\n"
              "cast: " (string-join cast ", ") "\n"
              "preset: default\n"
              "combo: value       # combos.eld 里的模型组合：budget、value、premium\n"
              "narrator:          # 模型别名，逗号分隔即 fallback 顺序；空则用 combo 的\n"
              "voice:             # 生成角色意图用的模型；空则用 combo 的\n"
              "recorder:          # 记下剧情事实的模型；空则用 combo 的\n"
              "intensity:         # 尺度，自由描述\n"
              "length: 200-400\n"
              "depth: 4\n"
              "---\n"
              "世界与开场。\n"))
    (iuiw-erpg-set-present (iuiw-erpg-campaign id) cast)
    (find-file (expand-file-name "campaign.md" dir))))

;;; Setup and sync

(defun iuiw-erpg--git (args callback)
  "Run git with ARGS in the data repository, then call CALLBACK with (OK OUTPUT)."
  (let ((default-directory (file-name-as-directory (expand-file-name iuiw-erpg-directory)))
        (out (generate-new-buffer " *erpg-git*")))
    (make-process
     :name "erpg-git" :buffer out :command (cons "git" args) :noquery t
     :sentinel (lambda (proc _)
                 (unless (process-live-p proc)
                   (let ((text (with-current-buffer out (string-trim (buffer-string)))))
                     (kill-buffer out)
                     (funcall callback (zerop (process-exit-status proc)) text)))))))

;;;###autoload
(defun iuiw-erpg-sync ()
  "Commit the data repository, pull with rebase and push."
  (interactive)
  (iuiw-erpg--git
   '("add" "-A")
   (lambda (_ _)
     (iuiw-erpg--git
      (list "commit" "-m" (format "Sync from %s" (system-name)))
      (lambda (_ _)
        (iuiw-erpg--git
         '("pull" "--rebase")
         (lambda (ok text)
           (if (not ok)
               (message "erpg pull failed: %s" text)
             (iuiw-erpg--git '("push")
                             (lambda (ok text)
                               (message (if ok "erpg synced" "erpg push failed: %s") text)))))))))))

(defun iuiw-erpg--models-cache ()
  "Path of the cached OpenRouter model list."
  (iuiw-erpg-file ".cache" "models.json"))

(defun iuiw-erpg-refresh-models ()
  "Fetch OpenRouter's model list into the cache."
  (interactive)
  (let ((file (iuiw-erpg--models-cache)))
    (make-directory (file-name-directory file) t)
    (with-current-buffer (url-retrieve-synchronously iuiw-erpg-models-url t t 60)
      (goto-char (point-min))
      (re-search-forward "\r?\n\r?\n")
      (let ((coding-system-for-write 'utf-8))
        (write-region (point) (point-max) file nil 'silent))
      (kill-buffer))
    (message "Cached %s" file)))

(defun iuiw-erpg--openrouter-models ()
  "OpenRouter's models as a list of plists, fetched when not cached."
  (unless (file-exists-p (iuiw-erpg--models-cache))
    (iuiw-erpg-refresh-models))
  (append (plist-get (json-parse-string (iuiw-erpg--read (iuiw-erpg--models-cache))
                                        :object-type 'plist :null-object nil :false-object nil)
                     :data)
          nil))

(defun iuiw-erpg--free-p (model)
  "Non-nil when OpenRouter charges nothing for MODEL, a plist from its list."
  (let ((pricing (plist-get model :pricing)))
    (and (zerop (string-to-number (or (plist-get pricing :prompt) "1")))
         (zerop (string-to-number (or (plist-get pricing :completion) "1"))))))

(defun iuiw-erpg--price (pricing key)
  "PRICING's KEY in dollars per million tokens, as text."
  (let ((value (plist-get pricing key)))
    (if value (format "%.2f" (* 1e6 (string-to-number value))) "?")))

;;;###autoload
(defun iuiw-erpg-add-model (&optional all)
  "Pick an OpenRouter model and add it to models.eld under an alias.
Free models come first.  Models OpenRouter moderates are left out unless
ALL, the prefix argument."
  (interactive "P")
  (let* ((models (seq-filter (lambda (m)
                               (or all (not (plist-get (plist-get m :top_provider) :is_moderated))))
                             (iuiw-erpg--openrouter-models)))
         (table (mapcar (lambda (m) (cons (plist-get m :id) m))
                        (append (seq-filter #'iuiw-erpg--free-p models)
                                (seq-remove #'iuiw-erpg--free-p models))))
         (id (completing-read
              "Model: "
              (lambda (string pred action)
                (if (eq action 'metadata)
                    `(metadata
                      (display-sort-function . identity)
                      (annotation-function
                       . ,(lambda (id)
                            (let ((m (cdr (assoc id table))))
                              (format "  %s  %sk ctx%s"
                                      (if (iuiw-erpg--free-p m)
                                          (propertize "FREE" 'face 'success)
                                        (format "in $%s  out $%s /M"
                                                (iuiw-erpg--price (plist-get m :pricing) :prompt)
                                                (iuiw-erpg--price (plist-get m :pricing) :completion)))
                                      (/ (or (plist-get m :context_length) 0) 1000)
                                      (if (plist-get (plist-get m :top_provider) :is_moderated)
                                          "  moderated" ""))))))
                  (complete-with-action action table string pred)))
              nil t))
         (alias (read-string "Alias: " (car (last (split-string id "/")))))
         (prefill (y-or-n-p "Send the preset's prefill to this model? "))
         (free (iuiw-erpg--free-p (cdr (assoc id table))))
         (existing (assoc-delete-all alias (iuiw-erpg-models))))
    (iuiw-erpg-save-models
     (append existing
             (list (cons alias (append (list :id id)
                                       (and prefill '(:prefill t))
                                       ;; Free endpoints mostly keep prompts.
                                       (and free '(:provider (:data_collection "allow"))))))))
    (message "Added %s as %s%s" id alias (if free ", allowing data retention" ""))))

;;;###autoload
(defun iuiw-erpg-setup ()
  "Get erpg ready on this machine.
Clone or update the data, cache the model list and check the key."
  (interactive)
  (let ((dir (expand-file-name iuiw-erpg-directory)))
    (if (file-directory-p dir)
        (let ((default-directory dir))
          (unless (zerop (call-process "git" nil nil nil "pull" "--rebase"))
            (message "erpg: git pull failed; sync by hand")))
      (unless (zerop (call-process "git" nil nil nil "clone" iuiw-erpg-remote dir))
        (user-error "Could not clone %s" iuiw-erpg-remote)))
    (iuiw-erpg-refresh-models)
    (if (iuiw-erpg-key)
        (message "erpg ready in %s" dir)
      (message "erpg cloned; add `machine openrouter.ai login apikey password KEY' to authinfo"))))

(provide 'iuiw-erpg)
;;; iuiw-erpg.el ends here
