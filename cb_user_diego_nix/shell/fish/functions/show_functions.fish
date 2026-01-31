# Show all defined functions
function show_functions --description 'List custom functions'
    printf "\n\x1b[1;34m=== DEFINED FUNCTIONS ===\x1b[0m\n"
    echo "  mkcd, mkd      - Create directory and cd into it"
    echo "  extract        - Extract any archive format"
    echo "  qfind          - Quick find by filename"
    echo "  backup         - Backup file with timestamp"
    echo "  gcam           - Git add all + commit"
    echo "  gpsh           - Git push to current branch"
    echo "  cpucap         - Show CPU frequency per core"
    echo "  pyp            - Poetry package runner"
    echo "  path           - Show PATH entries"
    echo "  duh            - Disk usage sorted"
    echo "  hg             - History grep"
    echo "  localip        - Show local IP"
    echo "  show_aliases   - List all aliases"
    echo "  show_functions - List all functions"
    echo "  ccusage-models - Claude Code usage stats"
end
