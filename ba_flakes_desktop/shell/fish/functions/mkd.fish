# Create directory and cd into it (alias for mkcd)
function mkd --description 'Create directory and cd into it'
    mkdir -p $argv; and cd $argv[-1]
end
