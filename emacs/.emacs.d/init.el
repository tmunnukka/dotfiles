;;; -*- lexical-binding: t -*-
;;; early-init.el --- Early initialization

(when (display-graphic-p)
  (let* ((monitors (display-monitor-attributes-list))
         (primary (or (seq-find (lambda (mon) (member 'primary mon))
                                monitors)
                      (car monitors)))
         (workarea (assoc 'workarea primary))
         (work-x (nth 1 workarea))
         (work-y (nth 2 workarea))
         (work-width (nth 3 workarea))
         (work-height (nth 4 workarea))
         ;; Calculate actual scrollbar width
         (scrollbar-width (if (fboundp 'frame-scroll-bar-width)
                             (frame-scroll-bar-width)
                           15))  ; Fallback estimate
         (border-width 10)  ; Window manager borders
         (gap 10)           ; Extra breathing room
         (total-padding (+ scrollbar-width border-width gap))
         (adjusted-width (- work-width total-padding))
         (half-width (/ adjusted-width 2)))
    
    (setq initial-frame-alist
          `((width . (text-pixels . ,half-width))
            (height . (text-pixels . ,work-height))
            (left . ,work-x)
            (top . ,work-y)))
    
    (setq default-frame-alist initial-frame-alist)))

(setq history-length 100)
(savehist-mode 1)
(recentf-mode 1)

;; Prevent package.el loading until we're ready
(setq package-enable-at-startup nil)

;; suppress tree-sitter font lock warnings
(setq warning-suppress-types '((treesit-font-lock-rules-mismatch)))

;; Package configuration

(require 'epg)
(require 'dired)
(require 'dired-aux)
(require 'epg)
(require 'message)
(require 'treesit)

;; do not do right-to-left scanning

(setq-default bidi-display-reordering 'left-to-right
              bidi-paragraph-direction 'left-to-right)
(setq bidi-inhibit-bpa t)

(setq read-process-output-max (* 4 1024 1024)) ; 4MB

;; kill duplicate buffers

(setq kill-do-not-save-duplicates t)

(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages nil)
 '(package-vc-selected-packages
   '((kusanagi-theme :url "https://github.com/LionyxML/kusanagi-theme")
     (php-ts-mode :vc-backend Git :url
		  "https://github.com/emacs-php/php-ts-mode"))))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )


(native-compile-async "/home/timo/.emacs.d/site-lisp/magit/lisp/" 'recursively)

(windmove-default-keybindings)
(winner-mode 1)

;; Enable tab-bar for workspaces
(tab-bar-mode 1)
(setq tab-bar-show 1)  ; Always show tab bar

;; Easier window switching
(global-set-key (kbd "M-o") 'other-window)

(require 'package)
;;; init.el

;; Package management
(require 'package)
(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/")))
(package-initialize)

;; Auto-update packages if older than 7 days
(defun my/maybe-update-packages ()
  "Update packages if it's been more than 7 days."
  (let* ((last-update-file (expand-file-name "last-package-update" user-emacs-directory))
         (last-update-time (when (file-exists-p last-update-file)
                            (with-temp-buffer
                              (insert-file-contents last-update-file)
                              (read (current-buffer)))))
         (days-since (if last-update-time
                        (/ (float-time (time-subtract (current-time) last-update-time)) 86400)
                      999)))
    (when (> days-since 7)
      (message "Updating packages (%.0f days since last update)..." days-since)
      (package-refresh-contents)
      (when (fboundp 'package-upgrade-all)
        (package-upgrade-all t))  ;; t = no confirmation
      (with-temp-file last-update-file
        (prin1 (current-time) (current-buffer)))
      (message "Package update complete!"))))

;; Run check on startup (updates if needed)
(add-hook 'after-init-hook #'my/maybe-update-packages)

;; Manual update keybinding
(global-set-key (kbd "C-c p u") 
                (lambda () 
                  (interactive)
                  (package-refresh-contents)
                  (package-upgrade-all)))


;; Add to init.el                                                                                                                                                                                               
(defun my/update-packages-on-startup ()
  "Update packages on Emacs startup."
  (interactive)
  (package-refresh-contents)
  (package-upgrade-all))


;; Tree-sitter language grammar sources
(setq treesit-language-source-alist
      '((bash "https://github.com/tree-sitter/tree-sitter-bash")
        (cmake "https://github.com/uyha/tree-sitter-cmake")
        (css "https://github.com/tree-sitter/tree-sitter-css")
        (elisp "https://github.com/Wilfred/tree-sitter-elisp")
        (go "https://github.com/tree-sitter/tree-sitter-go")
        (html "https://github.com/tree-sitter/tree-sitter-html")
        (javascript "https://github.com/tree-sitter/tree-sitter-javascript" "master" "src")
        (json "https://github.com/tree-sitter/tree-sitter-json")
        (make "https://github.com/alemuller/tree-sitter-make")
        (markdown "https://github.com/ikatyang/tree-sitter-markdown")
        (python "https://github.com/tree-sitter/tree-sitter-python")
        (toml "https://github.com/tree-sitter/tree-sitter-toml")
        (tsx "https://github.com/tree-sitter/tree-sitter-typescript" "master" "tsx/src")
        (typescript "https://github.com/tree-sitter/tree-sitter-typescript" "master" "typescript/src")
        (yaml "https://github.com/ikatyang/tree-sitter-yaml")
        (c "https://github.com/tree-sitter/tree-sitter-c")
        (cpp "https://github.com/tree-sitter/tree-sitter-cpp")
        (rust "https://github.com/tree-sitter/tree-sitter-rust")
        (commonlisp "https://github.com/tree-sitter-grammars/tree-sitter-commonlisp")))

;; Function to install missing grammars
(defun my/install-treesit-grammars ()
  "Install all tree-sitter grammars from treesit-language-source-alist."
  (interactive)
  (dolist (grammar treesit-language-source-alist)
    (let ((lang (car grammar)))
      (unless (treesit-language-available-p lang)
        (message "Installing tree-sitter grammar for %s..." lang)
        (condition-case err
            (treesit-install-language-grammar lang)
          (error (message "Failed to install %s: %s" lang (error-message-string err))))))))

;; Auto-install on first run (checks once per session)
(defvar my/treesit-grammars-installed nil
  "Track whether we've checked grammars this session.")

(unless my/treesit-grammars-installed
  (my/install-treesit-grammars)
  (setq my/treesit-grammars-installed t))
(put 'upcase-region 'disabled nil)

;; viimeiseksi teema kusanagi

(use-package kusanagi-theme
  :vc (:url "https://github.com/LionyxML/kusanagi-theme" :rev :newest)
  :config
  (add-to-list 'custom-theme-load-path
               (file-name-directory (locate-library "kusanagi-theme")))
  (load-theme 'kusanagi t))
