;;; iuiw-erpg.el --- Role-play with LLMs through OpenRouter -*- lexical-binding: t; -*-

;;; Commentary:
;; `iuiw-erpg-open' 打开一个战役：上面是对白，末尾 > 后输入。
;; 输入直接发送是玩家的行动或对白；以 // 开头是导演指令；空输入让剧情自己往下走。
;; 每一轮先让在场角色各自写意图，再由叙事者流式写正文；被拒绝的回复隐藏起来不再发送。
;; 数据在 `iuiw-erpg-directory'，新电脑上 `iuiw-erpg-setup' 一次装好。

;;; Code:

(require 'iuiw-erpg-store)
(require 'iuiw-erpg-llm)
(require 'crm)

(defcustom iuiw-erpg-show-voices t
  "Whether characters' intents and the recorder's changes are shown."
  :type 'boolean
  :group 'iuiw-erpg)

(defcustom iuiw-erpg-models-url "https://openrouter.ai/api/v1/models"
  "Where OpenRouter lists its models."
  :type 'string
  :group 'iuiw-erpg)

(defface iuiw-erpg-narrator '((t :inherit font-lock-keyword-face :weight bold))
  "Face of the narrator's header."
  :group 'iuiw-erpg)

(defface iuiw-erpg-player '((t :inherit font-lock-function-name-face :weight bold))
  "Face of the player's header."
  :group 'iuiw-erpg)

(defface iuiw-erpg-dim '((t :inherit shadow))
  "Face of intents, director notes and other asides."
  :group 'iuiw-erpg)

(defface iuiw-erpg-refused '((t :inherit warning))
  "Face of the mark on refused or failed replies."
  :group 'iuiw-erpg)

(defvar-local iuiw-erpg--campaign nil "The campaign this buffer plays.")
(defvar-local iuiw-erpg--entries nil "The campaign's log entries.")
(defvar-local iuiw-erpg--pending nil "Entry being written by a model, shown but not yet logged.")
(defvar-local iuiw-erpg--busy nil "Non-nil while a turn is running.")
(defvar-local iuiw-erpg--narrators nil "Narrator models chosen for this buffer, overriding the campaign's.")
(defvar-local iuiw-erpg--show-hidden nil "Whether refused and failed replies are shown.")
(defvar-local iuiw-erpg--input-marker nil "Start of the input after the prompt.")
(defvar-local iuiw-erpg--stream-marker nil "Where streamed text goes.")

(defvar-keymap iuiw-erpg-mode-map
  "RET" #'iuiw-erpg-send
  "C-c C-c" #'iuiw-erpg-send
  "C-c C-r" #'iuiw-erpg-regenerate
  "C-c C-p" #'iuiw-erpg-swipe-previous
  "C-c C-n" #'iuiw-erpg-swipe-next
  "C-c C-g" #'iuiw-erpg-continue
  "C-c C-e" #'iuiw-erpg-edit
  "C-c C-d" #'iuiw-erpg-delete
  "C-c C-t" #'iuiw-erpg-edit-state
  "C-c C-v" #'iuiw-erpg-present
  "C-c C-m" #'iuiw-erpg-narrators
  "C-c C-l" #'iuiw-erpg-set-combo
  "C-c C-k" #'iuiw-erpg-stop
  "C-c C-h" #'iuiw-erpg-toggle-hidden
  "C-c C-s" #'iuiw-erpg-sync)

(define-derived-mode iuiw-erpg-mode text-mode "erpg"
  "Play an erpg campaign.

\\{iuiw-erpg-mode-map}"
  (setq-local iuiw-erpg--input-marker (make-marker))
  (setq-local iuiw-erpg--stream-marker (make-marker))
  (setq-local word-wrap-by-category t)
  (visual-line-mode 1))

;;; Rendering

(defun iuiw-erpg--input ()
  "The text typed after the prompt."
  (if (marker-position iuiw-erpg--input-marker)
      (buffer-substring-no-properties iuiw-erpg--input-marker (point-max))
    ""))

(defun iuiw-erpg--header (entry)
  "Header line of ENTRY."
  (let* ((role (plist-get entry :role))
         (swipes (length (plist-get entry :swipes)))
         (aside (lambda (s) (propertize s 'face 'iuiw-erpg-dim))))
    (concat
     (pcase role
       ("narrator" (propertize "旁白" 'face 'iuiw-erpg-narrator))
       ("director" (funcall aside "导演"))
       ("voice" (funcall aside (format "· %s的意图" (plist-get entry :name))))
       ("record" (funcall aside "· 记录"))
       (_ (propertize (iuiw-erpg-player iuiw-erpg--campaign) 'face 'iuiw-erpg-player)))
     (when-let* ((model (plist-get entry :model)))
       (funcall aside (concat "  " model)))
     (when (> swipes 1)
       (funcall aside (format "  [%d/%d]" (1+ (plist-get entry :index)) swipes)))
     (when (plist-get entry :hidden)
       (propertize "  未采用" 'face 'iuiw-erpg-refused)))))

(defun iuiw-erpg--insert-entry (entry index)
  "Insert ENTRY, the INDEXth of the log or nil while pending."
  (let ((start (point))
        (dim (member (plist-get entry :role) '("voice" "director" "record"))))
    (insert (iuiw-erpg--header entry) "\n")
    (let ((body (point)))
      (insert (iuiw-erpg-entry-text entry))
      (when (or dim (plist-get entry :hidden))
        (add-face-text-property body (point) 'iuiw-erpg-dim))
      (unless index (set-marker iuiw-erpg--stream-marker (point))))
    (insert "\n\n")
    (when index (put-text-property start (point) 'iuiw-erpg-index index))))

(defun iuiw-erpg--shown-p (entry)
  "Non-nil when ENTRY is to be shown."
  (and (or iuiw-erpg--show-hidden (not (plist-get entry :hidden)))
       (or iuiw-erpg-show-voices (not (member (plist-get entry :role) '("voice" "record"))))))

(defun iuiw-erpg--render ()
  "Redraw the story, keeping the input."
  (let* ((input (iuiw-erpg--input))
         (old (point))
         (offset (and (marker-position iuiw-erpg--input-marker)
                      (>= (point) iuiw-erpg--input-marker)
                      (- (point) iuiw-erpg--input-marker)))
         (inhibit-read-only t))
    ;; Stay put while the rest of the story is drawn after the pending entry.
    (set-marker-insertion-type iuiw-erpg--stream-marker nil)
    (erase-buffer)
    (insert (propertize (or (plist-get iuiw-erpg--campaign :title) (plist-get iuiw-erpg--campaign :id))
                        'face 'bold)
            "\n\n")
    (cl-loop for entry in iuiw-erpg--entries for i from 0
             when (iuiw-erpg--shown-p entry) do (iuiw-erpg--insert-entry entry i))
    (when iuiw-erpg--pending
      (iuiw-erpg--insert-entry iuiw-erpg--pending nil))
    (insert (propertize "> " 'face 'minibuffer-prompt))
    (add-text-properties (point-min) (point)
                         '(read-only t front-sticky (read-only) rear-nonsticky t))
    (set-marker iuiw-erpg--input-marker (point))
    (insert input)
    (set-marker-insertion-type iuiw-erpg--stream-marker t)
    (goto-char (if offset (+ iuiw-erpg--input-marker offset) (min old iuiw-erpg--input-marker)))))

(defun iuiw-erpg--stream (text)
  "Show TEXT at the end of the pending entry."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char iuiw-erpg--stream-marker)
      (insert (propertize text 'read-only t 'front-sticky '(read-only) 'rear-nonsticky t)))))

(defun iuiw-erpg--save ()
  "Write the log and redraw."
  (iuiw-erpg-log-write iuiw-erpg--campaign iuiw-erpg--entries)
  (iuiw-erpg--render))

(defun iuiw-erpg--add (entry)
  "Append ENTRY to the log."
  (setq iuiw-erpg--entries (append iuiw-erpg--entries (list entry))))

(defun iuiw-erpg--entry-at-point ()
  "Index of the log entry at point, an error when none."
  (or (get-text-property (point) 'iuiw-erpg-index)
      (user-error "No entry here")))

(defun iuiw-erpg--last-narrator ()
  "Index of the last narrator reply in use, or nil."
  (cl-position-if (lambda (e) (and (equal (plist-get e :role) "narrator")
                                   (not (plist-get e :hidden))))
                  iuiw-erpg--entries :from-end t))

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

(defun iuiw-erpg--record (ctx)
  "Have the recorder update state.md from replies the user has moved on from.
It runs beside the turn; facts land a turn late, while the story they come
from is still in every prompt."
  (let* ((entries iuiw-erpg--entries)
         (narrator-p (lambda (e) (and (equal (plist-get e :role) "narrator") (not (plist-get e :hidden)))))
         (done (or (cl-position-if (lambda (e) (and (funcall narrator-p e) (plist-get e :recorded)))
                                   entries :from-end t)
                   -1))
         (last (cl-position-if narrator-p entries :from-end t))
         (campaign (plist-get ctx :campaign))
         (buffer (current-buffer)))
    (when (and last (> last done))
      (let ((story (iuiw-erpg--story (seq-subseq entries (1+ done) (1+ last))))
            (replies (seq-filter narrator-p (seq-subseq entries (1+ done) (1+ last))))
            (file (iuiw-erpg-state-file campaign)))
        (iuiw-erpg-request-chain
         (iuiw-erpg--recorder-aliases)
         (iuiw-erpg-recorder-system (plist-get ctx :preset))
         (list (iuiw-erpg-recorder-message campaign (plist-get ctx :state) story))
         :buffer buffer
         :callback
         (lambda (text alias)
           (let ((record (iuiw-erpg-parse-record text))
                 (visiting (find-buffer-visiting file)))
             (cond ((not (buffer-live-p buffer)))
                   ((null record) (message "erpg: the recorder gave no usable answer; it tries again next turn"))
                   ((and visiting (buffer-modified-p visiting))
                    (message "erpg: state.md has unsaved edits; the recorder tries again next turn"))
                   (t
                    ;; Reread: the user may have edited state.md since the turn began.
                    (pcase-let ((`(,state . ,changes)
                                 (iuiw-erpg-apply-record campaign (iuiw-erpg-state campaign) record)))
                      (iuiw-erpg-write-state campaign state)
                      (when visiting
                        (with-current-buffer visiting (revert-buffer t t t)))
                      (with-current-buffer buffer
                        (dolist (e replies) (plist-put e :recorded t))
                        (when changes
                          (iuiw-erpg--add (iuiw-erpg-entry "record" (string-join changes "\n")
                                                           :model alias)))
                        (iuiw-erpg--save))))))))))))

(defun iuiw-erpg--context ()
  "The campaign reread from disk, with its preset, state and cards, as a plist."
  (let ((campaign (iuiw-erpg-campaign (plist-get iuiw-erpg--campaign :id))))
    (setq iuiw-erpg--campaign campaign)
    (list :campaign campaign
          :preset (iuiw-erpg-preset (or (plist-get campaign :preset) "default"))
          :state (iuiw-erpg-state campaign)
          :cards (iuiw-erpg-cast campaign))))

(defun iuiw-erpg--finish (&optional message)
  "End the turn, showing MESSAGE when given."
  (setq iuiw-erpg--busy nil iuiw-erpg--pending nil)
  (iuiw-erpg--save)
  (when message (message "%s" message)))

(defun iuiw-erpg--voices (ctx done)
  "Ask each present character with a voice for its intent, then call DONE."
  (let* ((campaign (plist-get ctx :campaign))
         (present (plist-get (plist-get ctx :state) :present))
         (cards (seq-filter (lambda (c)
                              (and (plist-get c :voice)
                                   (member (plist-get c :name) present)
                                   (member (plist-get c :name) (plist-get campaign :cast))
                                   (not (equal (plist-get c :name) (plist-get campaign :player)))))
                            (plist-get ctx :cards)))
         (left (length cards))
         (buffer (current-buffer))
         (entries iuiw-erpg--entries))
    (if (zerop left)
        (funcall done)
      (message "Characters are deciding: %s"
               (mapconcat (lambda (c) (plist-get c :name)) cards "、"))
      (dolist (card cards)
        (let ((name (plist-get card :name)))
          (iuiw-erpg-request-chain
           (iuiw-erpg--voice-aliases card)
           (iuiw-erpg-voice-system campaign (plist-get ctx :preset) (plist-get ctx :state)
                                   card (plist-get ctx :cards))
           (list (iuiw-erpg-voice-message campaign (plist-get ctx :preset) entries card))
           :buffer buffer
           :on-fail (lambda (alias text error)
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (iuiw-erpg--add (iuiw-erpg-entry "voice" (or text error) :name name
                                                           :model alias :hidden t)))))
           :callback (lambda (text alias)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (when (and text iuiw-erpg--busy)
                             (iuiw-erpg--add (iuiw-erpg-entry "voice" (string-trim text)
                                                              :name name :model alias)))
                           (when (and (zerop (cl-decf left)) iuiw-erpg--busy)
                             (iuiw-erpg--render)
                             (funcall done)))))))))))

(defun iuiw-erpg--intents (entries)
  "Intents formed since the last user or director entry in ENTRIES.
They are returned as ((NAME . TEXT) ...)."
  (let ((since (or (cl-position-if (lambda (e) (member (plist-get e :role) '("user" "director")))
                                   entries :from-end t)
                   -1)))
    (cl-loop for e in (nthcdr (1+ since) entries)
             when (and (equal (plist-get e :role) "voice") (not (plist-get e :hidden)))
             collect (cons (plist-get e :name) (iuiw-erpg-entry-text e)))))

(defun iuiw-erpg--narrate (ctx mode &optional target)
  "Have the narrator write, streaming into the buffer.
MODE is `new' for the next reply, `swipe' for another version of entry
TARGET, or `continue' to extend TARGET."
  (let* ((campaign (plist-get ctx :campaign))
         (preset (plist-get ctx :preset))
         (before (if target (seq-take iuiw-erpg--entries (if (eq mode 'continue) (1+ target) target))
                   iuiw-erpg--entries))
         (intents (unless (eq mode 'continue) (iuiw-erpg--intents before)))
         (prefill (alist-get "prefill" preset nil nil #'equal))
         (buffer (current-buffer)))
    (iuiw-erpg-request-chain
     (iuiw-erpg--narrator-aliases)
     (iuiw-erpg-narrator-system campaign preset (plist-get ctx :state) (plist-get ctx :cards))
     (lambda (alias)
       (iuiw-erpg-narrator-messages campaign preset before intents (eq mode 'continue)
                                    (and (plist-get (iuiw-erpg-model alias) :prefill) prefill)))
     :buffer buffer
     :on-start (lambda (alias)
                 (with-current-buffer buffer
                   (setq iuiw-erpg--pending (iuiw-erpg-entry "narrator" "" :model alias))
                   (iuiw-erpg--render)))
     :on-chunk (lambda (text)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (when iuiw-erpg--pending
                       (iuiw-erpg-entry-set-text iuiw-erpg--pending
                                                 (concat (iuiw-erpg-entry-text iuiw-erpg--pending) text))
                       (iuiw-erpg--stream text)))))
     :on-fail (lambda (alias text error)
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (iuiw-erpg--add (iuiw-erpg-entry "narrator" (if (string-blank-p (or text "")) error text)
                                                     :model alias :hidden t))
                    (message "%s %s; trying the next model" alias (if error "failed" "refused")))))
     :callback
     (lambda (text alias)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (cond ((not iuiw-erpg--busy))
                 ((null text)
                  (iuiw-erpg--finish "No model answered; C-c C-h shows what came back"))
                 ((eq mode 'swipe)
                  (iuiw-erpg-entry-add-swipe (nth target iuiw-erpg--entries) (string-trim text))
                  (plist-put (nth target iuiw-erpg--entries) :model alias)
                  (iuiw-erpg--finish))
                 ((eq mode 'continue)
                  (let ((entry (nth target iuiw-erpg--entries)))
                    (iuiw-erpg-entry-set-text entry (concat (iuiw-erpg-entry-text entry) text)))
                  (iuiw-erpg--finish))
                 (t
                  (iuiw-erpg--add (iuiw-erpg-entry "narrator" (string-trim text) :model alias))
                  (iuiw-erpg--finish)))))))))

(defun iuiw-erpg--start ()
  "Mark a turn as running, an error when one already is."
  (when iuiw-erpg--busy
    (user-error "A turn is running; C-c C-k stops it"))
  (setq iuiw-erpg--busy t))

;;; Commands

(defun iuiw-erpg-send ()
  "Send the input and play a turn.
The input is an action, a // director note, or empty to let the story go on."
  (interactive nil iuiw-erpg-mode)
  (if (< (point) iuiw-erpg--input-marker)
      (user-error "Type after the > prompt")
    (let ((text (string-trim (iuiw-erpg--input))))
      (iuiw-erpg--start)
      (condition-case err
          (let ((ctx (iuiw-erpg--context)))
            (let ((inhibit-read-only t)) (delete-region iuiw-erpg--input-marker (point-max)))
            (cond ((string-prefix-p "//" text)
                   (iuiw-erpg--add (iuiw-erpg-entry "director" (string-trim (substring text 2)))))
                  ((not (string-empty-p text))
                   (iuiw-erpg--add (iuiw-erpg-entry "user" text))))
            (iuiw-erpg--save)
            (iuiw-erpg--record ctx)
            (let ((buffer (current-buffer)))
              (iuiw-erpg--voices ctx (lambda ()
                                       (with-current-buffer buffer
                                         (iuiw-erpg--narrate ctx 'new))))))
        (error (setq iuiw-erpg--busy nil)
               (signal (car err) (cdr err)))))))

(defun iuiw-erpg-regenerate ()
  "Write another version of the narrator's last reply.
Earlier versions stay as swipes."
  (interactive nil iuiw-erpg-mode)
  (let ((target (or (iuiw-erpg--last-narrator) (user-error "No reply to regenerate"))))
    (iuiw-erpg--start)
    (condition-case err
        (iuiw-erpg--narrate (iuiw-erpg--context) 'swipe target)
      (error (setq iuiw-erpg--busy nil)
             (signal (car err) (cdr err))))))

(defun iuiw-erpg-continue ()
  "Have the narrator carry on writing its last reply."
  (interactive nil iuiw-erpg-mode)
  (let ((target (or (iuiw-erpg--last-narrator) (user-error "No reply to continue"))))
    (iuiw-erpg--start)
    (condition-case err
        (iuiw-erpg--narrate (iuiw-erpg--context) 'continue target)
      (error (setq iuiw-erpg--busy nil)
             (signal (car err) (cdr err))))))

(defun iuiw-erpg--swipe (step)
  "Show the swipe STEP away in the entry at point, else the last reply."
  (let* ((index (or (get-text-property (point) 'iuiw-erpg-index) (iuiw-erpg--last-narrator)
                    (user-error "No reply")))
         (entry (nth index iuiw-erpg--entries))
         (count (length (plist-get entry :swipes))))
    (when (< count 2) (user-error "Only one version; C-c C-r writes another"))
    (plist-put entry :index (mod (+ (plist-get entry :index) step) count))
    (iuiw-erpg--save)))

(defun iuiw-erpg-swipe-previous ()
  "Show the previous version of a reply."
  (interactive nil iuiw-erpg-mode)
  (iuiw-erpg--swipe -1))

(defun iuiw-erpg-swipe-next ()
  "Show the next version of a reply."
  (interactive nil iuiw-erpg-mode)
  (iuiw-erpg--swipe 1))

(defun iuiw-erpg-edit ()
  "Edit the entry at point; the edit is what the models see from then on."
  (interactive nil iuiw-erpg-mode)
  (let* ((index (iuiw-erpg--entry-at-point))
         (buffer (current-buffer)))
    (string-edit "Edit, then C-c C-c" (iuiw-erpg-entry-text (nth index iuiw-erpg--entries))
                 (lambda (text)
                   (with-current-buffer buffer
                     (iuiw-erpg-entry-set-text (nth index iuiw-erpg--entries) text)
                     (iuiw-erpg--save))))))

(defun iuiw-erpg-delete ()
  "Delete the entry at point from the log."
  (interactive nil iuiw-erpg-mode)
  (let ((index (iuiw-erpg--entry-at-point)))
    (when (y-or-n-p "Delete this entry? ")
      (setq iuiw-erpg--entries (append (seq-take iuiw-erpg--entries index)
                                       (nthcdr (1+ index) iuiw-erpg--entries)))
      (iuiw-erpg--save))))

(defun iuiw-erpg-present (names)
  "Set who of the cast is present to NAMES."
  (interactive
   (let ((campaign (iuiw-erpg-campaign (plist-get iuiw-erpg--campaign :id))))
     (list (completing-read-multiple
            "Present: " (plist-get campaign :cast) nil t
            (string-join (plist-get (iuiw-erpg-state campaign) :present) ","))))
   iuiw-erpg-mode)
  (iuiw-erpg-set-present iuiw-erpg--campaign names)
  (message "Present: %s" (string-join names "、")))

(defun iuiw-erpg-edit-state ()
  "Open the campaign's state.md, which every model reads each turn."
  (interactive nil iuiw-erpg-mode)
  (find-file-other-window (expand-file-name "state.md" (plist-get iuiw-erpg--campaign :dir))))

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
  (let ((file (expand-file-name "campaign.md" (plist-get iuiw-erpg--campaign :dir))))
    (iuiw-erpg-with-file file
      (insert-file-contents file)
      (goto-char (point-min))
      (if (re-search-forward "^combo:.*$" nil t)
          (replace-match (concat "combo: " name) t t)
        (forward-line 1)
        (insert "combo: " name "\n")))
    (setq iuiw-erpg--campaign (iuiw-erpg-campaign (plist-get iuiw-erpg--campaign :id)))
    (message "Combo %s; narrators: %s" name (string-join (iuiw-erpg--narrator-aliases) " → "))))

(defun iuiw-erpg-stop ()
  "Stop the running turn."
  (interactive nil iuiw-erpg-mode)
  (setq iuiw-erpg--busy nil)
  (iuiw-erpg-abort (current-buffer))
  (iuiw-erpg--finish "Stopped"))

(defun iuiw-erpg-toggle-hidden ()
  "Show or hide refused and failed replies."
  (interactive nil iuiw-erpg-mode)
  (setq iuiw-erpg--show-hidden (not iuiw-erpg--show-hidden))
  (iuiw-erpg--render))

;;;###autoload
(defun iuiw-erpg-open (id)
  "Play campaign ID."
  (interactive (list (completing-read "Campaign: " (iuiw-erpg-campaign-ids) nil t)))
  (let* ((campaign (iuiw-erpg-campaign id))
         (buffer (get-buffer-create (format "*erpg %s*" id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'iuiw-erpg-mode)
        (iuiw-erpg-mode)
        (setq iuiw-erpg--campaign campaign
              iuiw-erpg--entries (iuiw-erpg-log-read campaign))
        (iuiw-erpg--render)))
    (pop-to-buffer-same-window buffer)
    (goto-char (point-max))))

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
              "recorder:          # 自动维护 state.md 的模型；空则用 combo 的\n"
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
