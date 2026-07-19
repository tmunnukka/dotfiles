;;; rust-dev.el --- Rust development environment -*- lexical-binding: t; -*-

;; Sibling of cc-dev.el: fills the four language slots (grammar, LSP
;; server, formatter, debug adapter) for Rust. All shared machinery --
;; corfu/vertico/consult, flymake keys, apheleia, dape UI, magit -- comes
;; from cc-dev.el, which this module requires.
;;
;; External binaries (rustup is the sane way):
;;   rustup component add rust-analyzer rustfmt clippy
;;   lldb-dap comes with `apt install lldb' (shared with cc-dev).
;; Run M-x rust-dev-doctor (C-c c ? in a Rust buffer) to verify.
;;
;; In Rust buffers C-c c is shadowed by the cargo map:
;;   C-c c ?  doctor        C-c c t  cargo test
;;   C-c c b  cargo build   C-c c l  cargo clippy
;;   C-c c R  build --release  C-c c d  cargo doc --open
;;   C-c c r  cargo run     C-c c c  cargo check
;;   C-c c k  kill build
;; Debugging stays on the shared C-c d prefix; pick `rust-lldb-cargo'.

(require 'cc-dev)

;;; ---------------------------------------------------------------------
;;; 1. Mode + grammar
;;; ---------------------------------------------------------------------
;; rust-ts-mode is built into Emacs; treesit-auto (from cc-dev) offers
;; to compile the grammar on first visit, same as it did for C.

(use-package rust-ts-mode
  :ensure nil
  :mode "\\.rs\\'"
  :hook (rust-ts-mode . rust-dev-maybe-eglot))

;;; ---------------------------------------------------------------------
;;; 2. Eglot + rust-analyzer
;;; ---------------------------------------------------------------------

(defun rust-dev-maybe-eglot ()
  "Start eglot only if rust-analyzer is installed (same guard as C)."
  (when (executable-find "rust-analyzer")
    (eglot-ensure)))

(with-eval-after-load 'eglot
  ;; check.command clippy: save-time diagnostics come from clippy
  ;; instead of plain `cargo check' -- the lints worth having.
  ;; Everything else (M-., M-?, C-c l r/a/h, M-g s) works unchanged;
  ;; C-c l a is where rust-analyzer shines: fill match arms, extract
  ;; function, add missing impl members. C-c l h inlay hints show
  ;; inferred types and lifetimes -- in Rust that's not a gimmick.
  (add-to-list 'eglot-server-programs
               '((rust-ts-mode rust-mode)
                 . ("rust-analyzer"
                    :initializationOptions
                    (:check (:command "clippy"))))))

;;; ---------------------------------------------------------------------
;;; 3. Formatting
;;; ---------------------------------------------------------------------
;; apheleia (global, from cc-dev) formats on save; just make sure the
;; mode maps to rustfmt. Honors rustfmt.toml in the project.

(with-eval-after-load 'apheleia
  (add-to-list 'apheleia-mode-alist '(rust-ts-mode . rustfmt)))

;;; ---------------------------------------------------------------------
;;; 4. Cargo: root finding, build map, doctor
;;; ---------------------------------------------------------------------

(defun rust-dev--cargo-root ()
  "Topmost directory upward with a Cargo.toml.
Topmost, not nearest: in a workspace you want the workspace root, not
the member crate, so builds and the debugger see everything."
  (let ((dir (expand-file-name default-directory)) root parent)
    (while dir
      (when (file-exists-p (expand-file-name "Cargo.toml" dir))
        (setq root dir))
      (setq parent (file-name-directory (directory-file-name dir))
            dir (and parent (not (equal parent dir)) parent)))
    root))

(defun rust-dev--compile (command)
  "Run COMMAND from the cargo root."
  (let ((default-directory
         (or (rust-dev--cargo-root)
             (user-error "No Cargo.toml found upward from %s"
                         default-directory))))
    (compile command)))

(defun rust-dev-build ()         (interactive) (rust-dev--compile "cargo build"))
(defun rust-dev-build-release () (interactive) (rust-dev--compile "cargo build --release"))
(defun rust-dev-run ()           (interactive) (rust-dev--compile "cargo run"))
(defun rust-dev-test ()          (interactive) (rust-dev--compile "cargo test"))
(defun rust-dev-check ()         (interactive) (rust-dev--compile "cargo check"))
(defun rust-dev-clippy ()        (interactive) (rust-dev--compile "cargo clippy --all-targets"))
(defun rust-dev-doc ()           (interactive) (rust-dev--compile "cargo doc --open"))

(defun rust-dev-doctor ()
  "Toolchain check for the Rust slots."
  (interactive)
  (let ((tools `(("rustc"         . ,(executable-find "rustc"))
                 ("cargo"         . ,(executable-find "cargo"))
                 ("rust-analyzer" . ,(executable-find "rust-analyzer"))
                 ("rustfmt"       . ,(executable-find "rustfmt"))
                 ("cargo-clippy"  . ,(executable-find "cargo-clippy"))
                 ("lldb-dap"      . ,(cc-dev--lldb-dap))
                 ("gdb"           . ,(executable-find "gdb")))))
    (with-help-window "*rust-dev doctor*"
      (princ "rust-dev toolchain check\n========================\n\n")
      (dolist (tool tools)
        (princ (format " %s %-14s %s\n" (if (cdr tool) "✓" "✗")
                       (car tool) (or (cdr tool) "NOT FOUND"))))
      (princ "\nMissing? rustup component add rust-analyzer rustfmt clippy\n"))))

