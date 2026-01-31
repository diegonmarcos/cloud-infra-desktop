# Disk usage human readable sorted
function duh --description 'Disk usage sorted by size'
    du -h --max-depth=1 | sort -h
end
