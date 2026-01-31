# Quick find by filename
function qfind --description 'Quick find by filename'
    find . -name "*$argv[1]*"
end
