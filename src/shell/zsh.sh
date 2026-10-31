__imx_precmd() {
    local imx_exit=$?
    if [[ ${PROMPT-} == "${__imx_last_prompt-}" ]]; then
        PROMPT=${__imx_base_prompt-}
    fi
    __imx_base_prompt=${PROMPT-}
    if [[ -n ${IMX_SESSION-} && -f "$__imx_shell_dir/show-session" ]]; then
        PROMPT="[$IMX_SESSION] $__imx_base_prompt"
    fi
    __imx_last_prompt=${PROMPT-}
    return "$imx_exit"
}

typeset -ga precmd_functions
precmd_functions=("${(@)precmd_functions:#__imx_precmd}" __imx_precmd)
