# Help command for shell features
function myhelp --description 'Show shell help with aliases and functions'
    printf "\n\x1b[1;32m##########################\n"
    printf "####### SHELL HELP #######\n"
    printf "##########################\x1b[0m\n"
    show_aliases
    show_functions
    echo ""
end
