#!/bin/bash

# backup_verified.sh
# Copies files from source to destination with SHA256 integrity verification
# Usage: ./backup_verified.sh --source <dir> --destination <dir>

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print error messages
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

# Function to print info messages
info() {
    echo -e "${GREEN}INFO: $1${NC}"
}

# Function to print warning messages
warn() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

# Check if OS is Unix-based
check_unix_os() {
    if [[ "$OSTYPE" != "linux-gnu"* && "$OSTYPE" != "darwin"* && "$OSTYPE" != "freebsd"* ]]; then
        error_exit "This script requires a Unix-based operating system (Linux, macOS, or FreeBSD). Current OS: $OSTYPE"
    fi
    info "Unix-based OS detected: $OSTYPE"
}

# Generate SHA256 hashes for all files in a directory
generate_hashes() {
    local dir="$1"
    local temp_file=$(mktemp)
    
    info "Generating SHA256 hashes for: $dir" >&2
    
    # Find all files (not directories) and generate SHA256 hash, excluding hidden files/folders
    find "$dir" -type f -not -path '*/.*' -print0 | sort -z | while IFS= read -r -d '' file; do
        # Get file name only
        local base_name="$(basename "$file")"
        # Generate hash and store with file name only
        sha256sum "$file" | sed "s|$file|$base_name|"
    done > "$temp_file"
    
    echo "$temp_file"
}

# Get total size of directory in bytes
get_directory_size() {
    local dir="$1"
    
    info "Calculating directory size: $dir" >&2
    
    # Get size in bytes (works on both Linux and macOS)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        local size=$(find "$dir" -type f -exec stat -f%z {} \; | awk '{sum+=$1} END {print sum}')
    else
        # Linux
        local size=$(du -sb "$dir" | cut -f1)
    fi
    
    echo "$size"
}

# Get available space at destination in bytes
get_available_space() {
    local dir="$1"
    
    info "Checking available space at: $dir" >&2
    
    # Get available space in bytes (works on both Linux and macOS)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - use df with -k and convert to bytes
        local avail_kb=$(df -k "$dir" | tail -1 | awk '{print $4}')
        local avail_bytes=$((avail_kb * 1024))
    else
        # Linux - use df with --output
        local avail_bytes=$(df --output=avail -B1 "$dir" | tail -1 | tr -d ' ')
    fi
    
    echo "$avail_bytes"
}

# Check if destination has enough space
check_destination_space() {
    local source_size="$1"
    local dest_dir="$2"
    
    local available_space=$(get_available_space "$dest_dir")
    
    # Add 10% buffer to source size for safety
    local required_space=$((source_size + source_size / 10))
    
    info "Source size: $source_size bytes ($(( source_size / 1048576 ))MB)"
    info "Required space (with 10% buffer): $required_space bytes ($(( required_space / 1048576 ))MB)"
    info "Available space: $available_space bytes ($(( available_space / 1048576 ))MB)"
    
    if [ "$available_space" -lt "$required_space" ]; then
        error_exit "Insufficient space at destination. Required: $(( required_space / 1048576 ))MB, Available: $(( available_space / 1048576 ))MB"
    fi
    
    info "Destination has sufficient space"
}

# Copy files using rsync
copy_files_rsync() {
    local source="$1"
    local destination="$2"
    
    info "Copying files from $source to $destination"
    
    # Use rsync with archive mode (preserves permissions, timestamps, etc.)
    rsync -avh --progress "$source/" "$destination/" \
        || error_exit "Failed to copy files with rsync"
    
    info "Files copied successfully"
}

# Compare two hash files
compare_hashes() {
    local hash_file1="$1"
    local hash_file2="$2"
    
    info "Comparing SHA256 hashes"
    
    # Sort both files and compare
    if diff <(sort "$hash_file1") <(sort "$hash_file2") > /dev/null; then
        return 0  # Hashes match
    else
        return 1  # Hashes differ
    fi
}

