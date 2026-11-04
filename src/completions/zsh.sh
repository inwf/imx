#compdef imx

_imx() {
    local kind output
    local -a candidates
    if [[ $words[2] == attach && $CURRENT -gt 2 ]]; then
        local index ended=false
        for ((index=3; index<CURRENT; index++)); do
            [[ $ended == false ]] || return 1
            case $words[index] in
                -r|--read-only) ;;
                --) ended=true ;;
                *) return 1 ;;
            esac
        done
        kind=sessions
        [[ $ended == true || $PREFIX != -* ]] || kind=options-attach
    else
        case $CURRENT in
            2) kind=commands ;;
            3)
                case $words[2] in
                    cat|kill|rename)
                        case $PREFIX in
                            -*) kind=options-$words[2] ;;
                            *) kind=sessions ;;
                        esac
                        ;;
                    help) kind=help ;;
                    list|ls|select|detach|update|uninstall) kind=options-$words[2] ;;
                    *) return 1 ;;
                esac
                ;;
            4)
                [[ $words[3] == -- ]] || return 1
                case $words[2] in
                    cat|kill|rename) kind=sessions ;;
                    *) return 1 ;;
                esac
                ;;
            *) return 1 ;;
        esac
    fi
    output=$(command imx __complete "$kind" "$PREFIX") || return
    [[ -n $output ]] || return 1
    candidates=("${(@f)output}")
    if [[ $kind == sessions && $words[CURRENT-1] != -- ]]; then
        candidates=("${(@)candidates:#-*}")
    fi
    if [[ $kind == sessions && -z $PREFIX && $#candidates -gt 1 ]]; then
        compstate[list]=list
        compstate[insert]=''
    fi
    compadd -a candidates
}

_imx "$@"
