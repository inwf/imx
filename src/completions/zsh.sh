#compdef imx

_imx() {
    local kind output
    local -a candidates
    case $CURRENT in
        2) kind=commands ;;
        3)
            case $words[2] in
                attach|cat|kill) kind=sessions ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
    output=$(command imx __complete "$kind" "$PREFIX") || return
    [[ -n $output ]] || return 1
    candidates=("${(@f)output}")
    if [[ $kind == sessions && -z $PREFIX && $#candidates -gt 1 ]]; then
        compstate[list]=list
        compstate[insert]=''
    fi
    compadd -a candidates
}

_imx "$@"
