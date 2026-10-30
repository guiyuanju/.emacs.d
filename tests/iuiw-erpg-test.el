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

(ert-deftest iuiw-erpg-card-needs-age ()
  (iuiw-erpg-test--with-repo
    (iuiw-erpg-test--write "cards/丙.md" "设定")
    (should-error (iuiw-erpg-card "丙") :type 'user-error)
    (should (iuiw-erpg-minor-p (iuiw-erpg-card "乙")))
    (should-not (plist-get (iuiw-erpg-card "乙") :voice))))

(ert-deftest iuiw-erpg-log-round-trip ()
  (iuiw-erpg-test--with-repo
    (let* ((campaign (iuiw-erpg-campaign "c"))
           (entry (iuiw-erpg-entry-add-swipe (iuiw-erpg-entry "narrator" "一" :hidden t :model nil) "二")))
      (iuiw-erpg-log-write campaign (list entry))
      (let ((read (car (iuiw-erpg-log-read campaign))))
        (should (equal (plist-get read :swipes) ["一" "二"]))
        (should (equal (iuiw-erpg-entry-text read) "二"))
        (should (eq (plist-get read :hidden) t))
        (should-not (plist-member read :model))))))

(ert-deftest iuiw-erpg-minors-always-named-in-rules ()
  (iuiw-erpg-test--with-repo
    (let* ((campaign (iuiw-erpg-campaign "c"))
           (cards (iuiw-erpg-cast campaign))
           (system (iuiw-erpg-narrator-system campaign (iuiw-erpg-preset "default")
                                              (iuiw-erpg-state campaign) cards)))
      (should (string-prefix-p "SYS" system))
      (should (string-match-p "乙未满 18 岁" system))
      (should (string-match-p "乙未满 18 岁"
                              (iuiw-erpg-voice-system campaign nil (iuiw-erpg-state campaign)
                                                      (car cards) cards))))))

(ert-deftest iuiw-erpg-narrator-messages-slots ()
  (iuiw-erpg-test--with-repo
    (let* ((campaign (iuiw-erpg-campaign "c"))
           (preset (iuiw-erpg-preset "default"))
           (entries (list (iuiw-erpg-entry "narrator" "开场")
                          (iuiw-erpg-entry "user" "u1")
                          (iuiw-erpg-entry "narrator" "n1")
                          (iuiw-erpg-entry "narrator" "被拒" :hidden t)
                          (iuiw-erpg-entry "director" "旧指令")
                          (iuiw-erpg-entry "narrator" "n2")
                          (iuiw-erpg-entry "user" "u2")
                          (iuiw-erpg-entry "voice" "VOICE" :name "甲")))
           (messages (iuiw-erpg-narrator-messages campaign preset entries '(("甲" . "想走")) nil "PRE")))
      ;; 开场前补一条用户消息；隐藏的、意图和已经过去的导演指令都不发。
      (should (equal (car messages) "（开始）"))
      (should (equal (nth 1 messages) "开场"))
      (should-not (cl-some (lambda (m) (string-match-p "被拒\\|旧指令\\|VOICE" m)) messages))
      (should (string-match-p "\\`u2\n\n【角色意图】\n甲：想走\n\nPOST\\'" (nth 4 messages)))
      ;; depth 2：落在倒数第 2 条之前最近的用户消息上。
      (should (string-match-p "u1\n\nDEPTH" (nth 2 messages)))
      (should (equal (car (last messages)) "PRE"))
      (should (= (length messages) 6)))))

(ert-deftest iuiw-erpg-continue-ends-with-the-reply ()
  (iuiw-erpg-test--with-repo
    (let* ((campaign (iuiw-erpg-campaign "c"))
           (entries (list (iuiw-erpg-entry "user" "u") (iuiw-erpg-entry "narrator" "n")))
           (messages (iuiw-erpg-narrator-messages campaign nil entries nil t "PRE")))
      (should (equal messages '("u" "n")))
      (should-error (iuiw-erpg-narrator-messages campaign nil (list (car entries)) nil t)
                    :type 'user-error))))

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

(ert-deftest iuiw-erpg-turn-runs-voices-then-narrator ()
  (iuiw-erpg-test--with-repo
    (let (calls)
      (cl-letf (((symbol-function 'iuiw-erpg-request)
                 (cl-function
                  (lambda (alias system messages &key on-chunk callback &allow-other-keys)
                    (push (list alias system messages) calls)
                    (cond ((string-match-p "你只扮演甲" system)
                           (funcall callback "行动：起身" nil))
                          (on-chunk
                           (funcall on-chunk "门")
                           (funcall on-chunk "开了")
                           (funcall callback "门开了" nil)))))))
        (iuiw-erpg-open "c")
        (unwind-protect
            (progn
              (goto-char (point-max))
              (insert "我进门")
              (iuiw-erpg-send)
              (should-not iuiw-erpg--busy)
              (should (equal (mapcar (lambda (e) (plist-get e :role)) iuiw-erpg--entries)
                             '("user" "voice" "narrator")))
              ;; 乙 voice: false，不单独问意图。
              (should (= (length calls) 2))
              (should (string-match-p "甲：行动：起身" (car (last (nth 2 (car calls))))))
              (should (string-match-p "旁白  a\n门开了\n\n> \\'" (buffer-string)))
              (should (equal (iuiw-erpg--input) ""))
              (iuiw-erpg-regenerate)
              (should (equal (plist-get (nth 2 iuiw-erpg--entries) :swipes) ["门开了" "门开了"]))
              (should (= (length (iuiw-erpg-log-read iuiw-erpg--campaign)) 3)))
          (kill-buffer))))))

;;; iuiw-erpg-test.el ends here
