;;; jgy-elfeed.el --- Elfeed keys and image referer -*- lexical-binding: t; -*-

;;; Commentary:
;; 在 evil-collection 的基础上补 elfeed 按键，不占 vim 的移动键；并让防盗链图片能加载。

;;; Code:

(declare-function evil-define-key* "evil-core")
(declare-function evil-collection-define-operator-key "evil-collection")
(declare-function elfeed-entry-link "elfeed-db")
(defvar elfeed-search-mode-map)
(defvar elfeed-show-mode-map)
(defvar url-current-lastloc)

(defun jgy-elfeed-evil-keys (mode _keymaps)
  "Add elfeed keys that evil-collection lacks in MODE, keeping vim motions."
  (when (eq mode 'elfeed)
    (evil-define-key* '(normal visual) elfeed-search-mode-map
      "r" #'elfeed-search-untag-unread
      "u" #'elfeed-search-tag-unread
      "U" nil
      "a" #'jgy-elfeed-ai-oneline)
    (evil-define-key* 'normal elfeed-search-mode-map
      "gO" #'elfeed-search-browse-url-secondary
      "]]" #'elfeed-search-next-separator
      "[[" #'elfeed-search-previous-separator
      "=" #'elfeed-search-feed-filter
      "~" #'elfeed-search-exclude-feed-filter
      "@" #'elfeed-search-date-filter
      "O" #'elfeed-search-reverse-order
      "A" #'jgy-elfeed-ai-digest
      "gA" #'jgy-elfeed-ai-set-backend)
    (evil-define-key* 'normal elfeed-show-mode-map
      "u" #'elfeed-show-tag-unread
      "R" #'elfeed-show-readable
      "gO" #'elfeed-show-visit-secondary
      "gf" #'elfeed-show-fetch-link
      "a" #'jgy-elfeed-ai-summarize
      "gA" #'jgy-elfeed-ai-set-backend)
    (evil-collection-define-operator-key 'yank 'elfeed-show-mode-map
      "U" #'elfeed-show-copy-url-at-point)))

(defun jgy-elfeed-show-set-referer (&rest _)
  "Send the entry's own URL as Referer so hotlink-protected images load."
  (when-let* ((entry (bound-and-true-p elfeed-show-entry))
              (link (elfeed-entry-link entry)))
    (setq-local url-current-lastloc (url-generic-parse-url link))))

(provide 'jgy-elfeed)
;;; jgy-elfeed.el ends here
