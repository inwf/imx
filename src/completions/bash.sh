__imx_complete() {
    COMPREPLY=()
    local kind current output
    current=${COMP_WORDS[COMP_CWORD]}
    if [[ ${COMP_WORDS[1]} == attach && $COMP_CWORD -gt 1 ]]; then
        local index ended=false
        for ((index=2; index<COMP_CWORD; index++)); do
            [[ $ended == false ]] || return 0
            case ${COMP_WORDS[index]} in
                -r|--read-only) ;;
                --) ended=true ;;
                *) return 0 ;;
            esac
        done
        kind=sessions
        [[ $ended == true || $current != -* ]] || kind=options-attach
    else
        case $COMP_CWORD in
            1) kind=commands ;;
            2)
                case ${COMP_WORDS[1]} in
                    cat|kill|rename)
                        case $current in
                            -*) kind=options-${COMP_WORDS[1]} ;;
                            *) kind=sessions ;;
                        esac
                        ;;
                    help) kind=help ;;
                    list|ls|select|detach|update|uninstall) kind=options-${COMP_WORDS[1]} ;;
                    *) return 0 ;;
                esac
                ;;
            3)
                [[ ${COMP_WORDS[2]} == -- ]] || return 0
                case ${COMP_WORDS[1]} in
                    cat|kill|rename) kind=sessions ;;
                    *) return 0 ;;
                esac
                ;;
            *) return 0 ;;
        esac
    fi
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
