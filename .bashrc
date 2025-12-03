# Only load Liquid Prompt in interactive shells, not from a script or from scp
[[ $- = *i* ]] && source ~/liquidprompt/liquidprompt
export TERM="alacritty"
alias doom="~/.config/emacs/bin/doom"
eval "$(direnv hook bash)"
alias godotgl="godot --rendering-driver opengl3"
alias grep="rg"
alias vi="emacsclient -nw"
alias e="emacsclient -nc"
alias et="emacsclient -nw"
man() {
    emacsclient -n -e "
      (let ((f (make-frame '((minibuffer . nil)
                             (name . \"Man Page\")
                             (width . 80)
                             (height . 40)))))
        (select-frame f)
        (man \"$*\")
        (delete-other-windows))
    " >/dev/null 2>&1
}
