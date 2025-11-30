#!/bin/bash

# Quick aliases for common commands I use
# Repository: https://github.com/Inkrex-dev/inkrex-scripts


# Normal aliases
alias docker-compose='docker compose'

# Function aliases
function docker-enter() {
    if [ -z "$1" ]; then
        echo "Usage: docker-enter <container> [shell]"
        return 1
    fi
    
    local container="$1"
    local shell="${2:-/bin/bash}"
    
    docker exec -it "$container" "$shell" 2>/dev/null || docker exec -it "$container" /bin/sh
}