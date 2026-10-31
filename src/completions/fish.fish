function __imx_candidates
    set -l words (commandline -opc)
    set -l kind
    switch (count $words)
        case 1
            set kind commands
        case 2
            switch $words[2]
                case attach cat kill
                    set kind sessions
                case '*'
                    return
            end
        case '*'
            return
    end
    set -l current (commandline -ct)
    command imx __complete "$kind" "$current"
end

complete -c imx -f -a '(__imx_candidates)'
