# Get current git branch
function git_current_branch --description 'Get current git branch'
    git branch 2>/dev/null | sed -n '/\* /s///p'
end
