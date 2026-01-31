# Quick git add all + commit with message
function gcam --description 'Git add all and commit with message'
    git add --all; and git commit -m $argv[1]
end
