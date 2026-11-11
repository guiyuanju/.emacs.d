;;; iuiw-sqlmesh.el --- SQLMesh model lineage drawn with dag-draw -*- lexical-binding: t; -*-

;;; Commentary:
;; `iuiw-sqlmesh-lineage' draws the upstream and downstream models of the
;; current model as box-drawing text; RET on a model opens its file.
;; The DAG comes from iuiw-sqlmesh-dag.py run with the project's .venv.

;;; Code:

(require 'dag-draw)
(require 'iuiw-prog)
(require 'json)

(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")

(defconst iuiw-sqlmesh-dag-script
  (expand-file-name "iuiw-sqlmesh-dag.py"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defconst iuiw-sqlmesh-label-width 24
  "Columns a box shows per label line; dag-draw clips longer lines.")

(defvar-local iuiw-sqlmesh-lineage--root nil)
(defvar-local iuiw-sqlmesh-lineage--focus nil)
(defvar-local iuiw-sqlmesh-lineage--depth nil)
(defvar-local iuiw-sqlmesh-lineage--dag nil)

(defun iuiw-sqlmesh--dag (root)
  "Return ROOT's DAG as a hash table of model name to (:path :deps)."
  (let ((python (expand-file-name ".venv/bin/python" root))
        (default-directory root))
    (unless (file-executable-p python)
      (user-error "No .venv/bin/python in %s" root))
    (with-temp-buffer
      (let ((status (call-process python nil (list t nil) nil iuiw-sqlmesh-dag-script)))
        (unless (eql status 0)
          (error "iuiw-sqlmesh-dag.py failed (%s): %s" status (buffer-string))))
      (goto-char (point-min))
      (json-parse-buffer :object-type 'hash-table :array-type 'list
                         :null-object nil))))

(defun iuiw-sqlmesh--downstream (dag)
  "Return DAG's reverse edges as a hash table of model name to dependents."
  (let ((down (make-hash-table :test #'equal)))
    (maphash (lambda (name entry)
               (dolist (dep (gethash "deps" entry))
                 (push name (gethash dep down))))
             dag)
    down))

(defun iuiw-sqlmesh--reachable (start next depth)
  "Return names reachable from START through NEXT within DEPTH steps.
NEXT maps a name to its neighbours; DEPTH nil means no limit."
  (let ((seen (list start))
        (frontier (list start))
        (level 0))
    (while (and frontier (or (null depth) (< level depth)))
      (setq frontier
            (seq-uniq (seq-remove (lambda (n) (member n seen))
                                  (mapcan (lambda (n) (copy-sequence (funcall next n)))
                                          frontier))))
      (setq seen (append seen frontier)
            level (1+ level)))
    seen))

(defun iuiw-sqlmesh--label-lines (name)
  "Return the label lines for model NAME, each fitting one box line."
  (let* ((dot (string-search "." name))
         (schema (and dot (substring name 0 dot)))
         (table (if dot (substring name (1+ dot)) name)))
    (cond
     ((<= (length name) iuiw-sqlmesh-label-width)
      (list (if schema (concat schema " " table) table)))
     ((<= (length table) iuiw-sqlmesh-label-width)
      (if schema (list schema table) (list table)))
     ;; Break an overlong table name after the last underscore that fits.
     ((let ((cut (string-search "_" (reverse
                                    (substring table 0 iuiw-sqlmesh-label-width)))))
        (and cut
             (let ((at (- iuiw-sqlmesh-label-width cut)))
               (list (substring table 0 at) (substring table at))))))
     (t (list table)))))

(defun iuiw-sqlmesh--render (dag focus depth)
  "Return FOCUS's lineage in DAG, DEPTH levels each way, as a string."
  (let* ((up (lambda (n) (gethash "deps" (gethash n dag))))
         (down-table (iuiw-sqlmesh--downstream dag))
         (down (lambda (n) (gethash n down-table)))
         (names (seq-uniq (append (iuiw-sqlmesh--reachable focus up depth)
                                  (iuiw-sqlmesh--reachable focus down depth))))
         (graph (dag-draw-create-graph)))
    (dolist (name names)
      ;; dag-draw wraps only labels over 25 columns; two spaces make every
      ;; two-line label long enough.
      (dag-draw-add-node graph (intern name)
                         (string-join (iuiw-sqlmesh--label-lines name) "  ")))
    (dolist (name names)
      (dolist (dep (funcall up name))
        (when (member dep names)
          (dag-draw-add-edge graph (intern dep) (intern name)))))
    (dag-draw-layout-graph graph)
    (cons names (dag-draw-render-graph graph 'ascii (intern focus)))))

(defun iuiw-sqlmesh--buttonize (names)
  "Turn the longest label line of each of NAMES into a button.
A schema line alone would match other models' boxes too."
  (dolist (name names)
    (let ((line (car (sort (iuiw-sqlmesh--label-lines name)
                           (lambda (a b) (> (length a) (length b)))))))
      (goto-char (point-min))
      (when (re-search-forward (format "[│║] *\\(%s\\) *[│║]" (regexp-quote line))
                               nil t)
        (make-text-button (match-beginning 1) (match-end 1)
                          'iuiw-sqlmesh-model name
                          'help-echo name
                          'action #'iuiw-sqlmesh-lineage--visit-button)))))

(defun iuiw-sqlmesh--narrow-arrows (text)
  "Replace the arrowheads in TEXT with junctions on the box's top border.
CJK monospace fonts draw ▼ two columns wide, which shifts the rest of the line;
edges always run downward, so the arrowhead adds nothing."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (search-forward "▼" nil t)
      (let ((double (memq (char-after (- (point) 2)) '(?═ ?╔ ?╩))))
        (replace-match (if double "╩" "┴") t t)))
    (buffer-string)))

(defun iuiw-sqlmesh-lineage--draw ()
  "Redraw the current lineage buffer from its DAG."
  (let ((inhibit-read-only t)
        (rendered (iuiw-sqlmesh--render iuiw-sqlmesh-lineage--dag
                                        iuiw-sqlmesh-lineage--focus
                                        iuiw-sqlmesh-lineage--depth)))
    (erase-buffer)
    (insert (iuiw-sqlmesh--narrow-arrows (cdr rendered)))
    (iuiw-sqlmesh--buttonize (car rendered))
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward
                        'iuiw-sqlmesh-model iuiw-sqlmesh-lineage--focus t)))
      (goto-char (prop-match-beginning match)))))

(defun iuiw-sqlmesh-lineage--revert (&rest _)
  "Reload the DAG from the project and redraw."
  (setq iuiw-sqlmesh-lineage--dag (iuiw-sqlmesh--dag iuiw-sqlmesh-lineage--root))
  (iuiw-sqlmesh-lineage--draw))

(defun iuiw-sqlmesh-lineage--model-at-point ()
  (or (get-text-property (point) 'iuiw-sqlmesh-model)
      (user-error "No model at point")))

(defun iuiw-sqlmesh-lineage--visit (name)
  "Open model NAME's file; external models jump to their entry."
  (let ((path (gethash "path" (gethash name iuiw-sqlmesh-lineage--dag))))
    (unless path (user-error "%s has no file" name))
    (find-file path)
    (unless (string-suffix-p ".sql" path)
      (goto-char (point-min))
      (when (search-forward (car (last (split-string name "\\."))) nil t)
        (beginning-of-line)))))

(defun iuiw-sqlmesh-lineage--visit-button (button)
  (iuiw-sqlmesh-lineage--visit (button-get button 'iuiw-sqlmesh-model)))

(defun iuiw-sqlmesh-lineage-visit ()
  "Open the file of the model at point."
  (interactive)
  (iuiw-sqlmesh-lineage--visit (iuiw-sqlmesh-lineage--model-at-point)))

(defun iuiw-sqlmesh-lineage-refocus ()
  "Redraw the lineage around the model at point."
  (interactive)
  (setq iuiw-sqlmesh-lineage--focus (iuiw-sqlmesh-lineage--model-at-point))
  (iuiw-sqlmesh-lineage--draw))

(defvar-keymap iuiw-sqlmesh-lineage-mode-map
  :parent special-mode-map
  "RET" #'iuiw-sqlmesh-lineage-visit
  "f" #'iuiw-sqlmesh-lineage-refocus
  "TAB" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode iuiw-sqlmesh-lineage-mode special-mode "SQLMesh-Lineage"
  "Major mode for SQLMesh lineage drawn by `iuiw-sqlmesh-lineage'."
  (setq-local truncate-lines t
              revert-buffer-function #'iuiw-sqlmesh-lineage--revert))

(with-eval-after-load 'evil
  (evil-set-initial-state 'iuiw-sqlmesh-lineage-mode 'motion)
  (evil-define-key* 'motion iuiw-sqlmesh-lineage-mode-map
    (kbd "RET") #'iuiw-sqlmesh-lineage-visit
    "f" #'iuiw-sqlmesh-lineage-refocus
    "gr" #'revert-buffer
    "q" #'quit-window
    (kbd "TAB") #'forward-button
    (kbd "<backtab>") #'backward-button))

;;;###autoload
(defun iuiw-sqlmesh-lineage (&optional depth)
  "Draw the upstream and downstream models of the current model.
With a numeric prefix argument, draw only DEPTH levels each way.
Outside a model file, or with a plain \\[universal-argument], ask for the model."
  (interactive "P")
  (let* ((root (or (iuiw-sqlmesh-project-p) (user-error "Not in a SQLMesh project")))
         (dag (iuiw-sqlmesh--dag root))
         (file (and buffer-file-name (file-truename buffer-file-name)))
         (current (and file (not (consp depth))
                       (string-suffix-p ".sql" file)
                       (seq-find (lambda (name)
                                   (when-let* ((path (gethash "path" (gethash name dag))))
                                     (equal (file-truename path) file)))
                                 (hash-table-keys dag))))
         (focus (or current
                    (completing-read "Model: " (sort (hash-table-keys dag) #'string<)
                                     nil t)))
         (buffer (get-buffer-create
                  (format "*sqlmesh lineage: %s*"
                          (file-name-nondirectory (directory-file-name root))))))
    (with-current-buffer buffer
      (iuiw-sqlmesh-lineage-mode)
      (setq default-directory root
            iuiw-sqlmesh-lineage--root root
            iuiw-sqlmesh-lineage--dag dag
            iuiw-sqlmesh-lineage--focus focus
            iuiw-sqlmesh-lineage--depth (and (integerp depth) depth))
      (iuiw-sqlmesh-lineage--draw))
    (pop-to-buffer-same-window buffer)))

(provide 'iuiw-sqlmesh)
;;; iuiw-sqlmesh.el ends here
