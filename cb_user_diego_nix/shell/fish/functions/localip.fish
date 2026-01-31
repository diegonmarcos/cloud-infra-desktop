# Get local IP address
function localip --description 'Show local IP address'
    ip addr show | grep 'inet ' | grep -v 127.0.0.1 | awk '{print $2}'
end
