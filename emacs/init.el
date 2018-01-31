
;; Added by Package.el.  This must come before configurations of
;; installed packages.  Don't delete this line.  If you don't want it,
;; just comment it out by adding a semicolon to the start of the line.
;; You may delete these explanatory comments.
(package-initialize)

;; Start as a daemon and let xmonad handle stuff, global modes etc.
(server-start)
(evil-mode 1)
(frames-only-mode)
(ivy-mode 1)
;; Remove all gui elements
(menu-bar-mode 0)
(toggle-scroll-bar 0)
(tool-bar-mode 0)