(defvar-keymap rust-dev-compile-map
  :doc "Cargo commands; shadows the global C-c c in Rust buffers."
  "?" #'rust-dev-doctor
  "b" #'rust-dev-build
  "R" #'rust-dev-build-release
  "r" #'rust-dev-run
  "t" #'rust-dev-test
  "c" #'rust-dev-check
  "l" #'rust-dev-clippy
  "d" #'rust-dev-doc
  "k" #'kill-compilation)

(with-eval-after-load 'rust-ts-mode
  (keymap-set rust-ts-mode-map "C-c c" rust-dev-compile-map))

;;; ---------------------------------------------------------------------
;;; 5. Debugging: dape + lldb-dap, cargo-aware
;;; ---------------------------------------------------------------------
;; Same build-then-debug automation as C: `C-c d d', pick
;; rust-lldb-cargo, and dape runs `cargo build', then finds the
;; binary under target/debug/ automatically.
;;
;; Alternative worth knowing: dape's built-in `codelldb-rust' config.
;; codelldb is a Rust-aware lldb wrapper that pretty-prints String,
;; Vec, enums etc. instead of raw structs, and dape offers to download
;; it for you on first use. lldb-dap works fine but shows Rust types
;; in their underlying representation.

(defun rust-dev--binaries (root)
  "Debuggable binaries at the top level of target/debug under ROOT.
Top level only: deps/, build/, incremental/ are compiler machinery."
  (let ((dir (expand-file-name "target/debug" root)))
    (when (file-directory-p dir)
      (seq-filter (lambda (f)
                    (and (file-regular-p f)
                         (file-executable-p f)
                         (not (string-match-p
                               "\\.\\(so\\|d\\|rlib\\)\\'" f))))
                  (directory-files dir t "\\`[^.]")))))

(defun rust-dev--dape-fn (config)
  "Resolve cargo root, build, and binary at debugger launch time."
  (let* ((root (or (rust-dev--cargo-root)
                   (user-error "No Cargo.toml found")))
         (bins (progn (plist-put config 'command-cwd root)
                      (plist-put config 'compile "cargo build")
                      (rust-dev--binaries root))))
    (plist-put config :cwd root)
    (plist-put config :program
               (cond ((null bins)
                      (read-file-name "Binary to debug: "
                                      (expand-file-name "target/debug" root)))
                     ((null (cdr bins)) (car bins))
                     (t (completing-read "Debug which binary: " bins nil t))))
    config))

(with-eval-after-load 'dape
  (add-to-list 'dape-configs
               `(rust-lldb-cargo
                 modes (rust-ts-mode rust-mode)
                 ensure ,(lambda (_config)
                           (unless (cc-dev--lldb-dap)
                             (user-error "lldb-dap not found (apt install lldb)")))
                 fn rust-dev--dape-fn
                 command ,(lambda () (cc-dev--lldb-dap))
                 :type "lldb-dap"
                 :cwd "."
                 :program "target/debug/main")))  ; replaced by rust-dev--dape-fn

(provide 'rust-dev)
;;; rust-dev.el ends here
