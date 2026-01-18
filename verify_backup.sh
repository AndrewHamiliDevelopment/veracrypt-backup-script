#!/bin/bash

# verify_backup.sh
# Verifies that source and destination directories have matching files using SHA256
# Usage: ./verify_backup.sh --source <dir> --destination <dir>

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
        # Get relative path
        local rel_path="${file#$dir/}"
        # Generate hash and store with relative path
        sha256sum "$file" | sed "s|$file|$rel_path|"
    done > "$temp_file"
    
    echo "$temp_file"
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

# Delete all files in destination directory
delete_destination_files() {
    local dest_dir="$1"
    
    warn "Deleting all files from destination: $dest_dir"
    
    if [ -d "$dest_dir" ]; then
        rm -rf "$dest_dir"/*
        info "All files deleted from destination"
    fi
}

# Main script
main() {
    info "=== Backup Verification Tool ==="
    
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
                echo "  -s, --source <directory>        Source directory to verify (required)"
                echo "  -d, --destination <directory>   Destination directory to verify (required)"
                echo "  -h, --help                      Show this help message"
                echo ""
                echo "Description:"
                echo "  This script generates SHA256 hashes for all files in both source and"
                echo "  destination directories and compares them. If the hashes differ, all"
                echo "  files in the destination are deleted and the script exits with status 1."
                echo "  If the hashes match, a success message is displayed and exits with status 0."
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
    
    # Validate destination directory
    if [ ! -d "$DEST_DIR" ]; then
        error_exit "Destination directory does not exist: $DEST_DIR"
    fi
    
    # Check if source directory contains files
    if [ -z "$(find "$SOURCE_DIR" -type f)" ]; then
        error_exit "Source directory is empty (no files found): $SOURCE_DIR"
    fi
    
    # Check if destination directory contains files
    if [ -z "$(find "$DEST_DIR" -type f)" ]; then
        error_exit "Destination directory is empty (no files found): $DEST_DIR"
    fi
    
    # Step 1: Check OS
    check_unix_os
    
    # Step 2: Generate SHA256 hashes for source directory
    SOURCE_HASH_FILE=$(generate_hashes "$SOURCE_DIR")
    info "Source hashes stored in: $SOURCE_HASH_FILE"
    
    # Step 3: Generate SHA256 hashes for destination directory
    DEST_HASH_FILE=$(generate_hashes "$DEST_DIR")
    info "Destination hashes stored in: $DEST_HASH_FILE"
    
    # Step 4: Compare hashes
    if ! compare_hashes "$SOURCE_HASH_FILE" "$DEST_HASH_FILE"; then
        echo -e "\n${RED}Verification FAILED! Files do not match.${NC}"
        
        # Show differences
        echo -e "\n${RED}Differences found:${NC}"
        diff <(sort "$SOURCE_HASH_FILE") <(sort "$DEST_HASH_FILE") || true
        
        # Cleanup temporary hash files
        rm -f "$SOURCE_HASH_FILE" "$DEST_HASH_FILE"
        
        # Delete destination files
        delete_destination_files "$DEST_DIR"
        
        echo -e "\n${RED}Destination files have been deleted due to verification failure.${NC}"
        exit 1
    fi
    
    echo -e "\n${GREEN}Verification PASSED! All files match perfectly.${NC}"
    
    # Cleanup temporary hash files
    rm -f "$SOURCE_HASH_FILE" "$DEST_HASH_FILE"
    
    info "=== Verification completed successfully ==="
    
    exit 0
}

# Run main function
main "$@"
