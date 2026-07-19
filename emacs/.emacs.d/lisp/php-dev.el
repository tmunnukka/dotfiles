;;; php-dev.el --- PHP development environment -*- lexical-binding: t; -*-

;; Sibling of cc-dev.el: fills the four language slots (grammar, LSP
;; server, formatter, debug adapter) for PHP. Shared machinery comes
;; from cc-dev.el, which this module requires.
;;
;; Server choice, in the order eglot will try them:
;;   phpactor      -- fully open source, very capable; try this first.
;;                    Install: https://phpactor.github.io (phar or composer)
;;   intelephense  -- strongest PHP server, but freemium: completion/
;;                    navigation/diagnostics free, rename & implementations
;;                    behind a paid key. npm i -g intelephense
;; Formatter: composer global require friendsofphp/php-cs-fixer
;; Run M-x php-dev-doctor (C-c c ? in a PHP buffer) to verify.
;;
;; In PHP buffers C-c c is shadowed by the project map:
;;   C-c c ?  doctor            C-c c t  phpunit
;;   C-c c s  php -S dev server C-c c l  phpstan analyse
;;   C-c c r  run current file  C-c c c  composer install
;;   C-c c k  kill compilation
;; Debugging stays on C-c d; pick `php-xdebug' (setup notes in §5).

(require 'cc-dev)

;;; ---------------------------------------------------------------------
;;; 1. Mode + grammar
;;; ---------------------------------------------------------------------
;; php-ts-mode is built into Emacs 30. It needs FOUR grammars (php,
;; phpdoc, html, css+js for templates); the mode ships an installer:
;; first visit, run M-x php-ts-mode-install-parsers once.

(use-package php-ts-mode
  :ensure nil
  :mode "\\.php\\'"
  :hook (php-ts-mode . php-dev-maybe-eglot))

;;; ---------------------------------------------------------------------
;;; 2. Eglot + phpactor/intelephense
;;; ---------------------------------------------------------------------

(defun php-dev--server ()
  "The PHP language server command to use, or nil if none installed."
  (cond ((executable-find "phpactor")
         '("phpactor" "language-server"))
        ((executable-find "intelephense")
         '("intelephense" "--stdio"))))

(defun php-dev-maybe-eglot ()
  "Start eglot only if a PHP language server is installed."
  (when (php-dev--server)
    (eglot-ensure)))

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               `((php-ts-mode php-mode)
                 . ,(lambda (&rest _)
                      (or (php-dev--server)
                          '("phpactor" "language-server"))))))

;;; ---------------------------------------------------------------------
;;; 3. Formatting
;;; ---------------------------------------------------------------------
;; php-cs-fixer edits files in place rather than filtering stdin, so
;; the formatter spec uses apheleia's `inplace' token. Honors a
;; .php-cs-fixer.php config in the project; without one it applies
;; PSR-12 -- add a config if munnukka has house style opinions.

(with-eval-after-load 'apheleia
  (add-to-list 'apheleia-formatters
               '(php-cs-fixer . ("php-cs-fixer" "fix" "--quiet"
                                 "--using-cache=no" inplace)))
  (add-to-list 'apheleia-mode-alist '(php-ts-mode . php-cs-fixer)))

;;; ---------------------------------------------------------------------
;;; 4. Project commands, doctor
;;; ---------------------------------------------------------------------

(defun php-dev--composer-root ()
  "Topmost directory upward with a composer.json, else project root."
  (let ((dir (expand-file-name default-directory)) root parent)
    (while dir
      (when (file-exists-p (expand-file-name "composer.json" dir))
        (setq root dir))
      (setq parent (file-name-directory (directory-file-name dir))
            dir (and parent (not (equal parent dir)) parent)))
    (or root (cc-dev--project-root))))

(defun php-dev--compile (command)
  "Run COMMAND from the composer/project root."
  (let ((default-directory (php-dev--composer-root)))
    (compile command)))

(defun php-dev-serve ()
  "PHP's built-in dev server at the project root, port 8000.
For a framework with a front controller, point it at the docroot:
prefix arg (C-u C-c c s) prompts for the directory."
  (interactive)
  (let ((dir (if current-prefix-arg
                 (read-directory-name "Document root: ")
               (php-dev--composer-root))))
    (let ((default-directory dir))
      (compile "php -S localhost:8000"))))

(defun php-dev-run-file ()
  "Run the current file with the CLI interpreter."
  (interactive)
  (php-dev--compile (format "php %s" (shell-quote-argument
                                      (buffer-file-name)))))

(defun php-dev-test ()     (interactive) (php-dev--compile "vendor/bin/phpunit"))
(defun php-dev-phpstan ()  (interactive) (php-dev--compile "vendor/bin/phpstan analyse"))
(defun php-dev-composer () (interactive) (php-dev--compile "composer install"))

(defun php-dev-doctor ()
  "Toolchain check for the PHP slots."
  (interactive)
  (let ((tools `(("php"           . ,(executable-find "php"))
                 ("composer"      . ,(executable-find "composer"))
                 ("phpactor"      . ,(executable-find "phpactor"))
                 ("intelephense"  . ,(executable-find "intelephense"))
                 ("php-cs-fixer"  . ,(executable-find "php-cs-fixer"))
                 ("node"          . ,(executable-find "node"))
                 ("xdebug adapter" . ,(and (file-exists-p (php-dev--adapter-js))
                                           (php-dev--adapter-js))))))
    (with-help-window "*php-dev doctor*"
      (princ "php-dev toolchain check\n=======================\n\n")
      (dolist (tool tools)
        (princ (format " %s %-15s %s\n" (if (cdr tool) "✓" "✗")
                       (car tool) (or (cdr tool) "NOT FOUND"))))
      (princ "\nOne LSP server (phpactor OR intelephense) is enough.\n")
      (princ "Xdebug adapter setup: see §5 of php-dev.el.\n"))))

(defvar-keymap php-dev-compile-map
  :doc "PHP project commands; shadows the global C-c c in PHP buffers."
  "?" #'php-dev-doctor
  "s" #'php-dev-serve
  "r" #'php-dev-run-file
  "t" #'php-dev-test
  "l" #'php-dev-phpstan
  "c" #'php-dev-composer
  "k" #'kill-compilation)

(with-eval-after-load 'php-ts-mode
  (keymap-set php-ts-mode-map "C-c c" php-dev-compile-map))

;;; ---------------------------------------------------------------------
;;; 5. Debugging: dape + Xdebug (inverted architecture!)
;;; ---------------------------------------------------------------------
;; PHP debugging is backwards relative to C/Rust: the editor doesn't
;; launch PHP -- PHP connects OUT to a listening adapter when a request
;; carries the Xdebug trigger. The adapter is vscode-php-debug, run
;; under node.
;;
;; One-time setup:
;;   1. sudo apt install php-xdebug   (or pecl install xdebug)
;;      In php.ini / conf.d:  xdebug.mode=debug
;;                            xdebug.start_with_request=trigger
;;   2. Install the adapter:
;;        mkdir -p ~/.emacs.d/debug-adapters && cd ~/.emacs.d/debug-adapters
;;        git clone https://github.com/xdebug/vscode-php-debug
;;        cd vscode-php-debug && npm install && npm run build
;;      (or download a release .vsix and unzip it -- it's a zip)
;;   3. C-c c ? should now show ✓ for the adapter.
;;
;; Session flow: C-c d d -> php-xdebug -> dape starts the adapter,
;; which listens on port 9003. Then TRIGGER the run yourself:
;;   CLI:  XDEBUG_SESSION=1 php script.php
;;   Web:  php-dev-serve (C-c c s), then browse with ?XDEBUG_SESSION=1
;;         appended to the URL (or a browser Xdebug-helper extension).
;; Breakpoints, stepping, watches: identical keys to C -- C-c d b,
;; bare n/s/o/c, C-c d w. Breakpoints in your framework's router while
;; clicking through the site locally is the payoff.

(defcustom php-dev-debug-adapter-dir
  (locate-user-emacs-file "debug-adapters/vscode-php-debug")
  "Directory of a built vscode-php-debug checkout."
  :type 'directory :group 'cc-dev)

(defun php-dev--adapter-js ()
  "Path to the adapter's entry point."
  (expand-file-name "out/phpDebug.js" php-dev-debug-adapter-dir))

(defun php-dev--dape-fn (config)
  "Resolve adapter path and project root at session start."
  (plist-put config 'command-args (list (php-dev--adapter-js)))
  (plist-put config 'command-cwd (php-dev--composer-root))
  config)

(with-eval-after-load 'dape
  (add-to-list 'dape-configs
               `(php-xdebug
                 modes (php-ts-mode php-mode)
                 ensure ,(lambda (_config)
                           (unless (and (executable-find "node")
                                        (file-exists-p (php-dev--adapter-js)))
                             (user-error
                              "vscode-php-debug not found -- see §5 of php-dev.el")))
                 fn php-dev--dape-fn
                 command "node"
                 command-args ("phpDebug.js")     ; replaced by php-dev--dape-fn
                 :type "php"
                 :port 9003                       ; where Xdebug connects in
                 :stopOnEntry nil)))

(provide 'php-dev)
;;; php-dev.el ends here
