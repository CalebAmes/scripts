#!/bin/bash

# === CONFIGURATION ===
SOURCE_DIR="/Volumes/T9/stock_footage/2_trimmed"
DEST_DIR="/Volumes/T9/stock_footage/3_processed"
LOG_DIR="/Volumes/T9/stock_footage/4_logs"

SUCCESS_LOG="$LOG_DIR/success.log"
SKIPPED_LOG="$LOG_DIR/skipped.log"
ERROR_LOG="$LOG_DIR/error.log"

DRY_RUN=false
NO_DELETE=false

# Supported video extensions (case-insensitive)
SUPPORTED_EXTENSIONS=("mp4" "mov" "mkv" "avi" "m4v" "webm")

# Array to store files to delete later
declare -a FILES_TO_DELETE

# === FUNCTIONS ===

log() {
    local message="$1"
    local log_file="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" | tee -a "$log_file"
}

notify() {
    local title="$1"
    local message="$2"
    osascript -e "display notification \"$message\" with title \"$title\""
}

is_supported_file() {
    local file="$1"
    local extension="${file##*.}"
    extension=$(echo "$extension" | tr '[:upper:]' '[:lower:]')

    for ext in "${SUPPORTED_EXTENSIONS[@]}"; do
        if [[ "$extension" == "$ext" ]]; then
            return 0
        fi
    done

    return 1
}

process_file() {
    local src_file="$1"
    local relative_path="${src_file#$SOURCE_DIR/}"
    local dest_file="$DEST_DIR/${relative_path%.*}_processed.${relative_path##*.}"
    local dest_folder
    dest_folder=$(dirname "$dest_file")

    # Ensure file type is supported
    if ! is_supported_file "$src_file"; then
        log "SKIPPED: Unsupported file type: $src_file" "$SKIPPED_LOG"
        return
    fi

    # Ensure destination folder exists
    mkdir -p "$dest_folder"

    # Check for conflicts
    if [ -e "$dest_file" ]; then
        log "SKIPPED: $dest_file already exists." "$SKIPPED_LOG"
        return
    fi

    # Validate file type with FFmpeg
    if ! ffmpeg -i "$src_file" -hide_banner 2>&1 | grep -q "Duration"; then
        log "ERROR: Unsupported or unreadable file: $src_file" "$ERROR_LOG"
        return
    fi

    # Dry run simulation
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would process $src_file → $dest_file" "$SUCCESS_LOG"
        return
    fi

    # Process the file
    ffmpeg -i "$src_file" -c copy -an "$dest_file" -hide_banner -loglevel error
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to process $src_file" "$ERROR_LOG"
        return
    fi

    # Validate the processed file
    if [ -e "$dest_file" ]; then
        log "SUCCESS: $src_file → $dest_file" "$SUCCESS_LOG"
        FILES_TO_DELETE+=("$src_file")
    else
        log "ERROR: Processed file not found after processing: $dest_file" "$ERROR_LOG"
    fi
}

delete_files() {
    if [ "$NO_DELETE" = true ]; then
        log "SKIPPED: File deletion disabled with --no-delete flag." "$SUCCESS_LOG"
        return
    fi

    log "STARTING FILE DELETION..." "$SUCCESS_LOG"

    for file in "${FILES_TO_DELETE[@]}"; do
        if [ -f "$file" ]; then
            rm "$file"
            log "DELETED: $file" "$SUCCESS_LOG"
        else
            log "SKIPPED: File not found for deletion: $file" "$SKIPPED_LOG"
        fi
    done

    log "FILE DELETION COMPLETE." "$SUCCESS_LOG"
}

delete_empty_dirs() {
    if [ "$NO_DELETE" = true ]; then
        log "SKIPPED: Directory cleanup disabled with --no-delete flag." "$SUCCESS_LOG"
        return
    fi

    log "STARTING EMPTY DIRECTORY CLEANUP..." "$SUCCESS_LOG"

    # Remove empty directories recursively
    find "$SOURCE_DIR" -type d -empty -print -delete | while IFS= read -r dir; do
        log "DELETED EMPTY DIR: $dir" "$SUCCESS_LOG"
    done

    log "EMPTY DIRECTORY CLEANUP COMPLETE." "$SUCCESS_LOG"
}

# === SCRIPT EXECUTION ===

# Parse flags
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true ;;
        --no-delete) NO_DELETE=true ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# Ensure log directory exists
mkdir -p "$LOG_DIR"
touch "$SUCCESS_LOG" "$SKIPPED_LOG" "$ERROR_LOG"

log "STARTING PROCESSING: $SOURCE_DIR → $DEST_DIR" "$SUCCESS_LOG"

# Gather all files into an array
declare -a ALL_FILES
while IFS= read -r -d '' file; do
    ALL_FILES+=("$file")
done < <(find "$SOURCE_DIR" -type f -print0)

# Process each file from the array
for file in "${ALL_FILES[@]}"; do
    process_file "$file"
done

# Delete processed files at the end
delete_files

# Remove empty directories
delete_empty_dirs

log "PROCESSING COMPLETE." "$SUCCESS_LOG"
notify "Stock Footage Script" "Processing Complete!"