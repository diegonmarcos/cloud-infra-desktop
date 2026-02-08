# Show all defined aliases
function show_aliases --description 'List all defined aliases'
    printf "\n\x1b[1;34m=== DEFINED ALIASES ===\x1b[0m\n"
    alias | sed 's/^/  /' | sort
end
