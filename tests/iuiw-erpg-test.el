;;; iuiw-erpg-test.el --- erpg checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'iuiw-erpg)

(defmacro iuiw-erpg-test--with-repo (&rest body)
  "Run BODY with `iuiw-erpg-directory' set to a fresh repository."
  (declare (indent 0))
  `(let* ((iuiw-erpg-directory (file-name-as-directory (make-temp-file "erpg" t))))
     (unwind-protect
         (progn
           (dolist (dir '("presets" "cards" "campaigns/c"))
             (make-directory (iuiw-erpg-file dir) t))
           (iuiw-erpg-test--write "models.eld" "((a :id \"x/a\") (b :id \"x/b\" :prefill t))")
           (iuiw-erpg-test--write "presets/default.md"
                                  "说明\n\n## system\nSYS\n\n## depth\nDEPTH\n\n## post-history\nPOST\n\n## prefill\nPRE\n")
           (iuiw-erpg-test--write "cards/甲.md" "---\nage: 30\n---\n甲的设定")
           (iuiw-erpg-test--write "cards/乙.md" "---\nage: 16\nvoice: false\n---\n乙的设定")
           (iuiw-erpg-test--write "campaigns/c/campaign.md"
                                  "---\ntitle: T\ncast: 甲, 乙\nnarrator: a, b\ndepth: 2\n---\n世界")
           ,@body)
       (delete-directory iuiw-erpg-directory t))))

(defun iuiw-erpg-test--write (path text)
  "Write TEXT to PATH in the test repository."
  (iuiw-erpg-with-file (iuiw-erpg-file path) (insert text)))

(ert-deftest iuiw-erpg-parse-front-matter ()
  (let ((parsed (iuiw-erpg-parse "---\ncast: 甲，乙 # comment\nempty:\n---\nbody\n")))
    (should (equal (iuiw-erpg-split (plist-get parsed :cast)) '("甲" "乙")))
    (should-not (plist-member parsed :empty))
    (should (equal (plist-get parsed :body) "body"))))

(ert-deftest iuiw-erpg-preset-sections ()
  (iuiw-erpg-test--with-repo
    (iuiw-erpg-test--write "presets/p.md" "head\n## system\nS\n## depth\n\n## prefill\nP\n")
    (should (equal (iuiw-erpg-preset "p") '(("system" . "S") ("prefill" . "P"))))))

(ert-deftest iuiw-erpg-story-parses-and-replays ()
  (with-temp-buffer
    (insert "### 你\n\n我进门\n\n<!-- 意图 甲\n行动：起身\n-->\n<!-- 随手记的 -->\n\n"
            "### 旁白\n\n门开了\n\n<!-- 记录\n在场：甲\n+ 一\n+ 二\n-->\n\n"
            "### 导演\n天黑了\n<!-- 记录\n- 一\n-->\n<!-- 在场：无 -->\n\n### 你\n")
    (let ((entries (iuiw-erpg-story-entries)))
      (should (equal (mapcar (lambda (e) (plist-get e :role)) entries)
                     '("user" "voice" "narrator" "record" "director" "record" "present" "user")))
      (should (equal (mapcar #'iuiw-erpg-entry-text entries)
                     '("我进门" "行动：起身" "门开了" "在场：甲\n+ 一\n+ 二" "天黑了" "- 一" "在场：无" "")))
      (should (equal (plist-get (nth 1 entries) :name) "甲"))
      (should (equal (buffer-substring (plist-get (nth 2 entries) :start) (plist-get (nth 2 entries) :body))
                     "### 旁白\n"))
      (should (equal (iuiw-erpg-replay '(:present ("甲" "乙") :body "B" :facts ("零")) entries)
                     '(:present nil :body "B" :facts ("零" "二"))))
      (should (equal (plist-get (iuiw-erpg-replay nil (append entries (list (iuiw-erpg-entry "record" "= 合并"))))
                                :facts)
                     '("合并")))
      ;; 空的段落不发给模型。
      (should (equal (mapcar #'iuiw-erpg-entry-text (iuiw-erpg--story entries)) '("我进门" "门开了" "天黑了"))))))
(ert-deftest iuiw-erpg-narrator-messages-slots ()
  (iuiw-erpg-test--with-repo
    (let* ((campaign (iuiw-erpg-campaign "c"))
           (preset (iuiw-erpg-preset "default"))
           (entries (list (iuiw-erpg-entry "narrator" "开场")
                          (iuiw-erpg-entry "user" "u1")
                          (iuiw-erpg-entry "narrator" "n1")
                          (iuiw-erpg-entry "director" "旧指令")
                          (iuiw-erpg-entry "narrator" "n2")
                          (iuiw-erpg-entry "user" "u2")
                          (iuiw-erpg-entry "voice" "VOICE" :name "甲")))
           (state '(:present ("甲") :body "" :facts ("事")))
           (messages (iuiw-erpg-narrator-messages campaign preset state entries '(("甲" . "想走")) nil "PRE")))
      ;; 开场前补一条用户消息；意图和已经过去的导演指令都不发。
      (should (equal (car messages) "（开始）"))
      (should (equal (nth 1 messages) "开场"))
      (should-not (cl-some (lambda (m) (string-match-p "旧指令\\|VOICE" m)) messages))
      ;; 每轮变的东西都在最后一条用户消息里。
      (should (string-match-p "\\`【当前状态】\n在场：甲\n已经发生、仍然成立的事：\n- 事\n\nu2\n\n【角色意图】\n甲：想走\n\nPOST\\'"
                              (nth 4 messages)))
      ;; depth 2：落在倒数第 2 条之前最近的用户消息上。
      (should (string-match-p "u1\n\nDEPTH" (nth 2 messages)))
      (should (equal (car (last messages)) "PRE"))
      (should (= (length messages) 6)))))

