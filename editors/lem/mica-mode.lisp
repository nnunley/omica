;;; mica-mode.lisp --- Major mode for the Mica language  -*- coding: utf-8 -*-
;;
;; Part of the Mica repository; see editors/lem/README.md.
;; The token tables below mirror `keyword_kind' and the punctuation cases in
;; mica/compiler/lexer.odin; keep them in sync when the language changes.

(defpackage :lem-mica-mode
  (:use :cl :lem :lem/language-mode)
  (:export :*mica-mode-hook*
           :mica-mode))
(in-package :lem-mica-mode)

;;; Token tables

(defvar *mica-keywords*
  '("after" "as" "assert" "begin" "break" "catch" "const" "continue" "do"
    "else" "elseif" "end" "finally" "fn" "for" "if" "in" "let" "method"
    "not" "raise" "recover" "require" "retract" "return" "spawn" "try"
    "verb" "while")
  "Reserved words, from `keyword_kind' in mica/compiler/lexer.odin.")

(defvar *mica-constants* '("true" "false")
  "Boolean literals.")

(defvar *mica-builtins*
  '("make_identity" "make_relation" "make_functional_relation")
  "Declarations the runtime predefines.")

(defvar *mica-contextual-keywords*
  '("dom" "exactly" "grant")
  "Words that are keywords only in context.
Distinctive enough to highlight without many false positives.")

(defvar *mica-operators*
  '(":-" "->" "=>" "==" "!=" "<=" ">=" "&&" "||" "..")
  "Operators, longest first so alternation order does not matter.")

;;; Syntax highlighting

(defun mica-tokens (strings)
  "Build a word-boundary ppcre parse tree matching any of STRINGS."
  (list :sequence
        :word-boundary
        (list* :alternation (sort (copy-list strings) #'> :key #'length))
        :word-boundary))

(defun mica-operators-pattern ()
  (list* :alternation (sort (copy-list *mica-operators*) #'> :key #'length)))

(defun mica-string-pattern ()
  "A double-quoted string region, with backslash escapes."
  (make-tm-region '(:sequence "\"")
                  '(:sequence "\"")
                  :name 'syntax-string-attribute
                  :patterns (make-tm-patterns
                             (make-tm-match "\\\\."))))

(defun make-tmlanguage-mica ()
  "Create the TextMate grammar for Mica."
  (make-tmlanguage
   :patterns
   (make-tm-patterns
    ;; Bytes literal b"...".
    (make-tm-region '(:sequence "b\"")
                    '(:sequence "\"")
                    :name 'syntax-string-attribute
                    :patterns (make-tm-patterns
                               (make-tm-match "\\\\.")))
    ;; Strings.
    (mica-string-pattern)
    ;; Line comments.
    (make-tm-region "//" "$" :name 'syntax-comment-attribute)
    ;; Keywords, constants and builtins.
    (make-tm-match (mica-tokens *mica-keywords*)
                   :name 'syntax-keyword-attribute)
    (make-tm-match (mica-tokens *mica-contextual-keywords*)
                   :name 'syntax-builtin-attribute)
    (make-tm-match (mica-tokens *mica-builtins*)
                   :name 'syntax-builtin-attribute)
    (make-tm-match (mica-tokens *mica-constants*)
                   :name 'syntax-constant-attribute)
    ;; Error codes such as E_INVARG.
    (make-tm-match "\\bE_[A-Za-z0-9_]+\\b"
                   :name 'syntax-constant-attribute)
    ;; Durable identities: #lamp, #sensor_17, #event/take, #agent/default.
    (make-tm-match "#[A-Za-z0-9_][A-Za-z0-9_/]*"
                   :name 'syntax-constant-attribute)
    ;; Relation and symbol names: :Label, :record_calibration, :event/take.
    (make-tm-match ":[A-Za-z_][A-Za-z0-9_/]*"
                   :name 'syntax-builtin-attribute)
    ;; Query variables: ?workspace.
    (make-tm-match "\\?[A-Za-z_][A-Za-z0-9_]*"
                   :name 'syntax-variable-attribute)
    ;; Operators.
    (make-tm-match (mica-operators-pattern)
                   :name 'syntax-keyword-attribute)
    ;; Numbers (integer, float, exponent).
    (make-tm-match "\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\b"
                   :name 'syntax-constant-attribute))))

;;; Syntax table

(defvar *mica-syntax-table*
  (make-syntax-table
   :space-chars '(#\space #\tab #\newline)
   :symbol-chars '(#\_ #\# #\: #\? #\@ #\/)
   :paren-pairs '((#\( . #\))
                  (#\{ . #\})
                  (#\[ . #\]))
   :string-quote-chars '(#\")
   :escape-chars '(#\\)
   :line-comment-string "//")
  "Syntax table for `mica-mode'.
The TextMate parser is installed below, once its rules are defined.")

;;; Indentation

(defvar *mica-block-openers*
  '("begin" "catch" "do" "else" "elseif" "finally" "fn" "for" "if"
    "method" "try" "verb" "while")
  "Words that open an `end'-terminated block.
`catch'/`elseif'/`else'/`finally' close the previous arm and open the next, so
they count as openers for the line that follows them.")

(defvar *mica-block-closers*
  '("catch" "else" "elseif" "end" "finally")
  "Block words that sit one level out from the block body.")

(defun mica-line-trim (line)
  (string-trim '(#\space #\tab) line))

(defun mica-comment-line-p (text)
  (and (>= (length text) 2)
       (string= "//" text :end2 2)))

(defun mica-line-starts-with-keyword-p (line keywords)
  "True when LINE begins with one of KEYWORDS as a whole word."
  (let ((text (string-left-trim '(#\space #\tab) line)))
    (dolist (keyword keywords)
      (let ((length (length keyword)))
        (when (and (>= (length text) length)
                   (string= keyword text :end2 length)
                   (or (= (length text) length)
                       (let ((next (char text length)))
                         (not (or (alphanumericp next) (char= next #\_))))))
          (return t))))))

(defun mica-line-opens-block-p (line)
  (mica-line-starts-with-keyword-p line *mica-block-openers*))

(defun mica-line-closes-block-p (line)
  (mica-line-starts-with-keyword-p line *mica-block-closers*))

(defun mica-line-ends-with-p (line suffix)
  (let ((text (mica-line-trim line)))
    (and (>= (length text) (length suffix))
         (string= suffix text :start2 (- (length text) (length suffix))))))

(defun mica-calc-indent (point)
  "Indentation for the line containing POINT.

Blocks run from `if'/'for'/'while'/'verb'/... to their matching `end'.  A rule
body introduced by `:-' is also indented, and runs until a blank line."
  (let ((tab-width (or (variable-value 'tab-width :default point) 2))
        (target-line (line-number-at-point point))
        (stack '()))
    (with-point ((p (buffer-start-point (point-buffer point))))
      (loop :for line := (line-number-at-point p)
            :while (< line target-line)
            :do (let ((text (mica-line-trim (line-string p))))
                  (cond
                    ((string= text "")
                     ;; A blank line ends any rule body.
                     (setf stack (remove :rule stack)))
                    ((mica-comment-line-p text))
                    (t
                     (when (and (mica-line-closes-block-p text)
                                (eq (first stack) :block))
                       (pop stack))
                     (when (mica-line-opens-block-p text)
                       (push :block stack))
                     (when (mica-line-ends-with-p text ":-")
                       (push :rule stack)))))
                 (unless (line-offset p 1)
                   (return)))
      (let ((depth (length stack)))
        (* tab-width
           (if (mica-line-closes-block-p (mica-line-trim (line-string point)))
               (max 0 (1- depth))
               depth))))))

;;; Major mode

(set-syntax-parser *mica-syntax-table* (make-tmlanguage-mica))

(define-major-mode mica-mode language-mode
    (:name "Mica"
     :description "Edits Mica source: facts, rules, verbs and DOM markup."
     :keymap *mica-mode-keymap*
     :syntax-table *mica-syntax-table*
     :mode-hook *mica-mode-hook*)
  (setf (variable-value 'enable-syntax-highlight) t
        (variable-value 'indent-tabs-mode) nil
        (variable-value 'tab-width) 2
        (variable-value 'line-comment) "//"
        (variable-value 'insertion-line-comment) "// "
        (variable-value 'calc-indent-function) 'mica-calc-indent))

;; Associate .mica files with mica-mode.
(define-file-type ("mica") mica-mode)
