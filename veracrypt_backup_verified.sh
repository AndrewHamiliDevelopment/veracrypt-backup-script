#!/bin/bash

# veracrypt_backup_verified.sh
# Creates a VeraCrypt container backup with SHA256 integrity verification
# Usage: ./veracrypt_backup_verified.sh --source <dir> [--destination <dir>] [--password <pass>] [--keyfile <file>]
# Note: Either --password or --keyfile (or both) must be provided
# Note: Containers are stored in /mnt by default (use --destination to override)

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

# Check if VeraCrypt is installed
check_veracrypt_installed() {
    if ! command -v veracrypt &> /dev/null; then
        error_exit "VeraCrypt is not installed or not in PATH"
    fi
    info "VeraCrypt is installed: $(command -v veracrypt)"
}

# Check if script has root privileges
check_root_privileges() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script requires root privileges. Please run with sudo."
    fi
    info "Running with root privileges"
}

# Generate SHA256 hashes for all files in a directory
generate_hashes() {
    local dir="$1"
    local temp_file=$(mktemp)
    
    info "Generating SHA256 hashes for: $dir"
    
    # Find all files (not directories) and generate SHA256 hash
    find "$dir" -type f -print0 | sort -z | while IFS= read -r -d '' file; do
        # Get relative path
        local rel_path="${file#$dir/}"
        # Generate hash and store with relative path
        sha256sum "$file" | sed "s|$file|$rel_path|"
    done > "$temp_file"
    
    echo "$temp_file"
}

