PROMPT='COMPLETION> '
if [[ -n $IMX_TEST_COMPLETION_PREFIX ]]; then
    fpath=("$IMX_TEST_COMPLETION_PREFIX/share/zsh/site-functions" $fpath)
fi
autoload -Uz compinit
compinit -D
bindkey -e

__imx_test_capture() {
    print -rn -- "$BUFFER" > "$IMX_TEST_SHELL_BUFFER"
}
zle -N __imx_test_capture
bindkey '^O' __imx_test_capture
