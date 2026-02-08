# Print PATH with newlines
function path --description 'Print PATH entries on separate lines'
    echo $PATH | tr ' ' '\n'
end
