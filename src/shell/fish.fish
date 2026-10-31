function __imx_install_prompt --on-event fish_prompt
    set -l current (functions fish_prompt)
    if set -q __imx_wrapped_prompt; and test "$current" = "$__imx_wrapped_prompt"
        return
    end
    functions --erase __imx_original_fish_prompt
    functions --copy fish_prompt __imx_original_fish_prompt; or return
    function fish_prompt
        set -l imx_prompt (__imx_original_fish_prompt | string collect --no-trim-newlines)
        if set -q IMX_SESSION; and test -f "$__imx_shell_dir/show-session"
            printf '[%s] ' "$IMX_SESSION"
        end
        printf '%s' "$imx_prompt"
    end
    set -g __imx_wrapped_prompt (functions fish_prompt)
end