(ert-deftest iuiw-erpg-continue-ends-with-the-reply ()
  (iuiw-erpg-test--with-repo
    (let* ((campaign (iuiw-erpg-campaign "c"))
           (entries (list (iuiw-erpg-entry "user" "u") (iuiw-erpg-entry "narrator" "n")))
           (state '(:present nil :body "" :facts nil))
           (messages (iuiw-erpg-narrator-messages campaign nil state entries nil t "PRE")))
      (should (equal messages '("【当前状态】\n在场：\n\nu" "n")))
      (should-error (iuiw-erpg-narrator-messages campaign nil state (list (car entries)) nil t)
                    :type 'user-error)
      ;; 没有新输入时，意图跟着补上的「（继续）」，不挂在上一段旁白之前。
      (let ((messages (iuiw-erpg-narrator-messages campaign nil state entries '(("甲" . "想走")))))
        (should (equal (car messages) "u"))
        (should (equal (car (last messages)) "【当前状态】\n在场：\n\n（继续）\n\n【角色意图】\n甲：想走"))))))

(ert-deftest iuiw-erpg-trim-keeps-the-start-for-caching ()
  (let ((iuiw-erpg-history-step 2)
        (messages (mapcar (lambda (i) (cons 'user (make-string 10 (+ ?a i)))) (number-sequence 0 6))))
    (should (equal (iuiw-erpg--trim messages 100) messages))
    ;; 超出时按步长成段地丢，开头在几轮里保持不变。
    (should (equal (iuiw-erpg--trim messages 50) (nthcdr 2 messages)))
    (should (equal (iuiw-erpg--trim (butlast messages) 50) (nthcdr 2 (butlast messages))))
    (should (equal (iuiw-erpg--trim messages 5) (last messages)))))

(ert-deftest iuiw-erpg-model-provider-overrides-default ()
  (let (params)
    (cl-letf (((symbol-function 'iuiw-erpg-model)
               (lambda (alias) (if (equal alias "free")
                                   '(:id "x/free" :provider (:data_collection "allow"))
                                 '(:id "x/paid"))))
              ((symbol-function 'gptel-request)
               (lambda (&rest _) (push gptel--request-params params))))
      (iuiw-erpg-request "free" "s" '("u") :callback #'ignore)
      (iuiw-erpg-request "paid" "s" '("u") :callback #'ignore))
    (should (equal (plist-get (nth 1 params) :provider) '(:data_collection "allow")))
    (should (equal (plist-get (nth 0 params) :provider) '(:data_collection "deny")))))

(ert-deftest iuiw-erpg-combo-fills-unset-roles ()
  (iuiw-erpg-test--with-repo
    (iuiw-erpg-test--write "combos.eld" "((cheap :narrator (\"b\") :voice (\"a\") :recorder (\"b\" \"a\")))")
    (iuiw-erpg-test--write "campaigns/c/campaign.md" "---\ntitle: T\ncast: 甲\ncombo: cheap\nvoice: b\n---\n世界")
    (with-temp-buffer
      (setq iuiw-erpg--campaign (iuiw-erpg-campaign "c"))
      (should (equal (iuiw-erpg--narrator-aliases) '("b")))
      (should (equal (iuiw-erpg--voice-aliases '(:model nil)) '("b")))
      (should (equal (iuiw-erpg--voice-aliases '(:model "a")) '("a")))
      (should (equal (iuiw-erpg--recorder-aliases) '("b" "a")))
      (setq iuiw-erpg--narrators '("a"))
      (should (equal (iuiw-erpg--narrator-aliases) '("a"))))
    (with-temp-buffer
      (setq iuiw-erpg--campaign (list :combo "nope"))
      (should-error (iuiw-erpg--narrator-aliases) :type 'user-error))))

(ert-deftest iuiw-erpg-refusals ()
  (should (iuiw-erpg-refusal-p "  "))
  (should (iuiw-erpg-refusal-p "抱歉，我无法继续这个故事。"))
  (should (iuiw-erpg-refusal-p "I'm sorry, but I can't continue."))
  (should-not (iuiw-erpg-refusal-p "她笑了笑，推开门。"))
  (should-not (iuiw-erpg-refusal-p (concat (make-string 900 ?字) "我无法"))))

(ert-deftest iuiw-erpg-chain-falls-back ()
  (let (tried failed result)
    (cl-letf (((symbol-function 'iuiw-erpg-request)
               (cl-function (lambda (alias _system messages &key callback &allow-other-keys)
                              (push (cons alias messages) tried)
                              (pcase alias
                                ("a" (funcall callback "抱歉，我不能写这个。" nil))
                                ("b" (funcall callback nil "HTTP 500"))
                                (_ (funcall callback "正文" nil)))))))
      (iuiw-erpg-request-chain '("a" "b" "c") "sys" (lambda (alias) (list alias))
                               :on-fail (lambda (alias text error) (push (list alias text error) failed))
                               :callback (lambda (text alias) (setq result (cons text alias)))))
    (should (equal result '("正文" . "c")))
    (should (equal (mapcar #'car failed) '("b" "a")))
    (should (equal (cdr (assoc "c" tried)) '("c")))))

(defmacro iuiw-erpg-test--with-models (&rest body)
  "Run BODY with the models answering without the network."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'iuiw-erpg-request)
              (cl-function
               (lambda (_alias system messages &key on-chunk callback &allow-other-keys)
                 (push (list system messages) calls)
                 (cond ((string-match-p "记录员" system)
                        (funcall callback "{\"present\": [\"甲\"], \"add\": [\"你进了门\"], \"remove\": []}" nil))
                       ((string-match-p "你只扮演甲" system)
                        (funcall callback "行动：起身" nil))
                       (on-chunk
                        (funcall on-chunk "\n门")
                        (funcall on-chunk "开了")
                        (funcall callback "\n门开了" nil)))))))
     ,@body))

(ert-deftest iuiw-erpg-turn-runs-voices-then-narrator ()
  (iuiw-erpg-test--with-repo
    (let (calls)
      (iuiw-erpg-test--with-models
        (iuiw-erpg-open "c")
        (unwind-protect
            (let ((turn "### 你\n\n我进门\n\n<!-- 意图 甲\n行动：起身\n-->\n\n### 旁白\n\n门开了"))
              (should (equal (buffer-string) "### 你\n\n"))
              (goto-char (point-max))
              (insert "我进门")
              (iuiw-erpg-send)
              (should-not iuiw-erpg--busy)
              (should (equal (buffer-string) (concat turn "\n\n### 你\n\n")))
              (should (= (point) (point-max)))
              (should-not (buffer-modified-p))
              ;; 乙 voice: false，不单独问意图。
              (should (= (length calls) 2))
              ;; 自己写了某个角色的意图，就不再替它生成。
              (should-not (iuiw-erpg--voice-cards
                           (list :campaign iuiw-erpg--campaign :cards (iuiw-erpg-cast iuiw-erpg--campaign)
                                 :state '(:present ("甲"))
                                 :entries (list (iuiw-erpg-entry "user" "我进门")
                                                (iuiw-erpg-entry "voice" "行动：坐下" :name "甲")))))
              (should (string-match-p "甲：行动：起身" (car (last (nth 1 (car calls))))))
              (iuiw-erpg-regenerate)
              (should (equal (buffer-string) (concat turn "\n\n### 你\n\n")))
              ;; 发下一句时，记录员读上一段旁白，记在它后面。
              (insert "我坐下")
              (iuiw-erpg-send)
              (should (string-prefix-p (concat turn "\n\n<!-- 记录\n在场：甲\n+ 你进了门\n-->\n\n### 你\n\n我坐下\n\n")
                                       (buffer-string)))
              (should (equal (iuiw-erpg--state) '(:present ("甲") :body "" :facts ("你进了门"))))
              (should (equal (iuiw-erpg-story-read (iuiw-erpg-story-file iuiw-erpg--campaign))
                             (iuiw-erpg-story-entries)))
              ;; 删掉剧情，记下的事实一起没了。
              (goto-char (point-min))
              (search-forward "<!-- 记录")
              (delete-region (match-beginning 0) (point-max))
              (should (equal (iuiw-erpg--state) '(:present ("甲" "乙") :body "" :facts nil))))
          (set-buffer-modified-p nil)
          (kill-buffer))))))
(ert-deftest iuiw-erpg-branch-copies-the-story-so-far ()
  (iuiw-erpg-test--with-repo
    (let (calls)
      (iuiw-erpg-test--with-models
        (iuiw-erpg-open "c")
        (let ((main (current-buffer)))
          (unwind-protect
              (progn
                (goto-char (point-max))
                (insert "我进门")
                (iuiw-erpg-send)
                (insert "我坐下")
                (iuiw-erpg-send)
                (goto-char (point-min))
                (search-forward "门开了")
                (iuiw-erpg-branch "b")
                (should (equal (iuiw-erpg-file-branch buffer-file-name) "b"))
                (should (equal (iuiw-erpg-branches iuiw-erpg--campaign) '("b" "主线")))
                (should (string-suffix-p "门开了\n\n<!-- 记录\n在场：甲\n+ 你进了门\n-->\n\n### 你\n\n"
                                         (buffer-string)))
                ;; 什么都不写就发送：空段落去掉，剧情接着往下走。
                (iuiw-erpg-send)
                (should (equal (last (mapcar (lambda (e) (plist-get e :role)) (iuiw-erpg-story-entries)) 4)
                               '("record" "voice" "narrator" "user")))
                (should (string-match-p "主线\\|· b" (overlay-get iuiw-erpg--header 'before-string)))
                (with-current-buffer main
                  (should (string-match-p "我坐下" (buffer-string)))))
            (kill-buffer)
            (kill-buffer main)))))))
(ert-deftest iuiw-erpg-state-keeps-notes-apart-from-facts ()
  (iuiw-erpg-test--with-repo
    (let ((campaign (iuiw-erpg-campaign "c")))
      (should (equal (iuiw-erpg-state campaign) '(:present ("甲" "乙") :body "" :facts nil)))
      (iuiw-erpg-write-state campaign '(:present ("甲") :body "手写" :facts ("事一" "事二")))
      (should (equal (iuiw-erpg-state campaign) '(:present ("甲") :body "手写" :facts ("事一" "事二"))))
      (iuiw-erpg-set-present campaign '("乙"))
      (should (equal (plist-get (iuiw-erpg-state campaign) :facts) '("事一" "事二")))
      (should (string-match-p "已经发生、仍然成立的事：\n- 事一\n- 事二"
                              (iuiw-erpg--state-text (iuiw-erpg-state campaign)))))))

(ert-deftest iuiw-erpg-record-applies ()
  (let ((campaign '(:cast ("甲" "乙")))
        (state '(:present ("甲") :body "B" :facts ("一" "二" "三"))))
    (should (equal (iuiw-erpg-parse-record "```json\n{\"add\": [\"四\"], \"remove\": [2]}\n```")
                   '(:add ("四") :remove (2))))
    (should-not (iuiw-erpg-parse-record "抱歉"))
    (pcase-let ((`(,new . ,changes)
                 (iuiw-erpg-apply-record campaign state
                                         '(:present ("甲" "乙" "路人") :add ("四" "") :remove (2)))))
      (should (equal new '(:present ("甲" "乙") :body "B" :facts ("一" "三" "四"))))
      (should (equal changes '("在场：甲、乙" "- 二" "+ 四"))))
    (pcase-let ((`(,new . ,changes) (iuiw-erpg-apply-record campaign state '(:facts ("合并")))))
      (should (equal (plist-get new :facts) '("合并")))
      (should (equal (plist-get new :present) '("甲")))
      (should (equal changes '("= 合并"))))))

(ert-deftest iuiw-erpg-secret-goes-only-to-the-narrator ()
  (iuiw-erpg-test--with-repo
    (iuiw-erpg-test--write "cards/韩立.md" "---\nage: 200\n---\n玩家")
    (iuiw-erpg-test--write "campaigns/c/campaign.md"
                           "---\ntitle: T\nplayer: 韩立\nalias: 厉\ncast: 甲\n---\n世界\n\n## 只给叙事者\n厉就是韩立")
    (let* ((campaign (iuiw-erpg-campaign "c"))
           (state (iuiw-erpg-state campaign))
           (cards (iuiw-erpg-cast campaign)))
      (should (equal (plist-get campaign :body) "世界"))
      (should (string-match-p "厉就是韩立" (iuiw-erpg-narrator-system campaign nil cards)))
      (should-not (string-match-p "厉就是韩立"
                                  (iuiw-erpg-voice-system campaign nil (car cards) cards)))
      (should (string-match-p "厉：来了"
                              (iuiw-erpg-voice-message campaign nil state (list (iuiw-erpg-entry "user" "来了"))
                                                       (car cards)))))))

(ert-deftest iuiw-erpg-campaign-card-and-prior ()
  (iuiw-erpg-test--with-repo
    (make-directory (iuiw-erpg-file "campaigns/d/cards") t)
    (iuiw-erpg-test--write "campaigns/d/cards/甲.md" "---\nage: 37\n---\n后来的甲")
    (iuiw-erpg-test--write "campaigns/d/campaign.md" "---\ntitle: D\ncast: 甲\nfollows: c\n---\n续")
    (iuiw-erpg-write-state (iuiw-erpg-campaign "c") '(:present ("甲") :body "" :facts ("甲救了你")))
    (iuiw-erpg-test--write "campaigns/c/story.md" "### 旁白\n\n开场\n\n<!-- 记录\n+ 你欠甲一命\n-->\n")
    (let* ((campaign (iuiw-erpg-campaign "d"))
           (card (car (iuiw-erpg-cast campaign))))
      (should (equal (plist-get card :age) 37))
      (should (equal (plist-get (iuiw-erpg-card "甲") :age) 30))
      (should (string-match-p "甲救了你\n- 你欠甲一命"
                              (iuiw-erpg-voice-system campaign nil card (list card)))))))

(ert-deftest iuiw-erpg-preview-shows-every-request ()
  (iuiw-erpg-test--with-repo
    (iuiw-erpg-test--write "campaigns/c/story.md" "### 旁白\n\n门开了\n\n### 你\n\n我进门\n")
    (iuiw-erpg-open "c")
    (unwind-protect
        (progn
          (iuiw-erpg-set-length "800-1200")
          (iuiw-erpg-preview)
          (with-current-buffer "*erpg preview c*"
            (let ((text (buffer-string)))
              (should (string-prefix-p "本轮共 3 次请求" text))
              (dolist (part '("━━━━ 甲的意图" "━━━━ 叙事者  a → b" "━━━━ 记录员" "每次 800-1200 字"
                              "我进门\n\n【角色意图】\n甲：（这一轮生成的意图）"))
                (should (string-search part text))))
            (kill-buffer)))
      (kill-buffer "erpg:c"))))

;;; iuiw-erpg-test.el ends here
