function __imx_candidates
    set -l words (commandline -opc)
    set -l kind
    set -l current (commandline -ct)
    if test (count $words) -ge 2; and test "$words[2]" = attach
        set -l ended false
        for word in $words[3..-1]
            test "$ended" = false; or return
            switch $word
                case -r --read-only
                case --
                    set ended true
                case '*'
                    return
            end
        end
        set kind sessions
        if test "$ended" = false; and string match -q -- '-*' "$current"
            set kind options-attach
        end
    else
        switch (count $words)
            case 1
                set kind commands
            case 2
                switch $words[2]
                    case cat kill rename
                        if string match -q -- '-*' "$current"
                            set kind options-$words[2]
                        else
                            set kind sessions
                        end
                    case help
                        set kind help
                    case list ls select detach update uninstall
                        set kind options-$words[2]
                    case '*'
                        return
                end
            case 3
                test "$words[3]" = --; or return
                switch $words[2]
                    case cat kill rename
                        set kind sessions
                    case '*'
                        return
                end
            case '*'
                return
        end
    end
    if test "$kind" = sessions; and test "$words[-1]" != --
        command imx __complete "$kind" "$current" | string match -v -- '-*'
    else
        command imx __complete "$kind" "$current"
    end
end

complete -c imx -f -a '(__imx_candidates)'
