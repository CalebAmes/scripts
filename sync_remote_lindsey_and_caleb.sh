#!/bin/bash

# Directories
EXTERNAL_DRIVE_DIR="/Volumes/T9/lindsey_and_caleb_projects/"
MACHINE_DIR="/Users/calebgilbert/Documents/skip_backup/lindsey_and_caleb_local/projects/"
DEFAULT_DIR="$EXTERNAL_DRIVE_DIR"

# Remote Configuration
REMOTE_USER="server"               # Remote username
REMOTE_HOST="spicymini"            # Remote server address or IP
REMOTE_DIR="/Volumes/V/spicymini_raid/lindsey_and_caleb/2025"
LOCAL_IP="192.168.1.69"                         # Local IP to use with --local
NOTIFY_APP="osascript"             # Notification tool for macOS
TMUX_SESSION_NAME="rsync_sync"     # Tmux session name
MAX_RETRIES=5                      # Maximum number of retries
RETRY_DELAY=10                     # Delay between retries (in seconds)

# Parse arguments
USE_MACHINE=false
USE_TMUX=false
USE_DIRECT=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --machine) USE_MACHINE=true ;;    # Use MACHINE_DIR
        --tmux) USE_TMUX=true ;;          # Enable tmux
        --local) REMOTE_HOST="$LOCAL_IP" ;; # Use local IP for remote host
        --direct) USE_DIRECT=true ;;      # Run locally on spicymini to the mounted drive
        --help) echo "Usage: $(basename "$0") [--machine] [--tmux] [--local] [--direct]"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# Set the source directory
if $USE_MACHINE; then
    SOURCE_DIR="$MACHINE_DIR"
else
    SOURCE_DIR="$EXTERNAL_DRIVE_DIR"
fi

# Function to send macOS notifications
send_notification() {
    TITLE="$1"
    MESSAGE="$2"
    $NOTIFY_APP -e "display notification \"$MESSAGE\" with title \"$TITLE\""
}

# Check if the source directory exists
check_source_dir() {
    if [ ! -d "$SOURCE_DIR" ]; then
        send_notification "Source Directory Missing" "The source directory $SOURCE_DIR does not exist."
        echo "[$(date)] Source directory $SOURCE_DIR not found."
        exit 1
    fi
}

# Check if remote service is reachable
check_remote_service() {
    ssh -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_HOST" exit 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "[$(date)] Remote service not reachable at $REMOTE_HOST. Retrying..."
        return 1
    fi
    return 0
}

# Check for "Broken pipe" errors in the log file
check_for_broken_pipe() {
    # Logging removed; cannot scan log file for 'Broken pipe'.
    # Keep the function for compatibility but make it a no-op.
    return 0
}

# Rsync command with retry logic
rsync_command() {
    local retries=0
    local success=false

    if $USE_DIRECT; then
        DEST_DISPLAY="$REMOTE_DIR"
    else
        DEST_DISPLAY="$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"
    fi

    send_notification "Sync Started" "Syncing $SOURCE_DIR to $DEST_DISPLAY"
    echo "[$(date)] Sync started: $SOURCE_DIR -> $DEST_DISPLAY"

    while [[ $retries -lt $MAX_RETRIES ]]; do
        echo "Attempt $(($retries + 1)) of $MAX_RETRIES..."

        # Run rsync
        if $USE_DIRECT; then
            rsync -av --progress --ignore-existing --exclude='.DS_Store' \
                "$SOURCE_DIR" "$REMOTE_DIR" 2>&1 | tee
        else
            rsync -av --progress --ignore-existing --exclude='.DS_Store' \
                -e "ssh" "$SOURCE_DIR" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR" 2>&1 | tee
        fi

        # Capture rsync exit code
        local rsync_exit_code=${PIPESTATUS[0]}

        # Check for success or "Broken pipe"
        if [ $rsync_exit_code -eq 0 ]; then
            success=true
            break
        else
            if ! $USE_DIRECT; then
                if ! check_remote_service || check_for_broken_pipe; then
                    echo "[$(date)] Service not reachable or 'Broken pipe' error detected. Retrying in $RETRY_DELAY seconds..."
                else
                    echo "[$(date)] Rsync failed with exit code $rsync_exit_code. Retrying in $RETRY_DELAY seconds..."
                fi
            else
                echo "[$(date)] Rsync failed with exit code $rsync_exit_code. Retrying in $RETRY_DELAY seconds..."
            fi
        fi

        sleep $RETRY_DELAY
        ((retries++))
    done

    if $success; then
        send_notification "Sync Complete" "All missing files have been copied successfully!"
        echo "[$(date)] Sync completed successfully."
    else
        send_notification "Sync Failed" "All retries failed. Please check the output."
        echo "[$(date)] Sync failed after $MAX_RETRIES attempts."
        exit 1
    fi
}

# Run the script
check_source_dir

if $USE_TMUX; then
    if command -v tmux &> /dev/null; then
        # Check if the tmux session already exists
        if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
            echo "Tmux session '$TMUX_SESSION_NAME' already exists. Attaching..."
            tmux attach-session -t "$TMUX_SESSION_NAME"
            exit
        fi

        echo "Launching rsync in a tmux session: $TMUX_SESSION_NAME"
        echo "[$(date)] Launched in tmux session: $TMUX_SESSION_NAME"

        # Start tmux session and run the command
        tmux new-session -d -s "$TMUX_SESSION_NAME" bash -c "$(declare -f rsync_command send_notification check_remote_service check_for_broken_pipe); rsync_command"
        echo "Rsync is running in tmux session: $TMUX_SESSION_NAME"
    else
        echo "tmux is not installed. Running rsync directly in this shell."
        rsync_command
    fi
else
    echo "Running rsync directly in this shell."
    rsync_command
fi