# Cleanup on failure
cleanup_on_failure() {
    local destination="$1"
    
    warn "Hash verification failed! Cleaning up..."
    
    # Delete all files from destination
    if [ -d "$destination" ]; then
        info "Deleting files from $destination"
        rm -rf "$destination"/*
    fi
}

# Main script
main() {
    info "=== Backup with Integrity Verification ==="
    
    # Initialize variables
    SOURCE_DIR=""
    DEST_DIR=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --source|-s)
                SOURCE_DIR="$2"
                shift 2
                ;;
            --destination|-d)
                DEST_DIR="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 --source <directory> --destination <directory>"
                echo ""
                echo "Options:"
                echo "  -s, --source <directory>        Directory containing files to backup (required)"
                echo "  -d, --destination <directory>   Directory where files will be copied (required)"
                echo "  -h, --help                      Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0 --source /data --destination /backup"
                echo "  $0 -s /data -d /backup"
                exit 0
                ;;
            *)
                error_exit "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
    
    # Validate required arguments
    if [ -z "$SOURCE_DIR" ]; then
        error_exit "Missing required argument: --source. Use --help for usage information."
    fi
    
    if [ -z "$DEST_DIR" ]; then
        error_exit "Missing required argument: --destination. Use --help for usage information."
    fi
    
    # Validate source directory
    if [ ! -d "$SOURCE_DIR" ]; then
        error_exit "Source directory does not exist: $SOURCE_DIR"
    fi
    
    # Check if source directory contains files
    if [ -z "$(find "$SOURCE_DIR" -type f)" ]; then
        error_exit "Source directory is empty (no files found): $SOURCE_DIR"
    fi
    
    # Create destination directory if it doesn't exist
    mkdir -p "$DEST_DIR"
    
    # Step 1: Check OS
    check_unix_os
    
    # Step 2: Generate SHA256 hashes for source directory
    SOURCE_HASH_FILE=$(generate_hashes "$SOURCE_DIR")
    info "Source hashes stored in: $SOURCE_HASH_FILE"
    
    # Step 3: Get source directory size
    SOURCE_SIZE=$(get_directory_size "$SOURCE_DIR")
    info "Source directory size: $SOURCE_SIZE bytes ($(( SOURCE_SIZE / 1048576 ))MB)"
    
    # Step 4: Check if destination has enough space
    check_destination_space "$SOURCE_SIZE" "$DEST_DIR"
    
    # Step 5: Copy files using rsync
    copy_files_rsync "$SOURCE_DIR" "$DEST_DIR"
    
    # Step 6: Generate SHA256 hashes for destination directory
    DEST_HASH_FILE=$(generate_hashes "$DEST_DIR")
    info "Destination hashes stored in: $DEST_HASH_FILE"
    
    # Step 7: Compare hashes
    if ! compare_hashes "$SOURCE_HASH_FILE" "$DEST_HASH_FILE"; then
        echo -e "${RED}ERROR: Hash verification FAILED! Files do not match.${NC}"
        echo -e "\n${RED}Detailed differences:${NC}"
        # Show a summary of missing, extra, and mismatched files
        awk '{print $2" "$1}' "$SOURCE_HASH_FILE" | sort > /tmp/source_hash_sorted.txt
        awk '{print $2" "$1}' "$DEST_HASH_FILE" | sort > /tmp/dest_hash_sorted.txt

        # Find files missing in destination
        comm -23 <(awk '{print $1}' /tmp/source_hash_sorted.txt) <(awk '{print $1}' /tmp/dest_hash_sorted.txt) > /tmp/missing_in_dest.txt
        # Find files extra in destination
        comm -13 <(awk '{print $1}' /tmp/source_hash_sorted.txt) <(awk '{print $1}' /tmp/dest_hash_sorted.txt) > /tmp/extra_in_dest.txt
        # Find files with mismatched hashes
        join -j 1 /tmp/source_hash_sorted.txt /tmp/dest_hash_sorted.txt | awk '$2 != $3 {print $1}' > /tmp/mismatched_hashes.txt

        if [ -s /tmp/missing_in_dest.txt ]; then
            echo -e "${YELLOW}Files present in source but missing in destination:${NC}"
            cat /tmp/missing_in_dest.txt
        fi
        if [ -s /tmp/extra_in_dest.txt ]; then
            echo -e "${YELLOW}Files present in destination but missing in source:${NC}"
            cat /tmp/extra_in_dest.txt
        fi
        if [ -s /tmp/mismatched_hashes.txt ]; then
            echo -e "${YELLOW}Files with mismatched hashes:${NC}"
            cat /tmp/mismatched_hashes.txt
        fi

        # Show raw diff for reference
        echo -e "\n${YELLOW}Raw diff output:${NC}"
        diff <(sort "$SOURCE_HASH_FILE") <(sort "$DEST_HASH_FILE") || true

        # Cleanup temporary hash files
        rm -f "$SOURCE_HASH_FILE" "$DEST_HASH_FILE"
        rm -f /tmp/source_hash_sorted.txt /tmp/dest_hash_sorted.txt /tmp/missing_in_dest.txt /tmp/extra_in_dest.txt /tmp/mismatched_hashes.txt

        # Cleanup and exit with status 1
        cleanup_on_failure "$DEST_DIR"
        exit 1
    fi
    
    info "Hash verification PASSED! All files match perfectly."
    
    # Cleanup temporary hash files
    rm -f "$SOURCE_HASH_FILE" "$DEST_HASH_FILE"
    
    info "=== Backup completed successfully ==="
    info "Destination location: $DEST_DIR"
    
    exit 0
}

# Run main function
main "$@"
