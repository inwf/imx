PS1='COMPLETION> '
PROMPT_COMMAND=
. /usr/share/bash-completion/bash_completion

__imx_test_capture() {
    printf '%s' "$READLINE_LINE" > "$IMX_TEST_SHELL_BUFFER"
}
bind -x '"\C-o":__imx_test_capture'
