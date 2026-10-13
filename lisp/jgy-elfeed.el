;;; jgy-elfeed.el --- Elfeed keys and image referer -*- lexical-binding: t; -*-

;;; Commentary:
;; 找回被 evil-collection 盖掉的 elfeed 按键，并让防盗链图片能加载。

;;; Code:

(declare-function evil-define-key* "evil-core")
(declare-function elfeed-entry-link "elfeed-db")
(defvar elfeed-search-mode-map)
(defvar elfeed-show-mode-map)
(defvar url-current-lastloc)

(defun jgy-elfeed-evil-keys (mode _keymaps)
  "Restore elfeed's own keys that evil-collection leaves to evil in MODE."
  (when (eq mode 'elfeed)
    (evil-define-key* 'normal elfeed-search-mode-map
      "G" #'elfeed-search-fetch
      "b" #'elfeed-search-browse-url
      "B" #'elfeed-search-browse-url-secondary
      "m" #'elfeed-search-mark
      "M" #'elfeed-search-unmark
      "r" #'elfeed-search-untag-unread
      "u" #'elfeed-search-tag-unread
      "t" #'elfeed-search-set-entry-title
      "T" #'elfeed-search-set-feed-title
      "o" #'elfeed-search-cycle-order
      "O" #'elfeed-search-reverse-order
      "@" #'elfeed-search-date-filter
      "=" #'elfeed-search-feed-filter
      "~" #'elfeed-search-exclude-feed-filter
      "<" #'elfeed-search-first-entry
      ">" #'elfeed-search-last-entry
      "a" #'jgy-elfeed-ai-digest)
    (evil-define-key* 'normal elfeed-show-mode-map
      "b" #'elfeed-show-visit
      "B" #'elfeed-show-visit-secondary
      "R" #'elfeed-show-readable
      "c" #'elfeed-show-copy-url-at-point
      "u" #'elfeed-show-tag-unread
      "n" #'elfeed-show-next
      "p" #'elfeed-show-prev
      "a" #'jgy-elfeed-ai-summarize)))

(defun jgy-elfeed-show-set-referer (&rest _)
  "Send the entry's own URL as Referer so hotlink-protected images load."
  (when-let* ((entry (bound-and-true-p elfeed-show-entry))
              (link (elfeed-entry-link entry)))
    (setq-local url-current-lastloc (url-generic-parse-url link))))

(provide 'jgy-elfeed)
;;; jgy-elfeed.el ends here
