;;; cc-dev.el --- Modern C/C++ development environment -*- lexical-binding: t; -*-

;; Target: Emacs 30.x with native-comp and tree-sitter support.
;; Philosophy: built-in machinery first (eglot, flymake, project.el,
;; tree-sitter), a small set of best-in-class external packages second.
;; No lsp-mode, no company, no helm, no dap-mode. Fewer moving parts,
;; all of them inspectable with C-h f like civilized software.
;;
;; External binaries you need on the system (Ubuntu 24.04):
;;   sudo apt install clangd clang-format clang-tidy cmake bear lldb ripgrep
;;   (or build your own clang toolchain into /opt, naturally)
;; Run M-x cc-dev-doctor (C-c c ?) to verify Emacs can find everything.
;;
;; Load from init.el with:
;;   (add-to-list 'load-path (locate-user-emacs-file "lisp/"))
;;   (require 'cc-dev)
;;
;; Build/CMake keys (C-c c prefix):     Debug keys (C-c d prefix):
;;   C-c c ?  toolchain doctor            C-c d d  start debugger (builds first)
;;   C-c c g  cmake configure ./build     C-c d b  toggle breakpoint
;;   C-c c j  write .clangd file          C-c d C  conditional breakpoint
;;   C-c c b  build (cmake or make)       C-c d n/s/o/c  step over/in/out, continue
;;   C-c c m  bear -- make (compile db)          (repeatable: bare letter after first)
;;   C-c c c  project-compile (prompt)    C-c d e  evaluate expression
;;   C-c c r  recompile                   C-c d w  watch expression
;;   C-c c k  kill compilation            C-c d q  quit session

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
      ;; set this to 'linux with offset 8 via .dir-locals.el.
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
;; so clangd sees the EXACT flags your build uses.

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
  ;; Hover docs in a childframe at point instead of squinting at the
  ;; echo area. C-c l d to pop it on demand.
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
;;; 6. Project root & CMake plumbing (used by build and debug below)
;;; ---------------------------------------------------------------------
;; The point of this section: build and debug commands should work from
;; ANY file in the tree, whether the project is CMake, plain Make, or a
;; kernel-style tree, without you cd-ing anywhere.

(defgroup cc-dev nil
  "C/C++ development environment."
  :group 'tools :prefix "cc-dev-")

(defcustom cc-dev-build-dir "build"
  "Build directory name, relative to the CMake root."
  :type 'string)

(defcustom cc-dev-cmake-configure-args
  "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_BUILD_TYPE=Debug"
  "Extra arguments passed to cmake at configure time."
  :type 'string)

(defun cc-dev--cmake-root ()
  "Topmost directory at or above the current one with a CMakeLists.txt.
Walks upward and keeps the HIGHEST hit, so from src/foo/bar.cpp you get
the project top, not a subdirectory with its own CMakeLists.txt.
Returns nil if the tree isn't CMake at all."
  (let ((dir (expand-file-name default-directory))
        root parent)
    (while dir
      (when (file-exists-p (expand-file-name "CMakeLists.txt" dir))
        (setq root dir))
      (setq parent (file-name-directory (directory-file-name dir))
            dir (and parent (not (equal parent dir)) parent)))
    root))

(defun cc-dev--project-root ()
  "Best guess at the project root: CMake root, else project.el, else here."
  (or (cc-dev--cmake-root)
      (when-let* ((pr (project-current)))
        (project-root pr))
      default-directory))

(defun cc-dev--build-path ()
  "Absolute path of the build directory for the current project."
  (expand-file-name cc-dev-build-dir (cc-dev--project-root)))

;;; --- Toolchain doctor -------------------------------------------------

(defun cc-dev--lldb-dap ()
  "Locate lldb-dap, tolerating Ubuntu's versioned-only binaries.
Ubuntu ships /usr/bin/lldb-dap-18 with NO unversioned symlink (unlike
lldb itself). Search PATH for lldb-dap-N and pick the highest N, so
this keeps working when lldb-dap-19/20 arrive. A plain lldb-dap (e.g.
your own llvm build in /opt) wins if present."
  (or (executable-find "lldb-dap")
      (let ((best nil) (best-ver -1))
        (dolist (dir exec-path)
          (when (file-directory-p dir)
            (dolist (f (directory-files dir nil "\\`lldb-dap-[0-9]+\\'"))
              (let ((ver (string-to-number
                          (substring f (length "lldb-dap-")))))
                (when (and (> ver best-ver)
                           (file-executable-p (expand-file-name f dir)))
                  (setq best (expand-file-name f dir) best-ver ver))))))
        best)))

(defun cc-dev-doctor ()
  "List every external tool this config drives: found or missing.
Run this first when something misbehaves -- nine times out of ten the
answer is a binary Emacs can't see on `exec-path'."
  (interactive)
  (let ((tools `(("clangd"       . ,(executable-find "clangd"))
                 ("clang-format" . ,(executable-find "clang-format"))
                 ("clang-tidy"   . ,(executable-find "clang-tidy"))
                 ("cmake"        . ,(executable-find "cmake"))
                 ("make"         . ,(executable-find "make"))
                 ("bear"         . ,(executable-find "bear"))
                 ("lldb-dap"     . ,(cc-dev--lldb-dap))
                 ("gdb"          . ,(executable-find "gdb"))
                 ("rg"           . ,(executable-find "rg"))
                 ("objdump"      . ,(executable-find "objdump")))))
    (with-help-window "*cc-dev doctor*"
      (princ "cc-dev toolchain check\n")
      (princ "======================\n\n")
      (dolist (tool tools)
        (princ (format " %s %-14s %s\n"
                       (if (cdr tool) "✓" "✗")
                       (car tool)
                       (or (cdr tool) "NOT FOUND"))))
      (princ "\nMissing something? Ubuntu: sudo apt install clangd \
clang-format clang-tidy cmake bear lldb ripgrep\n")
      (princ "Own builds in /opt work too -- just get them onto exec-path.\n"))))

;;; --- CMake configure / .clangd generation -----------------------------

(defun cc-dev-cmake-configure ()
  "Configure the CMake project into `cc-dev-build-dir' at the CMake root.
Exports compile_commands.json, which is 90% of what makes clangd smart."
  (interactive)
  (let ((root (or (cc-dev--cmake-root)
                  (user-error "No CMakeLists.txt found upward from %s"
                              default-directory))))
    (let ((default-directory root))
      (message "CMake root: %s" root)
      (compile (format "cmake -S . -B %s %s"
                       cc-dev-build-dir cc-dev-cmake-configure-args)))))

(defun cc-dev-write-clangd ()
  "Write a .clangd file pointing clangd at the build directory.
Needed for M-. to resolve correctly into STL/system headers when the
compilation database lives in build/ rather than the project root.
Run once per project, then M-x eglot-reconnect."
  (interactive)
  (let* ((root (cc-dev--project-root))
         (file (expand-file-name ".clangd" root)))
    (when (or (not (file-exists-p file))
              (y-or-n-p (format "%s exists; overwrite? " file)))
      (with-temp-file file
        (insert "CompileFlags:\n"
                (format "  CompilationDatabase: %s\n" cc-dev-build-dir)))
      (message "Wrote %s -- M-x eglot-reconnect to pick it up" file))))

(defun cc-dev-bear-make ()
  "Run bear -- make at the project root to produce compile_commands.json.
The non-CMake counterpart of `cc-dev-cmake-configure': for plain
Makefile projects (custom glibc/openssl builds, and friends). Kernel
trees have their own scripts/clang-tools/gen_compile_commands.py, which
is faster on an already-built tree."
  (interactive)
  (let ((default-directory (cc-dev--project-root)))
    (compile (read-string "Command: " "bear -- make -j$(nproc)"))))

;;; --- Build ------------------------------------------------------------

(defun cc-dev-build ()
  "Build the project: cmake --build if configured, else fall back to make.
DWIM order: configured CMake tree -> cmake --build; CMake tree without
build dir -> offer to configure; anything else -> compile at the root."
  (interactive)
  (let* ((cmake-root (cc-dev--cmake-root))
         (build (and cmake-root
                     (expand-file-name cc-dev-build-dir cmake-root))))
    (cond
     ((and build (file-directory-p build))
      (let ((default-directory cmake-root))
        (compile (format "cmake --build %s -j" cc-dev-build-dir))))
     (cmake-root
      (if (y-or-n-p "CMake project not configured yet; configure now? ")
          (cc-dev-cmake-configure)
        (message "Configure first: C-c c g")))
     (t
      (let ((default-directory (cc-dev--project-root)))
        (compile (if (string= compile-command "make -k ")
                     "make -j$(nproc)" compile-command)))))))

(defvar-keymap cc-dev-compile-map
  :doc "Build and toolchain commands, on the C-c c prefix."
  "?" #'cc-dev-doctor
  "g" #'cc-dev-cmake-configure
  "j" #'cc-dev-write-clangd
  "b" #'cc-dev-build
  "m" #'cc-dev-bear-make
  "c" #'project-compile
  "r" #'recompile
  "k" #'kill-compilation)
(keymap-global-set "C-c c" cc-dev-compile-map)

(setq compilation-scroll-output 'first-error
      compilation-max-output-line-length nil)
;; Render ANSI colors from gcc/clang/cmake instead of literal escapes.
(add-hook 'compilation-filter-hook #'ansi-color-compilation-filter)

;;; ---------------------------------------------------------------------
;;; 7. Debugging: dape + lldb-dap, with build-then-debug automation
;;; ---------------------------------------------------------------------
;; dape is the eglot of debuggers: one DAP client, no per-language
;; extension packages. The cc-lldb-cmake config below builds the project
;; first, then finds the executable under build/ automatically -- asking
;; which one if there are several -- instead of LLDB's bogus a.out
;; default or prompting you for a path every session.
;;
;; Adapter choice: lldb-dap, ALSO on Linux. gdb >= 14 speaks DAP
;; natively (config kept below), but gdb 15.1 on Ubuntu 24.04 has two
;; known DAP bugs: `launch' doesn't wait for configurationDone, so
;; breakpoints can lose the race against a fast program; and evaluating
;; an uninitialized local can hang gdb's DAP loop permanently. lldb-dap
;; has neither problem.

(defun cc-dev--find-executables (dir)
  "Recursively list debuggable executables under DIR.
Skips CMake's internal machinery and shared libraries."
  (when (file-directory-p dir)
    (seq-filter
     (lambda (f)
       (and (file-executable-p f)
            (not (file-directory-p f))
            (not (string-match-p
                  "\\.\\(so\\(\\.[0-9.]+\\)?\\|a\\|o\\|sh\\|cmake\\)\\'" f))))
     (directory-files-recursively
      dir ".*" nil
      (lambda (d) (not (string-match-p "CMakeFiles" d)))))))

(defun cc-dev--pick-program ()
  "Choose the executable to debug from the build directory."
  (let ((exes (cc-dev--find-executables (cc-dev--build-path))))
    (cond
     ((null exes)
      (read-file-name "No executable found; path to program: "
                      (cc-dev--build-path)))
     ((null (cdr exes)) (car exes))
     (t (completing-read "Debug which executable: " exes nil t)))))

(defun cc-dev--dape-fn (config)
  "Resolve project root, build command, adapter, and program at launch.
dape calls this each time the config is used, so everything is computed
against the file you're actually in -- no stale paths."
  (let ((root (cc-dev--project-root)))
    (plist-put config 'command-cwd root)
    (when (cc-dev--cmake-root)
      (plist-put config 'compile          ; dape builds before launching
                 (format "cmake --build %s -j" cc-dev-build-dir)))
    (plist-put config :cwd root)
    (plist-put config :program (cc-dev--pick-program))
    config))

(use-package dape
  :custom
  (dape-buffer-window-arrangement 'right)  ; IDE-ish layout
  (dape-inlay-hints t)                     ; variable values inline
  :config
  (add-to-list 'dape-configs
               `(cc-lldb-cmake
                 modes (c-mode c-ts-mode c++-mode c++-ts-mode)
                 ensure ,(lambda (_config)
                           (unless (cc-dev--lldb-dap)
                             (user-error
                              "lldb-dap not found (sudo apt install lldb; \
then C-c c ? to verify)")))
                 fn cc-dev--dape-fn
                 command ,(lambda () (cc-dev--lldb-dap))
                 :type "lldb-dap"
                 :cwd "."
                 :program "a.out"))       ; both replaced by cc-dev--dape-fn
  (add-to-list 'dape-configs
               `(cc-gdb-cmake
                 ;; Kept for completeness; prefer cc-lldb-cmake (see the
                 ;; gdb DAP bug notes at the top of this section).
                 modes (c-mode c-ts-mode c++-mode c++-ts-mode)
                 ensure ,(lambda (_config)
                           (unless (executable-find "gdb")
                             (user-error "gdb not found")))
                 fn cc-dev--dape-fn
                 command "gdb"
                 command-args ("--interpreter=dap")
                 :cwd "."
                 :program "a.out")))

(defvar-keymap cc-dev-debug-map
  :doc "Debugger commands, on the C-c d prefix."
  "d" #'dape                              ; start: pick cc-lldb-cmake
  "b" #'dape-breakpoint-toggle
  "C" #'dape-breakpoint-expression        ; conditional: i == 100 etc.
  "B" #'dape-breakpoint-remove-all
  "n" #'dape-next
  "s" #'dape-step-in
  "o" #'dape-step-out
  "c" #'dape-continue
  "e" #'dape-evaluate-expression
  "w" #'dape-watch-dwim
  "i" #'dape-info
  "R" #'dape-repl
  "r" #'dape-restart
  "p" #'dape-pause
  "q" #'dape-quit)
(keymap-global-set "C-c d" cc-dev-debug-map)

;; repeat-mode (built-in): after C-c d n, keep stepping with bare
;; n/s/o/c/b -- no prefix. The streak ends on any other key.
(defvar-keymap cc-dev-dape-repeat-map
  :doc "Single-key stepping after the first C-c d <step> command."
  :repeat t
  "n" #'dape-next
  "s" #'dape-step-in
  "o" #'dape-step-out
  "c" #'dape-continue
  "b" #'dape-breakpoint-toggle)
(repeat-mode 1)

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
  ;; Highlight TODO/FIXME/HACK/XXX in comments.
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
