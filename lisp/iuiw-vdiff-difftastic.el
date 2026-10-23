;;; iuiw-vdiff-difftastic.el --- Structural diffs in vdiff -*- lexical-binding: t; -*-

;;; Commentary:
;; 让 vdiff 用 difftastic 的语法级 diff：两边按 difftastic 的行对应对齐，改动处按它给的范围上色。
;; 把 `vdiff-diff-algorithm' 设为 `difftastic'，并在 init.el 里挂上下面三个 advice。

;;; Code:

(require 'cl-lib)
(require 'vdiff)

(defconst iuiw-vdiff-difftastic-command "env DFT_UNSTABLE=yes difft --display=json"
  "Command printing difftastic's JSON for two files.")

(defvar-local iuiw-vdiff-difftastic--spans nil
  "Changed spans of the last difftastic run, in vdiff's process buffer.
Each is (SIDE LINE START END): SIDE 0 for the first buffer, LINE from 0,
and START and END byte offsets in that line.")

(defvar-local iuiw-vdiff-difftastic--active nil
  "Non-nil in vdiff's process buffer when its last output came from difftastic.")

(defun iuiw-vdiff-difftastic--suffix (session)
  "Return the extension of the file SESSION compares, as \".el\".
vdiff diffs temporary copies; difftastic picks the language by their name."
  (when-let* ((name (seq-some (lambda (buf)
                                (with-current-buffer buf
                                  (or buffer-file-name
                                      (bound-and-true-p magit-buffer-file-name))))
                              (vdiff-session-buffers session)))
              (ext (file-name-extension name)))
    (concat "." ext)))

(defun iuiw-vdiff-difftastic-refresh (refresh &rest args)
  "Around `vdiff-refresh': run difftastic on copies named like the file.
Fall back to git's histogram diff when difft is missing."
  (if (not (and (eq vdiff-diff-algorithm 'difftastic) vdiff--session))
      (apply refresh args)
    (let* ((vdiff-diff-algorithm (if (executable-find "difft")
                                     'difftastic
                                   'git-diff-histogram))
           (vdiff-diff-algorithms (cons (cons 'difftastic iuiw-vdiff-difftastic-command)
                                        vdiff-diff-algorithms))
           (suffix (iuiw-vdiff-difftastic--suffix vdiff--session))
           (make-temp (symbol-function 'make-temp-file)))
      (cl-letf (((symbol-function 'make-temp-file)
                 (lambda (prefix &optional dir-flag sfx text)
                   (funcall make-temp prefix dir-flag
                            (or sfx (and (string-prefix-p "vdiff-" prefix) suffix))
                            text))))
        (apply refresh args)))))

(defun iuiw-vdiff-difftastic--range (lines prev)
  "Return the vdiff range of LINES, counted from 0.
With no LINES, the range is empty, before the line after PREV."
  (if lines
      (cons (1+ (apply #'min lines)) (1+ (apply #'max lines)))
    (list (+ prev 2))))

(defun iuiw-vdiff-difftastic--hunks (rows changed)
  "Group difftastic's aligned ROWS into vdiff hunks.
A row is a pair of line numbers, nil on the side lacking it.  CHANGED
holds (SIDE . LINE) for the lines with changes."
  (let ((prev-a -1) (prev-b -1) a-lines b-lines hunks)
    (cl-flet ((flush ()
                (when (or a-lines b-lines)
                  (push (list (iuiw-vdiff-difftastic--range a-lines prev-a)
                              (iuiw-vdiff-difftastic--range b-lines prev-b))
                        hunks)
                  (when a-lines (setq prev-a (apply #'max a-lines)))
                  (when b-lines (setq prev-b (apply #'max b-lines)))
                  (setq a-lines nil b-lines nil))))
      (pcase-dolist (`(,a ,b) rows)
        (if (and a b
                 (not (gethash (cons 0 a) changed))
                 (not (gethash (cons 1 b) changed)))
            (progn (flush)
                   (setq prev-a a prev-b b))
          (when a (push a a-lines))
          (when b (push b b-lines))))
      (flush))
    (nreverse hunks)))

(defun iuiw-vdiff-difftastic-parse (parse buf)
  "Around `vdiff--parse-diff-u': read BUF as difftastic's JSON when it is.
Other output goes to PARSE."
  (with-current-buffer buf
    (goto-char (point-min))
    (if (not (re-search-forward "^{" nil t))
        (progn (setq iuiw-vdiff-difftastic--active nil
                     iuiw-vdiff-difftastic--spans nil)
               (funcall parse buf))
      (goto-char (match-beginning 0))
      (let ((json (json-parse-buffer :object-type 'alist :array-type 'list
                                     :null-object nil))
            (changed (make-hash-table :test #'equal))
            spans)
        (dolist (chunk (alist-get 'chunks json))
          (dolist (entry chunk)
            (pcase-dolist (`(,key . ,side) '((lhs . 0) (rhs . 1)))
              (when-let* ((line (alist-get key entry)))
                (let ((n (alist-get 'line_number line)))
                  (puthash (cons side n) t changed)
                  (dolist (change (alist-get 'changes line))
                    (push (list side n (alist-get 'start change) (alist-get 'end change))
                          spans)))))))
        (setq iuiw-vdiff-difftastic--active t
              iuiw-vdiff-difftastic--spans spans)
        (iuiw-vdiff-difftastic--hunks (alist-get 'aligned_lines json) changed)))))

(defun iuiw-vdiff-difftastic--highlight (session spans)
  "Color SPANS inside the change hunks of SESSION's buffers."
  (let ((buffers (vdiff-session-buffers session)))
    ;; Walk each buffer once, line by line, instead of from the top per span.
    (dotimes (side 2)
      (with-current-buffer (nth side buffers)
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (let ((at 0))
              (pcase-dolist (`(,_ ,line ,start ,end)
                             (sort (seq-filter (lambda (span) (= (car span) side)) spans)
                                   :key #'cadr))
                (when (zerop (forward-line (- line at)))
                  (setq at line)
                  (when (seq-find (lambda (o) (eq (overlay-get o 'vdiff-type) 'change))
                                  (overlays-at (point)))
                    (let* ((bytes (position-bytes (point)))
                           (ovr (make-overlay (byte-to-position (+ bytes start))
                                              (byte-to-position (+ bytes end)))))
                      (overlay-put ovr 'vdiff t)
                      (overlay-put ovr 'vdiff-refinement t)
                      (overlay-put ovr 'face 'vdiff-refine-changed))))))))))
    (when vdiff-only-highlight-refinements
      (dolist (buf buffers)
        (with-current-buffer buf
          (dolist (o (overlays-in (point-min) (point-max)))
            (when (eq (overlay-get o 'vdiff-type) 'change)
              (overlay-put o 'face nil))))))))

(defun iuiw-vdiff-difftastic-finish (finish session &rest args)
  "Around `vdiff--diff-refresh-finish': color difftastic's spans.
vdiff's own word refinement is skipped for difftastic output."
  (let* ((proc-buf (get-buffer (vdiff-session-process-buffer session)))
         (active (and proc-buf
                      (buffer-local-value 'iuiw-vdiff-difftastic--active proc-buf)))
         (vdiff-auto-refine (and (not active) vdiff-auto-refine)))
    (apply finish session args)
    (when active
      (iuiw-vdiff-difftastic--highlight
       session (buffer-local-value 'iuiw-vdiff-difftastic--spans proc-buf)))))

(provide 'iuiw-vdiff-difftastic)
;;; iuiw-vdiff-difftastic.el ends here
