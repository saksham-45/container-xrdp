#!/bin/bash
set -e

# Generate self-signed certificate if it doesn't exist
generate_certificates() {
    if [ ! -f /etc/xrdp/cert.pem ] || [ ! -f /etc/xrdp/key.pem ]; then
        echo "Generating self-signed certificates..."
        openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem -days 365 -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=localhost"
        chmod 600 /etc/xrdp/key.pem
        chown xrdp:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem || true
    fi
}

start_xrdp_services() {
    # Preventing xrdp startup failure
    rm -rf /var/run/xrdp-sesman.pid
    rm -rf /var/run/xrdp.pid
    rm -rf /var/run/xrdp/xrdp-sesman.pid
    rm -rf /var/run/xrdp/xrdp.pid

    # Use exec ... to forward SIGNAL to child processes
    xrdp-sesman
    exec xrdp -n
}

stop_xrdp_services() {
    xrdp --kill
    xrdp-sesman --kill
    exit 0
}

add_user() {
    local username="$1"
    local password="$2"
    local sudo="$3"

    if id -- "$username" &>/dev/null; then
        echo "User '$username' already exists, skipping creation."
        return
    fi

    echo "Adding user '$username'..."
    # Use -- to prevent argument injection
    useradd -m -s /bin/bash -- "$username"
    echo "$username:$password" | chpasswd
    
    if [[ "$sudo" == "yes" ]]; then
        usermod -aG wheel -- "$username"
    fi
    echo "User '$username' is added"
}

echo "Entrypoint script is Running..."
echo

USER_CREATED=false

# 1. Process users from environment variables (Recommended/Secure)
# Format: XRDP_USERS="user1:pass1:yes,user2:pass2:no"
if [ -n "$XRDP_USERS" ]; then
    IFS=',' read -ra ADDR <<< "$XRDP_USERS"
    for user_record in "${ADDR[@]}"; do
        IFS=':' read -ra USER_DATA <<< "$user_record"
        if [ ${#USER_DATA[@]} -eq 3 ]; then
            add_user "${USER_DATA[0]}" "${USER_DATA[1]}" "${USER_DATA[2]}"
            USER_CREATED=true
        else
            echo "Invalid user record in XRDP_USERS: $user_record. Expected user:pass:sudo"
        fi
    done
fi

# 2. Process users from CLI arguments (Legacy/Less Secure)
if [ $# -ne 0 ]; then
    echo "Processing users from CLI arguments..."
    echo "WARNING: Passing passwords via CLI is insecure as they are visible in process lists."
    
    users=$(($#/3))
    mod=$(($# % 3))

    if [[ $mod -ne 0 ]]; then 
        echo "Incorrect input. There should be 3 input parameters per user."
        exit 1
    fi
    
    echo "You entered $users users via CLI"

    while [ $# -ne 0 ]; do
        add_user "$1" "$2" "$3"
        USER_CREATED=true
        shift 3
    done
fi

# If no users were created and we aren't already running as a non-root user that can login
if [ "$USER_CREATED" = false ] && [ "$(id -u)" -eq 0 ]; then
    echo "No users defined via environment variables or CLI arguments, and running as root."
    echo "Please provide at least one user to allow RDP login."
    exit 1
fi

generate_certificates
echo -e "starting xrdp services...\n"

trap "stop_xrdp_services" SIGKILL SIGTERM SIGHUP SIGINT EXIT
start_xrdp_services
