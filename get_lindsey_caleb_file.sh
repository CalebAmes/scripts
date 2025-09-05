#!/bin/bash

# Configuration
REMOTE_USER="server"
REMOTE_HOST="spicymini"
REMOTE_DIR="/Volumes/V/spicymini_raid/lindsey_and_caleb"
LOCAL_DIR="$HOME/Downloads"
MAX_RETRIES=10
BASE_DELAY=2 # Base delay in seconds for exponential backoff

# Check if at least one file name is provided
if [[ "$#" -lt 1 ]]; then
  echo "Usage: $0 <file-name-1> [file-name-2 ... file-name-N]"
  echo "Example: $0 myfile1 myfile2 myfile3"
  exit 1
fi

# Function to compute the checksum of a remote file
compute_remote_checksum() {
  local REMOTE_PATH="$1"
  ssh "$REMOTE_USER@$REMOTE_HOST" "md5 -q '$REMOTE_PATH'" 2>/dev/null
}

# Function to download a file with retries and exponential backoff
download_file() {
  local FILE_TO_FIND="$1"
  local retry_count=0

  echo "Searching for '$FILE_TO_FIND' (any extension) on the server..."

  # Search for the file on the server
  if [[ "$FILE_TO_FIND" == *.* ]]; then
    # If the filename contains a dot, assume it's a full filename with an extension
    REMOTE_PATHS=$(ssh "$REMOTE_USER@$REMOTE_HOST" "find '$REMOTE_DIR' -type f -iname '${FILE_TO_FIND}' 2>/dev/null")
  else
    # Otherwise, search for any file with the given base name and any extension
    REMOTE_PATHS=$(ssh "$REMOTE_USER@$REMOTE_HOST" "find '$REMOTE_DIR' -type f -iname '${FILE_TO_FIND}.*' 2>/dev/null")
  fi

  if [[ -z "$REMOTE_PATHS" ]]; then
    echo "File '$FILE_TO_FIND' not found on the server."
    return 1
  fi

  # Convert the list of paths into an array
  IFS=$'\n' read -r -d '' -a REMOTE_PATHS_ARRAY <<< "$REMOTE_PATHS"

  echo "Found ${#REMOTE_PATHS_ARRAY[@]} occurrences of '$FILE_TO_FIND':"
  for path in "${REMOTE_PATHS_ARRAY[@]}"; do
    echo "  - $path"
  done

  # Check if all occurrences have the same checksum
  echo "Verifying file consistency..."
  FIRST_CHECKSUM=$(compute_remote_checksum "${REMOTE_PATHS_ARRAY[0]}")
  ALL_MATCH=true

  for path in "${REMOTE_PATHS_ARRAY[@]}"; do
    CURRENT_CHECKSUM=$(compute_remote_checksum "$path")
    if [[ "$CURRENT_CHECKSUM" != "$FIRST_CHECKSUM" ]]; then
      echo "Checksum mismatch detected:"
      echo "  - ${REMOTE_PATHS_ARRAY[0]} (checksum: $FIRST_CHECKSUM)"
      echo "  - $path (checksum: $CURRENT_CHECKSUM)"
      ALL_MATCH=false
      break
    fi
  done

  if [[ "$ALL_MATCH" == false ]]; then
    echo "Error: Files with the same name but different content found. Aborting download for '$FILE_TO_FIND'."
    return 1
  fi

  echo "All occurrences of '$FILE_TO_FIND' are identical. Proceeding with download..."

  # Pick the first occurrence to download
  REMOTE_PATH="${REMOTE_PATHS_ARRAY[0]}"
  echo "Downloading '$REMOTE_PATH' to $LOCAL_DIR..."

  # Retry loop with exponential backoff
  while [[ $retry_count -lt $MAX_RETRIES ]]; do
    rsync -avz --progress -e ssh "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH" "$LOCAL_DIR/"

    if [[ $? -eq 0 ]]; then
      echo "File '$FILE_TO_FIND' downloaded successfully to $LOCAL_DIR"
      return 0
    else
      ((retry_count++))
      delay=$((BASE_DELAY ** retry_count))
      echo "Download failed (attempt $retry_count of $MAX_RETRIES). Retrying in $delay seconds..."
      sleep $delay
    fi
  done

  echo "Failed to download '$FILE_TO_FIND' after $MAX_RETRIES attempts."
  return 1
}

# Process each file name
for FILE_TO_FIND in "$@"; do
  download_file "$FILE_TO_FIND"
  echo # Blank line for better readability
done