;;; cc-dev.el --- Modern C/C++ development environment -*- lexical-binding: t; -*-

;; Target: Emacs 30.x with native-comp and tree-sitter support.
;; Philosophy: built-in machinery first (eglot, flymake, project.el,
;; tree-sitter), a small set of best-in-class external packages second.
;; No lsp-mode, no company, no helm, no dap-mode. Fewer moving parts,
;; all of them inspectable with C-h f like civilized software.
;;
;; External binaries you need on the system (Ubuntu 24.04):
;;   sudo apt install clangd clang-format clang-tidy bear lldb
;;   (or build your own clang toolchain into /opt, naturally)
;;
;; Load from init.el with: (load "~/.emacs.d/lisp/cc-dev.el")

;;; ---------------------------------------------------------------------
;;; 0. Package plumbing
;;; ---------------------------------------------------------------------

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
;; use-package is built-in since Emacs 29. `ensure' pulls from MELPA/ELPA.
(setq use-package-always-ensure t)

;;; ---------------------------------------------------------------------
;;; 1. Tree-sitter: modern syntax awareness
;;; ---------------------------------------------------------------------
;; c-ts-mode/c++-ts-mode use a real parse tree instead of cc-mode's
;; thirty years of regex heuristics. Faster fontification on big files
;; (kernel sources included) and structural navigation for free:
;; C-M-a/C-M-e jump by function, treesit-* commands walk the AST.

(use-package treesit-auto
  ;; Auto-installs missing grammars (compiles a small .so per language)
  ;; and remaps c-mode -> c-ts-mode etc. One-time cost per grammar.
  :custom (treesit-auto-install 'prompt)
  :config
  (treesit-auto-add-to-auto-mode-alist '(c cpp cmake))
  (global-treesit-auto-mode))

(setq c-ts-mode-indent-offset 4
      ;; 'linux, 'gnu, 'k&r, 'bsd, or a custom function. For kernel work
      ;; set this to 'linux with offset 8 via .dir-locals.el (see notes).
      c-ts-mode-indent-style 'k&r)

;; Heavier fontification than the conservative default. Tree-sitter can
;; afford it.
(setq treesit-font-lock-level 4)

;;; ---------------------------------------------------------------------
;;; 2. Eglot + clangd: the semantic brain
;;; ---------------------------------------------------------------------
;; Eglot is built-in. It speaks LSP to clangd, which gives you:
;; completion, go-to-definition, find-references, rename, signature
;; help, diagnostics (via flymake), code actions, inlay hints, and
;; clang-tidy findings inline. All of it driven by compile_commands.json,
;; so clangd sees the EXACT flags your build uses -- including -std=c23,
;; your -march=amdfam10, and any -I into /opt/*-custom/include.

(use-package eglot
  :ensure nil                        ; built-in
  :hook ((c-ts-mode c++-ts-mode) . eglot-ensure)
  :bind (:map eglot-mode-map
         ("C-c l r" . eglot-rename)
         ("C-c l a" . eglot-code-actions)
         ("C-c l h" . eglot-inlay-hints-mode)
         ("C-c l f" . eglot-format))
  :config
  ;; clangd flags worth having:
  ;;   --background-index    index the whole project in the background
  ;;   --clang-tidy          run clang-tidy checks as you type
  ;;   --header-insertion    auto-add #include on completion (iwyu style)
  ;;   --completion-style    detailed = one candidate per overload
  (add-to-list 'eglot-server-programs
               '((c-ts-mode c++-ts-mode c-mode c++-mode)
                 . ("clangd"
                    "--background-index"
                    "--clang-tidy"
                    "--header-insertion=iwyu"
                    "--completion-style=detailed"
                    "--function-arg-placeholders=0")))
  ;; Snappier feel; clangd is fast enough to deserve it.
  (setq eglot-send-changes-idle-time 0.2
        ;; Don't log every JSON-RPC message; large events lag Emacs.
        eglot-events-buffer-config '(:size 0 :format full))
  ;; Shut down the server when the last project buffer closes.
  (setq eglot-autoshutdown t))

;; Eldoc renders signature help / hover docs. Keep it to one echo-area
;; line; M-x eldoc (or the box below) when you want the full text.
(setq eldoc-echo-area-use-multiline-p nil)

(use-package eldoc-box
  ;; Optional but pleasant: hover docs in a childframe at point instead
  ;; of squinting at the echo area. C-c l d to toggle on demand.
  :bind ("C-c l d" . eldoc-box-help-at-point))

;; Jump between foo.c and foo.h. Built-in, criminally unknown.
(keymap-global-set "C-c o" #'ff-find-other-file)

;;; ---------------------------------------------------------------------
;;; 3. Flymake: diagnostics UI (fed by clangd)
;;; ---------------------------------------------------------------------

(use-package flymake
  :ensure nil
  :bind (:map flymake-mode-map
         ("M-n" . flymake-goto-next-error)
         ("M-p" . flymake-goto-prev-error)
         ("C-c ! l" . flymake-show-buffer-diagnostics)
         ("C-c ! p" . flymake-show-project-diagnostics)))

;;; ---------------------------------------------------------------------
;;; 4. Completion: corfu in-buffer, vertico & friends in the minibuffer
;;; ---------------------------------------------------------------------

(use-package corfu
  ;; In-buffer completion popup. Uses the standard completion-at-point
  ;; machinery, so eglot plugs in with zero configuration.
  :custom
  (corfu-auto t)                     ; pop up as you type
  (corfu-auto-delay 0.1)
  (corfu-auto-prefix 2)              ; after 2 chars
  (corfu-cycle t)
  :init (global-corfu-mode)
  :config (corfu-popupinfo-mode))    ; doc popup next to candidates

(use-package cape
  ;; Extra completion sources merged with LSP results.
  :init
  (add-hook 'completion-at-point-functions #'cape-file)     ; paths in #include
  (add-hook 'completion-at-point-functions #'cape-dabbrev)) ; words from buffers

(use-package vertico
  ;; Vertical minibuffer completion. Small, predictable.
  :init (vertico-mode))

(use-package orderless
  ;; Type space-separated substrings in any order: "sock recv" matches
  ;; recv_from_socket. Applies to minibuffer AND corfu candidates.
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles basic partial-completion))
                                   (eglot (styles orderless)))))

(use-package marginalia
  ;; Annotations in the minibuffer (docstrings, file sizes, keybindings).
  :init (marginalia-mode))

(use-package consult
  ;; Souped-up versions of standard commands, with live preview.
  :bind (("C-s"     . consult-line)          ; isearch with overview
         ("M-g i"   . consult-imenu)         ; jump to function/struct
         ("M-g g"   . consult-goto-line)
         ("C-x b"   . consult-buffer)
         ("M-s r"   . consult-ripgrep)       ; needs ripgrep installed
         ("M-g f"   . consult-flymake)))     ; diagnostics picker

(use-package consult-eglot
  ;; Fuzzy-search every symbol in the project via clangd's index.
  :bind ("M-g s" . consult-eglot-symbols))

(use-package embark
  ;; Context menu on anything: point at a symbol, C-., act on it
  ;; (find refs, rename, google it...). The "right-click" of Emacs.
  :bind (("C-." . embark-act))
  :config (use-package embark-consult))

;;; ---------------------------------------------------------------------
;;; 5. Formatting
;;; ---------------------------------------------------------------------

(use-package apheleia
  ;; Runs clang-format asynchronously on save WITHOUT moving point or
  ;; janking the buffer -- it applies an RCS diff of the result. Reads
  ;; your project's .clang-format file. Toggle per-buffer with
  ;; M-x apheleia-mode if a project has, let's say, opinions.
  :init (apheleia-global-mode))

(use-package ws-butler
  ;; Trims trailing whitespace, but ONLY on lines you actually touched.
  ;; Keeps diffs clean without whitespace-bombing legacy files.
  :hook (prog-mode . ws-butler-mode))

;;; ---------------------------------------------------------------------
;;; 6. Build & compile
;;; ---------------------------------------------------------------------
;; project.el (built-in) + M-x project-compile is usually all you need.
;; C-x p c compiles from the project root, errors are hyperlinked.

(setq compilation-scroll-output 'first-error
      compilation-max-output-line-length nil)
;; Render ANSI colors from gcc/clang/cmake instead of literal escapes.
(add-hook 'compilation-filter-hook #'ansi-color-compilation-filter)

(keymap-global-set "C-c c" #'project-compile)
(keymap-global-set "C-c C-r" #'recompile)

;;; ---------------------------------------------------------------------
;;; 7. Debugging: dape + lldb-dap
;;; ---------------------------------------------------------------------

(use-package dape
  ;; Debug Adapter Protocol client in the eglot spirit: no per-language
  ;; extension packages. Works with lldb-dap (ships with lldb >= 18,
  ;; formerly lldb-vscode) or gdb >= 14 (native DAP support).
  ;; M-x dape, pick a config, set breakpoints with `dape-breakpoint-toggle'.
  :bind ("C-c d" . dape)
  :custom
  (dape-buffer-window-arrangement 'right)  ; IDE-ish layout
  (dape-inlay-hints t))                    ; variable values inline

;;; ---------------------------------------------------------------------
;;; 8. Quality of life
;;; ---------------------------------------------------------------------

;; Built-in since Emacs 30: shows available keybindings after a prefix.
(which-key-mode)
;; Built-in since 30.1: honors .editorconfig files.
(editorconfig-mode)

;; Magit you already have; listed for completeness.
(use-package magit
  :bind ("C-x g" . magit-status))

(use-package hl-todo
  ;; Highlight TODO/FIXME/HACK/XXX in comments; consult-todo to list them.
  :hook (prog-mode . hl-todo-mode))

(use-package yasnippet
  ;; Snippet expansion; eglot advertises snippet support to clangd, so
  ;; completing a function can drop placeholder args you TAB through.
  :hook ((c-ts-mode c++-ts-mode) . yas-minor-mode))
(use-package yasnippet-snippets)     ; a starter collection

;; Show matching paren instantly, subtle line numbers in code buffers.
(setq show-paren-delay 0)
(add-hook 'prog-mode-hook #'display-line-numbers-mode)

(provide 'cc-dev)
;;; cc-dev.el ends here
