__imx_complete() {
    COMPREPLY=()
    local kind current output
    current=${COMP_WORDS[COMP_CWORD]}
    case $COMP_CWORD in
        1) kind=commands ;;
        2)
            case ${COMP_WORDS[1]} in
                attach|cat|kill)
                    case $current in
                        -*) kind=options-${COMP_WORDS[1]} ;;
                        *) kind=sessions ;;
                    esac
                    ;;
                help) kind=help ;;
                list|ls|detach|update|uninstall) kind=options-${COMP_WORDS[1]} ;;
                *) return 0 ;;
            esac
            ;;
        3)
            [[ ${COMP_WORDS[2]} == -- ]] || return 0
            case ${COMP_WORDS[1]} in
                attach|cat|kill) kind=sessions ;;
                *) return 0 ;;
            esac
            ;;
        *) return 0 ;;
    esac
    output=$(command imx __complete "$kind" "$current") || return
    [[ -n $output ]] || return 0
    mapfile -t COMPREPLY <<< "$output"
    if [[ $kind == sessions && ${COMP_WORDS[COMP_CWORD-1]} != -- ]]; then
        local name
        local -a names=()
        for name in "${COMPREPLY[@]}"; do
            [[ $name != -* ]] && names+=("$name")
        done
        COMPREPLY=("${names[@]}")
    fi
    if [[ $kind == sessions && -z $current && ${#COMPREPLY[@]} -gt 1 && $COMP_POINT -eq ${#COMP_LINE} ]]; then
        printf '\n'
        printf '%s\n' "${COMPREPLY[@]}"
        printf '%s%s' "${PS1@P}" "$COMP_LINE"
        COMPREPLY=()
    fi
}
complete -o nosort -F __imx_complete imx