# Get total size of directory in bytes
get_directory_size() {
    local dir="$1"
    
    info "Calculating directory size: $dir"
    
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

# Create VeraCrypt container
create_veracrypt_container() {
    local container_path="$1"
    local size_bytes="$2"
    local password="$3"
    local keyfile="$4"
    
    # Add 128MB (134217728 bytes) to the size
    local total_size=$((size_bytes + 134217728))
    
    # Convert to MB for VeraCrypt (round up)
    local size_mb=$(( (total_size + 1048575) / 1048576 ))
    
    info "Creating VeraCrypt container: $container_path (Size: ${size_mb}MB)"
    
    # Create the container
    veracrypt --text --create "$container_path" \
        --size="${size_mb}M" \
        --password="$password" \
        --encryption=AES \
        --hash=SHA-512 \
        --filesystem=ext4 \
        --pim=0 \
        --keyfiles="$keyfile" \
        --random-source=/dev/urandom \
        || error_exit "Failed to create VeraCrypt container"
    
    info "VeraCrypt container created successfully"
}

# Mount VeraCrypt container
mount_veracrypt_container() {
    local container_path="$1"
    local mount_point="$2"
    local password="$3"
    local keyfile="$4"
    
    info "Mounting VeraCrypt container to: $mount_point"
    
    # Create mount point if it doesn't exist
    sudo mkdir -p "$mount_point"
    
    # Mount the container
    echo "$password" | veracrypt --text \
        --mount "$container_path" \
        "$mount_point" \
        --password="$password" \
        --pim=0 \
        --keyfiles="$keyfile" \
        --protect-hidden=no \
        || error_exit "Failed to mount VeraCrypt container"
    
    # Change ownership to current user
    sudo chown -R $(whoami):$(id -gn) "$mount_point"
    
    info "VeraCrypt container mounted successfully"
}

# Dismount VeraCrypt container
dismount_veracrypt_container() {
    local mount_point="$1"
    
    info "Dismounting VeraCrypt container from: $mount_point"
    
    veracrypt --text --dismount "$mount_point" \
        || warn "Failed to dismount VeraCrypt container (it may not be mounted)"
    
    info "VeraCrypt container dismounted"
}

# Copy files using rsync
copy_files_rsync() {
    local source="$1"
    local destination="$2"
    
    info "Copying files from $source to $destination"
    
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
    local mount_point="$1"
    local container_path="$2"
    
    warn "Hash verification failed! Cleaning up..."
    
    # Delete all files from mount point
    if [ -d "$mount_point" ]; then
        info "Deleting files from $mount_point"
        sudo rm -rf "$mount_point"/*
    fi
    
    # Dismount container
    dismount_veracrypt_container "$mount_point"
    
    # Optionally delete the container file
    if [ -f "$container_path" ]; then
        info "Deleting VeraCrypt container: $container_path"
        rm -f "$container_path"
    fi
}

# Main script
main() {
    info "=== VeraCrypt Backup with Integrity Verification ==="
    
    # Initialize variables
    SOURCE_DIR=""
    DEST_DIR=""
    PASSWORD=""
    KEYFILE=""
    CONTAINER_NAME=""
    
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
            --password|-p)
                PASSWORD="$2"
                shift 2
                ;;
            --keyfile|-k)
                KEYFILE="$2"
                shift 2
                ;;
            --container-name|-n)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 --source <directory> [--destination <directory>] [--password <password>] [--keyfile <file>] [--container-name <name>]"
                echo ""
                echo "Options:"
                echo "  -s, --source <directory>        Directory containing files to backup (required)"
                echo "  -d, --destination <directory>   Directory where container will be stored (optional, default: /mnt)"
                echo "  -p, --password <password>       Password for the VeraCrypt container (optional)"
                echo "  -k, --keyfile <file>            Path to keyfile(s) - comma-separated for multiple (optional)"
                echo "  -n, --container-name <name>     Custom name for the container file (optional)"
                echo "  -h, --help                      Show this help message"
                echo ""
                echo "Note: Either --password or --keyfile (or both) must be provided."
                echo "Note: If --destination is not provided, containers are stored in /mnt"
                echo "Note: If --container-name is not provided, the source directory name will be used."
                echo "      Spaces in names are replaced with dashes."
                echo ""
                echo "Examples:"
                echo "  sudo $0 --source /data --password 'MyPass123'"
                echo "  sudo $0 --source /data --destination /backup --password 'MyPass123'"
                echo "  sudo $0 --source /data --keyfile /path/to/key.key"
                echo "  sudo $0 -s /data -d /backup -p 'MyPass123' -k /key.key"
                echo "  sudo $0 --source /data --destination /mnt/pool --keyfile key1.key,key2.key"
                echo "  sudo $0 --source /data --password 'MyPass' --container-name mybackup"
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
    
    # Validate that at least password or keyfile is provided
    if [ -z "$PASSWORD" ] && [ -z "$KEYFILE" ]; then
        error_exit "Either --password or --keyfile (or both) must be provided. Use --help for usage information."
    fi
    
    # Set default destination directory if not provided
    if [ -z "$DEST_DIR" ]; then
        DEST_DIR="/mnt"
        info "Destination not specified, using default: /mnt"
    fi
    
    # Generate container name if not provided
    if [ -z "$CONTAINER_NAME" ]; then
        # Get basename of source directory and replace spaces with dashes
        CONTAINER_NAME=$(basename "$SOURCE_DIR" | tr ' ' '-')
        info "Container name not specified, using source directory name: $CONTAINER_NAME"
    else
        # Replace spaces with dashes in provided name
        CONTAINER_NAME=$(echo "$CONTAINER_NAME" | tr ' ' '-')
    fi
    
    MOUNT_POINT="/mnt/vera"
    CONTAINER_FILE="${CONTAINER_NAME}_$(date +%Y%m%d_%H%M%S).vc"
    CONTAINER_PATH="$DEST_DIR/$CONTAINER_FILE"
    
    # Check root privileges early
    check_root_privileges
    
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
    
    # Validate keyfile if provided
    if [ -n "$KEYFILE" ]; then
        info "Validating keyfile(s)..."
        
        # Split comma-separated keyfiles and validate each one
        IFS=',' read -ra KEYFILE_ARRAY <<< "$KEYFILE"
        for kf in "${KEYFILE_ARRAY[@]}"; do
            # Trim whitespace
            kf=$(echo "$kf" | xargs)
            
            # Check if it's a directory
            if [ -d "$kf" ]; then
                error_exit "Keyfile cannot be a directory: $kf"
            fi
            
            # Check if file exists
            if [ ! -f "$kf" ]; then
                error_exit "Keyfile does not exist: $kf"
            fi
            
            info "Keyfile validated: $kf"
        done
        
        info "Using keyfile(s): $KEYFILE"
    fi
    
    # Step 1: Check OS
    check_unix_os
    
    # Step 2: Check VeraCrypt installation
    check_veracrypt_installed
    
    # Step 3: Generate SHA256 hashes for source directory
    SOURCE_HASH_FILE=$(generate_hashes "$SOURCE_DIR")
    info "Source hashes stored in: $SOURCE_HASH_FILE"
    
    # Step 4: Get source directory size
    SOURCE_SIZE=$(get_directory_size "$SOURCE_DIR")
    info "Source directory size: $SOURCE_SIZE bytes ($(( SOURCE_SIZE / 1048576 ))MB)"
    
    # Step 5: Create and mount VeraCrypt container
    create_veracrypt_container "$CONTAINER_PATH" "$SOURCE_SIZE" "$PASSWORD" "$KEYFILE"
    mount_veracrypt_container "$CONTAINER_PATH" "$MOUNT_POINT" "$PASSWORD" "$KEYFILE"
    
    # Step 6: Copy files using rsync
    copy_files_rsync "$SOURCE_DIR" "$MOUNT_POINT"
    
    # Step 7: Generate SHA256 hashes for mounted directory
    MOUNT_HASH_FILE=$(generate_hashes "$MOUNT_POINT")
    info "Mount point hashes stored in: $MOUNT_HASH_FILE"
    
    # Step 8: Compare hashes
    if ! compare_hashes "$SOURCE_HASH_FILE" "$MOUNT_HASH_FILE"; then
        error "Hash verification FAILED! Files do not match."
        
        # Show differences
        echo -e "\n${RED}Differences found:${NC}"
        diff <(sort "$SOURCE_HASH_FILE") <(sort "$MOUNT_HASH_FILE") || true
        
        # Cleanup temporary hash files
        rm -f "$SOURCE_HASH_FILE" "$MOUNT_HASH_FILE"
        
        # Cleanup and exit with status 1
        cleanup_on_failure "$MOUNT_POINT" "$CONTAINER_PATH"
        exit 1
    fi
    
    info "Hash verification PASSED! All files match perfectly."
    
    # Cleanup temporary hash files
    rm -f "$SOURCE_HASH_FILE" "$MOUNT_HASH_FILE"
    
    # Step 9: Dismount and exit successfully
    dismount_veracrypt_container "$MOUNT_POINT"
    
    info "=== Backup completed successfully ==="
    info "Container location: $CONTAINER_PATH"
    
    exit 0
}

# Run main function
main "$@"
