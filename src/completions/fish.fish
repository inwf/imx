function __imx_candidates
    set -l words (commandline -opc)
    set -l kind
    set -l current (commandline -ct)
    switch (count $words)
        case 1
            set kind commands
        case 2
            switch $words[2]
                case attach cat kill
                    if string match -q -- '-*' "$current"
                        set kind options-$words[2]
                    else
                        set kind sessions
                    end
                case help
                    set kind help
                case list ls detach update uninstall
                    set kind options-$words[2]
                case '*'
                    return
            end
        case 3
            test "$words[3]" = --; or return
            switch $words[2]
                case attach cat kill
                    set kind sessions
                case '*'
                    return
            end
        case '*'
            return
    end
    if test "$kind" = sessions; and test (count $words) -eq 2
        command imx __complete "$kind" "$current" | string match -v -- '-*'
    else
        command imx __complete "$kind" "$current"
    end
end

complete -c imx -f -a '(__imx_candidates)'
