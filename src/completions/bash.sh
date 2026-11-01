__imx_complete() {
    COMPREPLY=()
    local kind current output
    current=${COMP_WORDS[COMP_CWORD]}
    case $COMP_CWORD in
        1) kind=commands ;;
        2)
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
    if [[ $kind == sessions && -z $current && ${#COMPREPLY[@]} -gt 1 && $COMP_POINT -eq ${#COMP_LINE} ]]; then
        printf '\n'
        printf '%s\n' "${COMPREPLY[@]}"
        printf '%s%s' "${PS1@P}" "$COMP_LINE"
        COMPREPLY=()
    fi
}
complete -o nosort -F __imx_complete imx
