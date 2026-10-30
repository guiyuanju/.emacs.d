;;; iuiw-erpg-llm.el --- erpg prompts and OpenRouter calls -*- lexical-binding: t; -*-

;;; Commentary:
;; 混合模式：在场且 voice 为真的角色各自只看到自己的卡片和最近的剧情，先写出意图；
;; 叙事者再拿着这些意图用一个声音写正文。
;; 请求经 gptel 发给 OpenRouter；回复被判为拒绝或出错时换 fallback 链上的下一个模型。
;; 成人内容只限成年角色：未满 18 岁的角色名单总会写进规则，不能关掉。

;;; Code:

(require 'iuiw-erpg-store)

(require 'gptel)
(require 'gptel-openai)

(defcustom iuiw-erpg-provider '(:data_collection "deny")
  "OpenRouter provider preferences, unless a model in models.eld sets :provider."
  :type 'plist
  :group 'iuiw-erpg)

(defcustom iuiw-erpg-history-chars 30000
  "Most characters of past story sent to the narrator."
  :type 'natnum
  :group 'iuiw-erpg)

(defcustom iuiw-erpg-voice-history 8
  "How many recent log entries a character sees when forming its intent."
  :type 'natnum
  :group 'iuiw-erpg)

(defcustom iuiw-erpg-refusal-regexp
  (rx (or "我不能" "我无法" "无法继续" "无法协助" "无法提供" "不能继续" "很抱歉" "抱歉，"
          "作为AI" "作为一个AI" "作为人工智能" "AI助手"
          "I can't" "I cannot" "I won't" "I'm sorry" "I am sorry" "I'm not able"
          "I am unable" "I'm unable" "As an AI"))
  "Matches the opening of a reply that refuses or steps out of the story."
  :type 'regexp
  :group 'iuiw-erpg)

(defcustom iuiw-erpg-refusal-head 160
  "How many leading characters of a reply are checked for a refusal."
  :type 'natnum
  :group 'iuiw-erpg)

(defcustom iuiw-erpg-refusal-max-length 800
  "Replies longer than this are never taken for refusals."
  :type 'natnum
  :group 'iuiw-erpg)

;;; Requests

(defvar iuiw-erpg--backend nil
  "The gptel OpenRouter backend, made on first use.")

(defun iuiw-erpg-key ()
  "The OpenRouter API key from auth-source or OPENROUTER_API_KEY, or nil."
  (or (ignore-errors (gptel-api-key-from-auth-source "openrouter.ai"))
      (getenv "OPENROUTER_API_KEY")))

(defun iuiw-erpg--key ()
  "The OpenRouter API key, an error when missing."
  (or (iuiw-erpg-key)
      (user-error "No OpenRouter key: add `machine openrouter.ai login apikey password KEY' to authinfo")))

(defun iuiw-erpg--backend ()
  "The gptel backend for OpenRouter."
  (or iuiw-erpg--backend
      (setq iuiw-erpg--backend
            (gptel-make-openai "erpg"
              :host "openrouter.ai" :endpoint "/api/v1/chat/completions"
              :stream t :key #'iuiw-erpg--key :models nil))))

(defun iuiw-erpg-refusal-p (text)
  "Non-nil when TEXT is empty or opens with a refusal."
  (or (string-blank-p text)
      (and (<= (length text) iuiw-erpg-refusal-max-length)
           (string-match-p iuiw-erpg-refusal-regexp
                           (substring text 0 (min (length text) iuiw-erpg-refusal-head))))))

(cl-defun iuiw-erpg-request (alias system messages &key buffer on-chunk callback)
  "Send MESSAGES with SYSTEM to model ALIAS.
MESSAGES alternate user and assistant, starting with the user.  With
ON-CHUNK, stream and call it with each piece of text.  Call CALLBACK with
\(TEXT ERROR) when done; BUFFER owns the request for `gptel-abort'."
  (let* ((model (iuiw-erpg-model alias))
         (gptel-backend (iuiw-erpg--backend))
         (gptel-model (intern (plist-get model :id)))
         (gptel-stream t)
         (gptel-use-tools nil)
         (gptel-use-context nil)
         (gptel-include-reasoning nil)
         (gptel--request-params (append (plist-get model :params)
                                        (list :provider (or (plist-get model :provider)
                                                            iuiw-erpg-provider))))
         (parts nil))
    ;; gptel replaces a model its backend does not list.
    (cl-pushnew gptel-model (gptel-backend-models gptel-backend))
    (gptel-request messages
      :system system :buffer (or buffer (current-buffer)) :stream (and on-chunk t)
      :callback
      (lambda (response info)
        (cond ((stringp response)
               (if on-chunk
                   (progn (push response parts) (funcall on-chunk response))
                 (funcall callback response nil)))
              ((eq response t)
               (funcall callback (apply #'concat (nreverse parts)) nil))
              ((eq response 'abort)
               (funcall callback nil "aborted"))
              ((null response)
               (funcall callback nil (or (plist-get info :status) "no response"))))))))

(cl-defun iuiw-erpg-request-chain (aliases system messages &key buffer on-start on-chunk on-fail callback)
  "Try model ALIASES in order until one answers without refusing.
MESSAGES may be a function of the alias returning them.  ON-START is
called with each alias tried; ON-FAIL with (ALIAS TEXT ERROR) when one
refuses or fails.  CALLBACK gets (TEXT ALIAS), or (nil nil) when every
model failed or the request was aborted.  BUFFER and ON-CHUNK are as in
`iuiw-erpg-request'."
  (if (null aliases)
      (funcall callback nil nil)
    (let ((alias (car aliases)))
      (when on-start (funcall on-start alias))
      (iuiw-erpg-request
       alias system (if (functionp messages) (funcall messages alias) messages)
       :buffer buffer :on-chunk on-chunk
       :callback
       (lambda (text error)
         (cond ((equal error "aborted") (funcall callback nil nil))
               ((or error (iuiw-erpg-refusal-p text))
                (when on-fail (funcall on-fail alias text error))
                (iuiw-erpg-request-chain (cdr aliases) system messages
                                         :buffer buffer :on-start on-start :on-chunk on-chunk
                                         :on-fail on-fail :callback callback))
               (t (funcall callback text alias))))))))

(defun iuiw-erpg-abort (buffer)
  "Stop every request BUFFER owns."
  (dotimes (_ 20) (gptel-abort buffer)))

;;; Prompts

(defun iuiw-erpg-player (campaign)
  "Name of the player's character in CAMPAIGN."
  (or (plist-get campaign :player) "你"))

(defun iuiw-erpg-cast (campaign)
  "Cards of CAMPAIGN's cast and its player's card."
  (mapcar #'iuiw-erpg-card
          (delete-dups (append (plist-get campaign :cast)
                               (and (plist-get campaign :player)
                                    (list (plist-get campaign :player)))))))

(defun iuiw-erpg--age-rules (cards)
  "Rules on sexual content for CARDS."
  (let ((minors (mapcar (lambda (c) (plist-get c :name)) (seq-filter #'iuiw-erpg-minor-p cards))))
    (concat "- 性内容只发生在成年人之间。"
            (when minors
              (format "\n- %s未满 18 岁：任何情况下都不写与其有关的性内容或性暗示。"
                      (string-join minors "、"))))))

(defun iuiw-erpg--card-text (card)
  "CARD as a prompt section."
  (format "## %s（%d 岁）\n%s" (plist-get card :name) (plist-get card :age) (plist-get card :body)))

(defun iuiw-erpg--state-text (state)
  "STATE as a prompt section."
  (concat "# 当前状态\n在场：" (string-join (plist-get state :present) "、")
          (unless (string-empty-p (plist-get state :body))
            (concat "\n" (plist-get state :body)))
          (when (plist-get state :facts)
            (concat "\n已经发生、仍然成立的事：\n"
                    (mapconcat (lambda (f) (concat "- " f)) (plist-get state :facts) "\n")))))

(defun iuiw-erpg--join (&rest parts)
  "PARTS that are non-empty, separated by blank lines."
  (string-join (seq-remove (lambda (p) (or (null p) (string-empty-p p))) parts) "\n\n"))

(defun iuiw-erpg-narrator-system (campaign preset state cards)
  "The narrator's system prompt for CAMPAIGN with PRESET, STATE and CARDS."
  (let ((player (iuiw-erpg-player campaign))
        (player-card (seq-find (lambda (c) (equal (plist-get c :name) (plist-get campaign :player)))
                               cards)))
    (iuiw-erpg--join
     (alist-get "system" preset nil nil #'equal)
     (concat "# 规则\n"
             (format "- 你是这场互动小说的叙事者：写旁白，以及除%s以外所有角色的言行。\n" player)
             (format "- 不替%s说话、行动或做决定，写到需要%s回应时停下。\n" player player)
             "- 消息里的【角色意图】是在场角色此刻想做的事，要体现在正文里，怎么写由你决定；不要照抄，也不要提到它。\n"
             "- 【导演指令】是用户对剧情的要求，照做，不要回应它本身。\n"
             (format "- 用中文写，每次 %s 字。\n" (or (plist-get campaign :length) "200-400"))
             (when-let* ((intensity (plist-get campaign :intensity)))
               (format "- 尺度：%s\n" intensity))
             (iuiw-erpg--age-rules cards))
     (concat "# 世界与开场\n" (plist-get campaign :body))
     (if player-card
         (concat "# 玩家角色\n" (iuiw-erpg--card-text player-card))
       "# 玩家角色\n玩家就是「你」，用第二人称写。")
     (concat "# 角色\n"
             (mapconcat #'iuiw-erpg--card-text
                        (seq-remove (lambda (c) (eq c player-card)) cards) "\n\n"))
     (iuiw-erpg--state-text state))))

(defun iuiw-erpg--story (entries)
  "ENTRIES that belong in the story: shown, and from the user or the narrator.
A director's note only counts until the narrator next speaks."
  (let* ((shown (seq-filter (lambda (e) (and (not (plist-get e :hidden))
                                             (member (plist-get e :role)
                                                     '("user" "director" "narrator"))))
                            entries))
         (last-narrator (cl-position "narrator" shown
                                     :key (lambda (e) (plist-get e :role)) :test #'equal :from-end t)))
    (cl-loop for e in shown for i from 0
             unless (and (equal (plist-get e :role) "director")
                         last-narrator (< i last-narrator))
             collect e)))

(defun iuiw-erpg--entry-message (entry)
  "ENTRY as (ROLE . TEXT) for the narrator, ROLE being user or assistant."
  (let ((text (iuiw-erpg-entry-text entry)))
    (pcase (plist-get entry :role)
      ("narrator" (cons 'assistant text))
      ("director" (cons 'user (concat "【导演指令】" text)))
      (_ (cons 'user text)))))

(defun iuiw-erpg--alternate (messages)
  "MESSAGES, a list of (ROLE . TEXT), merged into alternating texts from the user."
  (let (out)
    (dolist (m messages)
      (if (and out (eq (car (car out)) (car m)))
          (setcdr (car out) (concat (cdr (car out)) "\n\n" (cdr m)))
        (push (cons (car m) (cdr m)) out)))
    (setq out (nreverse out))
    (when (or (null out) (eq (car (car out)) 'assistant))
      (push (cons 'user "（开始）") out))
    out))

(defun iuiw-erpg--trim (messages limit)
  "The latest MESSAGES whose texts add up to at most LIMIT characters.
The last message is always kept."
  (let ((total 0) kept)
    (cl-loop for m in (reverse messages)
             do (cl-incf total (length (cdr m)))
             while (or (null kept) (<= total limit))
             do (push m kept))
    kept))

(defun iuiw-erpg--append (message text)
  "MESSAGE with TEXT added after a blank line."
  (cons (car message) (concat (cdr message) "\n\n" text)))

(defun iuiw-erpg-narrator-messages (campaign preset entries intents &optional continue prefill)
  "Texts for the narrator from the story in ENTRIES, CAMPAIGN and PRESET.
INTENTS, ((NAME . TEXT) ...), go with the last user message.  With
CONTINUE the story ends with the narrator's reply to extend; else with
PREFILL the reply opens with the preset's prefill."
  (let* ((messages (iuiw-erpg--trim (mapcar #'iuiw-erpg--entry-message (iuiw-erpg--story entries))
                                    iuiw-erpg-history-chars))
         (messages (iuiw-erpg--alternate messages))
         (last-user (cl-position 'user messages :key #'car :from-end t))
         (depth-note (alist-get "depth" preset nil nil #'equal))
         (post (alist-get "post-history" preset nil nil #'equal)))
    (when depth-note
      (let ((i (cl-position 'user messages :key #'car :from-end t
                            :end (max 1 (- (length messages) (plist-get campaign :depth))))))
        (setf (nth (or i 0) messages) (iuiw-erpg--append (nth (or i 0) messages) depth-note))))
    (when intents
      (setf (nth last-user messages)
            (iuiw-erpg--append (nth last-user messages)
                               (concat "【角色意图】\n"
                                       (mapconcat (lambda (i) (format "%s：%s" (car i) (cdr i)))
                                                  intents "\n")))))
    (when post
      (setf (nth last-user messages) (iuiw-erpg--append (nth last-user messages) post)))
    (when (and continue (not (eq (car (car (last messages))) 'assistant)))
      (user-error "Nothing to continue"))
    (when (and (not continue) (eq (car (car (last messages))) 'assistant))
      (setq messages (append messages (list (cons 'user "（继续）")))))
    (when (and prefill (not continue))
      (setq messages (append messages (list (cons 'assistant prefill)))))
    (mapcar #'cdr messages)))

(defun iuiw-erpg-voice-system (campaign preset state card cards)
  "System prompt for CARD forming its intent in CAMPAIGN."
  (let ((name (plist-get card :name)))
    (iuiw-erpg--join
     (alist-get "system" preset nil nil #'equal)
     (concat "# 规则\n"
             (format "- 你只扮演%s。根据最近的剧情，写出%s此刻的意图，交给叙事者写成正文。\n" name name)
             "- 只输出三行：「行动：」「台词：」「心思：」，每行不超过 60 字；没有就写「无」。\n"
             (format "- %s只知道自己亲眼所见、亲耳所闻和下面卡片里的事。\n" name)
             (format "- 照%s的性格和欲望行事，可以拒绝、隐瞒、主动或算计，不必迎合任何人。\n" name)
             (iuiw-erpg--age-rules cards))
     (concat "# 世界\n" (plist-get campaign :body))
     (concat "# 你的角色\n" (iuiw-erpg--card-text card))
     (iuiw-erpg--state-text state))))

(defun iuiw-erpg-voice-message (campaign preset entries card)
  "The one message asking CARD for its intent, from the story in ENTRIES."
  (let* ((story (last (iuiw-erpg--story entries) iuiw-erpg-voice-history))
         (player (iuiw-erpg-player campaign))
         (lines (mapcar (lambda (e)
                          (format "%s：%s"
                                  (pcase (plist-get e :role)
                                    ("narrator" "旁白")
                                    ("director" "导演")
                                    (_ player))
                                  (iuiw-erpg-entry-text e)))
                        story)))
    (iuiw-erpg--join
     (concat "最近的剧情：\n" (if lines (string-join lines "\n\n") "（刚开场）"))
     (format "写出%s此刻的意图。" (plist-get card :name))
     (alist-get "post-history" preset nil nil #'equal))))

(defcustom iuiw-erpg-facts-chars 1500
  "Recorded facts longer than this many characters in all get condensed."
  :type 'natnum
  :group 'iuiw-erpg)

(defun iuiw-erpg-recorder-system (preset)
  "System prompt of the recorder, which keeps state.md's facts, with PRESET."
  (iuiw-erpg--join
   (alist-get "system" preset nil nil #'equal)
   (concat "# 规则\n"
           "- 你是这场互动小说的记录员，不写剧情。读新发生的剧情，维护一份事实清单，供角色以后回忆。\n"
           "- 只记以后还用得上的事：关系和态度的变化、承诺和交易、暴露的秘密、得到或失去的东西、伤势、去过的地方、做出的决定。\n"
           "- 不记一时的动作、对白原文和气氛描写；已有清单里有的不重复记。\n"
           "- 每条一句，不超过 40 字，写明是谁；玩家写作「你」。\n"
           "- 只输出一个 JSON 对象，不要别的文字。")))

(defun iuiw-erpg-recorder-message (campaign state entries)
  "Ask the recorder to update STATE of CAMPAIGN from the story in ENTRIES."
  (let* ((player (iuiw-erpg-player campaign))
         (facts (plist-get state :facts))
         (condense (> (apply #'+ (mapcar #'length facts)) iuiw-erpg-facts-chars)))
    (iuiw-erpg--join
     (concat "已有清单：\n"
             (if facts
                 (string-join (cl-loop for f in facts for i from 1 collect (format "%d. %s" i f)) "\n")
               "（空）"))
     (format "角色：%s\n现在在场：%s"
             (string-join (plist-get campaign :cast) "、")
             (string-join (plist-get state :present) "、"))
     (concat "新发生的剧情：\n"
             (mapconcat (lambda (e)
                          (format "%s：%s" (if (equal (plist-get e :role) "narrator") "旁白" player)
                                  (iuiw-erpg-entry-text e)))
                        entries "\n\n"))
     (if condense
         (format "清单太长了。输出 {\"present\": [此刻在场的角色], \"facts\": [合并精简后的完整清单]}，清单总长不超过 %d 字，去掉不再重要的。"
                 (/ iuiw-erpg-facts-chars 2))
       "输出 {\"present\": [此刻在场的角色], \"add\": [新增的条目], \"remove\": [不再成立的已有条目的编号]}；没有就给空数组。"))))

(defun iuiw-erpg-parse-record (text)
  "The JSON object in the recorder's TEXT as a plist, or nil."
  (when (and text (string-match "{\\(?:.\\|\n\\)*}" text))
    (let ((value (ignore-errors
                   (json-parse-string (match-string 0 text) :object-type 'plist
                                      :array-type 'list :null-object nil :false-object nil))))
      (and (plistp value) (cl-evenp (length value)) value))))

(defun iuiw-erpg-apply-record (campaign state record)
  "STATE of CAMPAIGN with RECORD applied, and what changed.
Returns (NEW-STATE . CHANGES), CHANGES being lines to show."
  (let* ((cast (plist-get campaign :cast))
         (old (plist-get state :facts))
         (strings (lambda (list) (seq-filter (lambda (x) (and (stringp x) (not (string-blank-p x)))) list)))
         (present (if (plist-member record :present)
                      (seq-filter (lambda (n) (member n cast)) (funcall strings (plist-get record :present)))
                    (plist-get state :present)))
         (facts (if (plist-member record :facts)
                    (funcall strings (plist-get record :facts))
                  (let ((gone (seq-filter #'integerp (plist-get record :remove))))
                    (append (cl-loop for f in old for i from 1 unless (memq i gone) collect f)
                            (funcall strings (plist-get record :add))))))
         changes)
    (unless (equal present (plist-get state :present))
      (push (concat "在场：" (if present (string-join present "、") "无")) changes))
    (if (plist-member record :facts)
        (push (format "清单精简为 %d 条" (length facts)) changes)
      (dolist (f (seq-difference old facts)) (push (concat "- " f) changes))
      (dolist (f (seq-difference facts old)) (push (concat "+ " f) changes)))
    (cons (list :present present :body (plist-get state :body) :facts facts)
          (nreverse changes))))

(provide 'iuiw-erpg-llm)
;;; iuiw-erpg-llm.el ends here
