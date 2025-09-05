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
LOG_FILE="$HOME/scripts/logs/rsync_sync.log"    # Log file location
NOTIFY_APP="osascript"             # Notification tool for macOS
TMUX_SESSION_NAME="rsync_sync"     # Tmux session name
MAX_RETRIES=5                      # Maximum number of retries
RETRY_DELAY=10                     # Delay between retries (in seconds)

# Parse arguments
USE_MACHINE=false
USE_TMUX=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --machine) USE_MACHINE=true ;;    # Use MACHINE_DIR
        --tmux) USE_TMUX=true ;;          # Enable tmux
        --local) REMOTE_HOST="$LOCAL_IP" ;; # Use local IP for remote host
        --help) echo "Usage: $(basename "$0") [--machine] [--tmux] [--local]"; exit 0 ;;
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
        echo "[$(date)] Source directory $SOURCE_DIR not found." >> "$LOG_FILE"
        exit 1
    fi
}

# Check if remote service is reachable
check_remote_service() {
    ssh -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_HOST" exit 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "[$(date)] Remote service not reachable at $REMOTE_HOST. Retrying..." | tee -a "$LOG_FILE"
        return 1
    fi
    return 0
}

# Check for "Broken pipe" errors in the log file
check_for_broken_pipe() {
    if grep -q "Broken pipe" "$LOG_FILE"; then
        echo "[$(date)] Detected 'Broken pipe' error in log. Triggering retry..." | tee -a "$LOG_FILE"
        return 1
    fi
    return 0
}

# Rsync command with retry logic
rsync_command() {
    local retries=0
    local success=false

    send_notification "Sync Started" "Syncing $SOURCE_DIR to $REMOTE_HOST"
    echo "[$(date)] Sync started: $SOURCE_DIR -> $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR" >> "$LOG_FILE"

    while [[ $retries -lt $MAX_RETRIES ]]; do
        echo "Attempt $(($retries + 1)) of $MAX_RETRIES..." | tee -a "$LOG_FILE"

        # Run rsync
        rsync -av --progress --ignore-existing --exclude='.DS_Store' \
            -e "ssh" "$SOURCE_DIR" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR" 2>&1 | tee -a "$LOG_FILE"

        # Capture rsync exit code
        local rsync_exit_code=${PIPESTATUS[0]}

        # Check for success or "Broken pipe"
        if [ $rsync_exit_code -eq 0 ]; then
            success=true
            break
        elif ! check_remote_service || check_for_broken_pipe; then
            echo "[$(date)] Service not reachable or 'Broken pipe' error detected. Retrying in $RETRY_DELAY seconds..." | tee -a "$LOG_FILE"
        else
            echo "[$(date)] Rsync failed with exit code $rsync_exit_code. Retrying in $RETRY_DELAY seconds..." | tee -a "$LOG_FILE"
        fi

        sleep $RETRY_DELAY
        ((retries++))
    done

    if $success; then
        send_notification "Sync Complete" "All missing files have been copied successfully!"
        echo "[$(date)] Sync completed successfully." >> "$LOG_FILE"
    else
        send_notification "Sync Failed" "All retries failed. Please check the logs."
        echo "[$(date)] Sync failed after $MAX_RETRIES attempts. Check the log file: $LOG_FILE" >> "$LOG_FILE"
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
        echo "[$(date)] Launched in tmux session: $TMUX_SESSION_NAME" >> "$LOG_FILE"

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