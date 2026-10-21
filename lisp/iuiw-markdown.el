;;; iuiw-markdown.el --- GitHub-styled markdown preview -*- lexical-binding: t; -*-

;;; Commentary:
;; markdown-preview 页面的 head：GitHub 样式、深浅色、highlight.js 与任务列表。

;;; Code:

(defconst iuiw-markdown-preview-head
  (let ((gh "https://cdn.jsdelivr.net/npm/github-markdown-css@5/github-markdown.css")
        (hl "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11"))
    (concat
     "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>\n"
     (format "<link rel=\"stylesheet\" href=\"%s\"/>\n" gh)
     (format "<link rel=\"stylesheet\" href=\"%s/styles/github.min.css\" media=\"(prefers-color-scheme: light)\"/>\n" hl)
     (format "<link rel=\"stylesheet\" href=\"%s/styles/github-dark.min.css\" media=\"(prefers-color-scheme: dark)\"/>\n" hl)
     ;; github-markdown-css scopes its palette to .markdown-body, so the page
     ;; canvas and the reading column need setting separately.
     "<style>\n"
     "html { color-scheme: light dark; }\n"
     "body { margin: 0; background: #ffffff; }\n"
     "@media (prefers-color-scheme: dark) { body { background: #0d1117; } }\n"
     ".markdown-body { box-sizing: border-box; max-width: 980px; margin: 0 auto; padding: 2.5rem 1.5rem 6rem; }\n"
     "@media (max-width: 767px) { .markdown-body { padding: 1.25rem; } }\n"
     "</style>\n"
     (format "<script src=\"%s/highlight.min.js\"></script>\n" hl)
     ;; Pandoc names task-list elements differently than GitHub's stylesheet
     ;; expects, so relabel them instead of restyling them.
     "<script>addEventListener(\"DOMContentLoaded\", function () {\n"
     "  hljs.highlightAll();\n"
     "  document.querySelectorAll(\"ul.task-list > li\").forEach(function (li) {\n"
     "    li.classList.add(\"task-list-item\");\n"
     "    li.querySelectorAll(\"input[type=checkbox]\").forEach(function (box) {\n"
     "      box.classList.add(\"task-list-item-checkbox\");\n"
     "    });\n"
     "  });\n"
     "});</script>\n"))
  "Head markup giving `markdown-preview' GitHub styling and highlight.js.")

(provide 'iuiw-markdown)
;;; iuiw-markdown.el ends here
