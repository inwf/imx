set -g fish_greeting
fish_default_key_bindings
function fish_prompt
    printf 'COMPLETION> '
end

function __imx_test_capture
    commandline -b > "$IMX_TEST_SHELL_BUFFER"
end
bind \co __imx_test_capture
