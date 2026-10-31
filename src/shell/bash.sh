__imx_shell_dir=${__imx_shell_dir:?}

__imx_prompt() {
    local imx_exit=$?
    if [[ ${PS1-} == "${__imx_last_prompt-}" ]]; then
        PS1=${__imx_base_prompt-}
    fi
    __imx_base_prompt=${PS1-}
    if [[ -n ${IMX_SESSION-} && -f "$__imx_shell_dir/show-session" ]]; then
        PS1="[$IMX_SESSION] $__imx_base_prompt"
    fi
    __imx_last_prompt=${PS1-}
    return "$imx_exit"
}

if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) =~ ^declare\ -[^[:space:]]*a ]]; then
    __imx_commands=()
    for __imx_command in "${PROMPT_COMMAND[@]}"; do
        [[ $__imx_command == __imx_prompt ]] || __imx_commands+=("$__imx_command")
    done
    PROMPT_COMMAND=("${__imx_commands[@]}" __imx_prompt) || return
    unset __imx_commands __imx_command
else
    if [[ ${PROMPT_COMMAND-} != __imx_prompt ]]; then
        __imx_command=${PROMPT_COMMAND[0]-}
        __imx_command=${__imx_command%$'\n__imx_prompt'}
        # 当前分支处理 PROMPT_COMMAND 的字符串形式。
        # shellcheck disable=SC2178
        PROMPT_COMMAND=${__imx_command:+$__imx_command$'\n'}__imx_prompt || return
        unset __imx_command
    fi
fi
