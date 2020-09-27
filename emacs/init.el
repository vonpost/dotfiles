(require 'package)
(set-face-attribute 'default nil :height 110)
;; optional. makes unpure packages archives unavailable
(setq package-archives nil)

(setq package-enable-at-startup nil)

;; Added by Package.el.  This must come before configurations of
;; installed packages.  Don't delete this line.  If you don't want it,
;; just comment it out by adding a semicolon to the start of the line.
;; You may delete these explanatory comments.
(package-initialize)

;; Start as a daemon and let xmonad handle stuff, global modes etc.
(server-start)
(frames-only-mode)
(ivy-mode 1)
;;(counsel-mode 1)

;; Convenience
(display-battery-mode 1)
(display-time-mode 1)

;; Evil
(setq evil-want-integration nil)
(evil-mode 1)
(setq evil-collection-setup-minibuffer t)
(evil-collection-init)

;;; Developing
(add-hook 'prog-mode-hook 'rainbow-delimiters-mode)
;; Haskell
;; (setq haskell-process-wrapper-function
;;       (lambda (args) (apply 'nix-shell-command (nix-current-sandbox) args)))
(add-hook 'haskell-mode-hook 'dante-mode)
(add-hook 'haskell-mode-hook 'flycheck-mode)


;; Enable which-key
(which-key-mode 1)

;; Use pdf-tools to open PDF files
(setq TeX-view-program-selection '((output-pdf "PDF Tools"))
      TeX-source-correlate-start-server t)

;; Update PDF buffers after successful LaTeX runs
(add-hook 'TeX-after-compilation-finished-functions
           #'TeX-revert-document-buffer)

;; Enable pdf tools
(pdf-tools-install)


(setq backup-directory-alist
      `(("." . ,(concat user-emacs-directory "backups"))))

;; Remove all gui elements
(menu-bar-mode 0)
(toggle-scroll-bar 0)
(tool-bar-mode 0)
(global-visual-line-mode)
(setq initial-scratch-message "")
(defun my/disable-scroll-bars (frame)
  (modify-frame-parameters frame
                           '((vertical-scroll-bars . nil)
                             (horizontal-scroll-bars . nil))))
(add-hook 'after-make-frame-functions 'my/disable-scroll-bars)
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(ansi-color-faces-vector
   [default default default italic underline success warning error])
 '(ansi-color-names-vector
   ["#242424" "#e5786d" "#95e454" "#cae682" "#8ac6f2" "#333366" "#ccaa8f" "#f6f3e8"])
 '(custom-enabled-themes '(xresources))
 '(custom-safe-themes
   '("e0c66085db350558f90f676e5a51c825cb1e0622020eeda6c573b07cb8d44be5" default))
 '(global-auto-revert-mode t)
 '(indent-tabs-mode nil)
 '(package-selected-packages
   '(csharp-mode which-key visual-regexp-steroids rust-mode ranger rainbow-mode rainbow-delimiters projectile pdf-tools nix-mode nix-buffer magit latex-preview-pane ivy-pass idris-mode highlight-parentheses frames-only-mode evil-collection dante counsel company-math auctex))
 '(tab-width 4))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(rainbow-delimiters-depth-1-face ((t (:foreground "dark orange"))))
 '(rainbow-delimiters-depth-2-face ((t (:foreground "pink"))))
 '(rainbow-delimiters-depth-3-face ((t (:foreground "chartreuse"))))
 '(rainbow-delimiters-depth-4-face ((t (:foreground "deep sky blue"))))
 '(rainbow-delimiters-depth-5-face ((t (:foreground "yellow"))))
 '(rainbow-delimiters-depth-6-face ((t (:foreground "orchid"))))
 '(rainbow-delimiters-depth-7-face ((t (:foreground "spring green"))))
 '(rainbow-delimiters-depth-8-face ((t (:foreground "sienna1"))))
 '(rainbow-delimiters-mismatched-face ((t (:foreground "red"))))
 '(rainbow-delimiters-unmatched-face ((t (:foreground "red")))))
 

(add-hook 'after-make-frame-functions (lambda (frame) (load-theme 'xresources)))
