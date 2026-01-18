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

# Check if destination has enough space for container
check_destination_space() {
    local source_size="$1"
    local dest_dir="$2"
    
    local available_space=$(get_available_space "$dest_dir")
    
    # Container size will be source_size + 256MB
    local container_size=$((source_size + 268435456))
    
    # Add 10% buffer to container size for safety
    local required_space=$((container_size + container_size / 10))
    
    info "Source size: $source_size bytes ($(( source_size / 1048576 ))MB)"
    info "Container size: $container_size bytes ($(( container_size / 1048576 ))MB)"
    info "Required space (with 10% buffer): $required_space bytes ($(( required_space / 1048576 ))MB)"
    info "Available space: $available_space bytes ($(( available_space / 1048576 ))MB)"
    
    if [ "$available_space" -lt "$required_space" ]; then
        error_exit "Insufficient space at destination. Required: $(( required_space / 1048576 ))MB, Available: $(( available_space / 1048576 ))MB"
    fi
    
    info "Destination has sufficient space"
}

# Create VeraCrypt container
create_veracrypt_container() {
    local container_path="$1"
    local size_bytes="$2"
    local password="$3"
    local keyfile="$4"
    
    # Add 256MB (268435456 bytes) to the size
    local total_size=$((size_bytes + 268435456))
    
    # Convert to MB for VeraCrypt (round up)
    local size_mb=$(( (total_size + 1048575) / 1048576 ))
    
    info "Creating VeraCrypt container: $container_path (Size: ${size_mb}MB)"
    
    # Create the container
    veracrypt --text --create "$container_path" \
        --size="${size_mb}M" \
        --password="$password" \
        --encryption=AES \
        --hash=SHA-512 \
        --filesystem=exfat \
        --pim=0 \
        --keyfiles="$keyfile" \
        --random-source=/dev/urandom \
        --volume-type=normal \
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
    
    # Change ownership to current user (ignore errors for filesystems like exFAT that don't support it)
    sudo chown -R $(whoami):$(id -gn) "$mount_point" 2>/dev/null || true
    
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
    
    # Use rsync with timestamp preservation but without ownership/permissions for exFAT compatibility
        find "$dir" -type f -print0 | sort -z | while IFS= read -r -d '' file; do
            # Get file name only
            local base_name="$(basename "$file")"
            # Generate hash and store with file name only
            sha256sum "$file" | sed "s|$file|$base_name|"
        done > "$temp_file"
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
    
    # Step 5: Check if destination has enough space
    check_destination_space "$SOURCE_SIZE" "$DEST_DIR"
    
    # Step 6: Create and mount VeraCrypt container
    create_veracrypt_container "$CONTAINER_PATH" "$SOURCE_SIZE" "$PASSWORD" "$KEYFILE"
    mount_veracrypt_container "$CONTAINER_PATH" "$MOUNT_POINT" "$PASSWORD" "$KEYFILE"
    
    # Step 6: Copy files using rsync
    copy_files_rsync "$SOURCE_DIR" "$MOUNT_POINT"
    
    # Step 7: Generate SHA256 hashes for mounted directory
    MOUNT_HASH_FILE=$(generate_hashes "$MOUNT_POINT")
    info "Mount point hashes stored in: $MOUNT_HASH_FILE"
    
    # Step 9: Compare hashes
    if ! compare_hashes "$SOURCE_HASH_FILE" "$MOUNT_HASH_FILE"; then
Raw diff output:
1,170c1,170
< 000917a5d5521f8e2570f8092a51a295c4d4c567489f336ccf83978f152c2ce9  /mnt/files/CANON/EOS_750D/20251206/IMG_4558.JPG
< 0042a05478c18494f879ea31dd5143d5ea2e375ee359f5f2cb2ec52c15522d1f  /mnt/files/CANON/EOS_750D/20251206/IMG_4522.CR2
< 008eb06f7ee91e61737ca266f36f96cc2691482301731391ee160a6f7487e1f7  /mnt/files/CANON/EOS_750D/20251206/IMG_4517.CR2
< 0443f91bc3ae06d3d7aa441b72a22ed7b45076a9d3aa84a99920f14098141984  /mnt/files/CANON/EOS_750D/20251206/IMG_4524.CR2
< 04888cbf030243f80a7d83e86e44c42e6db5c8c434ba92c9ce2e76c8c3b40721  /mnt/files/CANON/EOS_750D/20251206/IMG_4538.JPG
< 0563ffcbb3324be21446ddc1ebfec35023ec958d79de6c960ea20d54a924a670  /mnt/files/CANON/EOS_750D/20251206/IMG_4587.CR2
< 066a7d077e0a917deb868b242c08ed5acdcdc31ec5d4d339da4192de3d09a394  /mnt/files/CANON/EOS_750D/20251206/IMG_4545.JPG
< 0bdf0713b554129ffe25e774a0f5b75bd906b118604b7f5411f191e431db7894  /mnt/files/CANON/EOS_750D/20251206/IMG_4516.CR2
< 0df0d542b17b368e824c38840d8cc6ccfb1e9fcb6a3ff8b34bdf8c004c3404b1  /mnt/files/CANON/EOS_750D/20251206/IMG_4485.JPG
< 0e25cc41b1338691e270ab5010946153d8b12b05fbbb86a353c9264863359147  /mnt/files/CANON/EOS_750D/20251206/IMG_4494.CR2
< 0fb267cae95add016492f53da8ff399ee538dbdb79bb5c9d6083fc27f897693a  /mnt/files/CANON/EOS_750D/20251206/IMG_4478.JPG
< 101e9e24e616ea7d4cbd99ab2199d0361f5751d3b2bdb572733b4a0c9702a7ea  /mnt/files/CANON/EOS_750D/20251206/IMG_4499.CR2
< 107f63d8d448d971c6ddc33bd9e60a44395eae207e353944ed9e80874574e123  /mnt/files/CANON/EOS_750D/20251206/IMG_4498.JPG
< 1080e566a72f4fed028a4b55f2523b6dc278704a7b5d7bcdfef1fe83b09b47bf  /mnt/files/CANON/EOS_750D/20251206/IMG_4515.JPG
< 11a74060671571be28d06426e2acf4851a37c3a47a6a54c70862b9a8220adf54  /mnt/files/CANON/EOS_750D/20251206/IMG_4543.JPG
< 126b4fe57f0854f5a2e23f0f0a53e81ac27cf9e56a348ac7e2407b0d48ad64f3  /mnt/files/CANON/EOS_750D/20251206/IMG_4521.JPG
< 15de341a06466fab7cac7db2a635e45e27ab8aa3abfe411d3edbdca50bbb5ff5  /mnt/files/CANON/EOS_750D/20251206/IMG_4491.JPG
< 164851ac0fe8fb922953515fb7faa9126207f5fca7f4baac365357eab76be41f  /mnt/files/CANON/EOS_750D/20251206/IMG_4566.JPG
< 16ccdf3a8429ba1b21c7ca8a6d428e0f19b37537f6a6b46112bc3625938a4185  /mnt/files/CANON/EOS_750D/20251206/IMG_4482.JPG
< 171f11c5b8e3869d378efa30e72557572eaae7e0113450e28520845fcd935a86  /mnt/files/CANON/EOS_750D/20251206/IMG_4539.JPG
< 177a6eb60e95e13a37197a9971b0eb3622d1e8bcb08c12a70dd98ca469601993  /mnt/files/CANON/EOS_750D/20251206/IMG_4488.CR2
< 18c7aa485d2b00a6be82edb09b6cb3e424eafba2a340ffe7b850c23339907f48  /mnt/files/CANON/EOS_750D/20251206/IMG_4556.JPG
< 1a98902a89f0244064ce3911a666dad2ac2f6a7beb96d12321dc32dff78c287a  /mnt/files/CANON/EOS_750D/20251206/IMG_4498.CR2
< 1ba9e46dddc9d88e01b8c64ea821902d1bd0894fed72628f947dad6926474519  /mnt/files/CANON/EOS_750D/20251206/IMG_4545.CR2
< 1d2648e114f0eee989d9b8a1ab885e52b3f7a803af0cddc1f41d4f7f48504152  /mnt/files/CANON/EOS_750D/20251206/IMG_4519.JPG
< 1f880f3793b530ab68b13d2ffda5830f0bd33182c1fd1c5bfb01133ad37e0389  /mnt/files/CANON/EOS_750D/20251206/IMG_4511.CR2
< 209d51f912b2a792a6c181a619df2698c9abc739b5d0404fe71afdae623b6426  /mnt/files/CANON/EOS_750D/20251206/IMG_4561.JPG
< 26c96b323e98a91ae054bb01bc1067659b1d5afff7eea86313f58d8f2cf628a4  /mnt/files/CANON/EOS_750D/20251206/IMG_4520.JPG
< 2ad8f33f9e100fe23c1f15ea893736d36ce61312699a3015468015a61ff88222  /mnt/files/CANON/EOS_750D/20251206/IMG_4563.JPG
< 2c102de5674985c306b695645410c7333505977b0f61b59faaf6769a69aeb5f0  /mnt/files/CANON/EOS_750D/20251206/IMG_4549.CR2
< 2d3159398dc0283ad6cb2b6606c5da867ce26b9eefb7325a63ab41f3ec908c33  /mnt/files/CANON/EOS_750D/20251206/IMG_4493.CR2
< 2f7aaa925f69c05025b1d6d5842ce03ecb4087de39f6e0572e4c500f084f8aea  /mnt/files/CANON/EOS_750D/20251206/IMG_4490.CR2
< 2fcfe5385b2780c5088987654b7f5dcb001e5e58c3af6bfbce4554ca4748b7ae  /mnt/files/CANON/EOS_750D/20251206/IMG_4511.JPG
< 3371af90f490df0fc6d8e6ba03bc90a61379e6f226cad820e1d6b4cab502c91f  /mnt/files/CANON/EOS_750D/20251206/IMG_4523.CR2
< 33f7c21ff6fbab63a7080ed9b39cf0d5a2fe26ecab5d46db2aab542a687cef5c  /mnt/files/CANON/EOS_750D/20251206/IMG_4523.JPG
< 34ef83870ee3874b3ca4c3a48c059ec683b7c5739dde283e52fc028893f1c783  /mnt/files/CANON/EOS_750D/20251206/IMG_4553.JPG
< 36046c196c9dafda83065242fdee4bda1fc6cfdf3e7e421671c97d433cbf9106  /mnt/files/CANON/EOS_750D/20251206/IMG_4482.CR2
< 36d4c254f2763a3218ac168c3cdebac97853f3afbd13910291f233a20b8019f9  /mnt/files/CANON/EOS_750D/20251206/IMG_4502.JPG
< 396c84f051507c37fabe76b67535da4e9178fc92d113f754c2905775bf13e438  /mnt/files/CANON/EOS_750D/20251206/IMG_4535.CR2
< 3a6a4c6e630281f04790240b6bb6721a2565ba1ae13556ffa92e76e749adad1f  /mnt/files/CANON/EOS_750D/20251206/IMG_4525.CR2
< 3a85669efd0fd6cba442e9cb6a07426ea067a94d07d16097109d0819b4e7d6e0  /mnt/files/CANON/EOS_750D/20251206/IMG_4522.JPG
< 3da6c286892cbed4e97b9ad0c03703fd8a117b2522e3866e80733382ab191f04  /mnt/files/CANON/EOS_750D/20251206/IMG_4558.CR2
< 42d6cde67882e4ed70ff457a46cabec68f560b3c46507319c607cf47d4c761d0  /mnt/files/CANON/EOS_750D/20251206/IMG_4538.CR2
< 44534cde417e975409bf6b33cce8be5a288e92d85a1f6353a0db45dc91084977  /mnt/files/CANON/EOS_750D/20251206/IMG_4549.JPG
< 471f33e0a4d9ab8e3b1852a4072731d8d0cfa4b24621e97e414613747b239ef0  /mnt/files/CANON/EOS_750D/20251206/IMG_4515.CR2
< 473ef5ee2c46b80771c5db861da0ee96c2aed6e1f5be9819974f0e317ebb4f8a  /mnt/files/CANON/EOS_750D/20251206/IMG_4547.CR2
< 48ae9210c005cc33fd9998d310388af699196d01f799fc0048d4ef4cccf215a1  /mnt/files/CANON/EOS_750D/20251206/IMG_4541.JPG
< 4a03760627edecfab66095b01b02b7393934876481204f11aa83eade39e3ff6c  /mnt/files/CANON/EOS_750D/20251206/IMG_4528.CR2
< 4cbc74dcbf7b6176941ed4394a0365ffffe4d1a912e7b4b9331e05f42d82844b  /mnt/files/CANON/EOS_750D/20251206/IMG_4509.CR2
< 4fff7265937d17efbc523ea3cfd5710258154994e6e45e360f55cca4fc131a03  /mnt/files/CANON/EOS_750D/20251206/IMG_4543.CR2
< 5166bd2824951b03587a668dfe9026bf4f65c8259494d97214f508326afd3873  /mnt/files/CANON/EOS_750D/20251206/IMG_4508.CR2
< 53e9bef19fa6472000073bb005d01295bc8879407636c6129675b0741140a501  /mnt/files/CANON/EOS_750D/20251206/IMG_4534.CR2
< 56933389edf046974a94231c64a07a21ca66abe2b62b0ec53db9beaf9dc9497d  /mnt/files/CANON/EOS_750D/20251206/IMG_4539.CR2
< 57e041a3ac4b2c8825bddc9ac75000fdfd04ecc2e16ee52bba2f048c92e8ea1b  /mnt/files/CANON/EOS_750D/20251206/IMG_4576.JPG
< 586a6df39b8e6d3b1563ae92ac7fdca92acab680a53be0361ebf92dc9430c459  /mnt/files/CANON/EOS_750D/20251206/IMG_4564.JPG
< 58dc164bca2c502f7ea40ac8377b069f4a6243a3a031c5a60e7616c553db6e75  /mnt/files/CANON/EOS_750D/20251206/IMG_4485.CR2
< 590dea20af1c9d4f8591353ffb05b80f592e77b1e596a816e168cae900068d5b  /mnt/files/CANON/EOS_750D/20251206/IMG_4484.CR2
< 595b375c108fca085d5e5ba138ab45933ad0c69be22c4d8987c0b56a456edd6f  /mnt/files/CANON/EOS_750D/20251206/IMG_4580.CR2
< 5a3fb55470d0c68796152e8ee5ad9970ecaf2748a1a8335a71ce295e8149601e  /mnt/files/CANON/EOS_750D/20251206/IMG_4500.JPG
< 5ce40c4f28152d2d22756ed476e0b686c350cdc709f46177eb4a2792b272ee14  /mnt/files/CANON/EOS_750D/20251206/IMG_4542.CR2
< 5db108507232620256a9e74c5f45d09dbf62fd67313206bdf3e7c437288ecd62  /mnt/files/CANON/EOS_750D/20251206/IMG_4521.CR2
< 5ef2cc57c26a8df8a30d00a0351d12bbfd41e0a9b6c71b9628c935cb5bc107a2  /mnt/files/CANON/EOS_750D/20251206/IMG_4533.JPG
< 61ae863b887d1c4d21461183b4de09fb0c967928e8564ac2133db914b8e7e910  /mnt/files/CANON/EOS_750D/20251206/IMG_4491.CR2
< 648186ace02eb21cc872a1de281cf3cce2f46f9a952639febfc7621fdf3427bd  /mnt/files/CANON/EOS_750D/20251206/IMG_4562.CR2
< 64d883ce30be505e00beeb33ebb80b77cbe79743d898bb688b5f746668d710f5  /mnt/files/CANON/EOS_750D/20251206/IMG_4553.CR2
< 6599e58281b2fc4c621bde89363429d17ef7fb0e61fcaa1dc5f7f55f1e9e99ca  /mnt/files/CANON/EOS_750D/20251206/IMG_4524.JPG
< 65d2799937b7c9c31e7600777d402cfa5d3b72d33d2129657dc59cfe2935b24a  /mnt/files/CANON/EOS_750D/20251206/IMG_4512.CR2
< 662f9221767f87165de9fb6b2faa15610d39f6b4c52b977b1684c8daf1f2256b  /mnt/files/CANON/EOS_750D/20251206/IMG_4586.JPG
< 6678069cb5c32fdc5e5cb38b0b5faa3274ec67793ce5a77801ac2d652d822988  /mnt/files/CANON/EOS_750D/20251206/IMG_4492.JPG
< 68e384d2e4b13f6b1578aaa817a8dd807246a73ebd899d10211c0f35f7625ac3  /mnt/files/CANON/EOS_750D/20251206/IMG_4565.CR2
< 6a7d45f057784bee52ef78e6174bef61d272db14fb4fc02db04e37b176749226  /mnt/files/CANON/EOS_750D/20251206/IMG_4519.CR2
< 6e6797817b73f10302c0962d9640ba6c79b958385a60a2069c205176c41112c0  /mnt/files/CANON/EOS_750D/20251206/IMG_4530.JPG
< 6ef991cfe5987bd5c70d45fa7088ad7f242a1e219697fefc3d708d7d3e616e52  /mnt/files/CANON/EOS_750D/20251206/IMG_4583.JPG
< 72a498bf1a19adcf2ec3278deafd6b0ebc1d8c142622f243504e1888188a1a4d  /mnt/files/CANON/EOS_750D/20251206/IMG_4520.CR2
< 736d3932f738c9279ed5987bf73228d692bce154be8f3e8da189597252b1c1b3  /mnt/files/CANON/EOS_750D/20251206/IMG_4510.CR2
< 744edda12bc7ac020849ed02d0e883a0748df3082a7c6222ab18d77db640c773  /mnt/files/CANON/EOS_750D/20251206/IMG_4534.JPG
< 7541844afebd4facac461bb0e3b047cf52e4ac8331ef562098bd2be33105c537  /mnt/files/CANON/EOS_750D/20251206/IMG_4486.JPG
< 7621bdc776feee2802469c5e37befedc40794cb2bf3e304b5deb04029cda5509  /mnt/files/CANON/EOS_750D/20251206/IMG_4502.CR2
< 791fd96fb5e3b18183692d98149eb97f82ccd35a4a9202f68643306aaadc9930  /mnt/files/CANON/EOS_750D/20251206/IMG_4495.JPG
< 7a6b26f3115648b01918b28ed02ba7de1949cdc5066d4230eb9c568a5a680640  /mnt/files/CANON/EOS_750D/20251206/IMG_4555.CR2
< 7c2b4bebd94989e7558e46e7da2a08e4c0716fcd769df6ee2215a40b95fc5bfe  /mnt/files/CANON/EOS_750D/20251206/IMG_4554.CR2
< 7d490d82b2408f3df9c9d954a75ddce7bb196ef0fed7fe5791c103597d9a0e52  /mnt/files/CANON/EOS_750D/20251206/IMG_4587.JPG
< 7e94f10efe75be1f7a2f2c7e24df25f70a6d7d7c37fb758e9dd5a8bdbfabade7  /mnt/files/CANON/EOS_750D/20251206/IMG_4581.JPG
< 7ec4c4cb01b8847dd59313f71a3740ba2becbc7052a35e99a9e350691e6ff800  /mnt/files/CANON/EOS_750D/20251206/IMG_4480.CR2
< 7f22b4ebe62fd67f923136c8fb5fcafe8059337fe3cad6d2bca36b5f81ff9d26  /mnt/files/CANON/EOS_750D/20251206/IMG_4579.JPG
< 7f7d09af86144a53dcedac5965ea0491c6c452b093fef2e173938bc02b510a27  /mnt/files/CANON/EOS_750D/20251206/IMG_4487.CR2
< 8032c01a62b05fa25c51cfe564a988f7995d3fec0fb4e86ec67cd9ad133b27d6  /mnt/files/CANON/EOS_750D/20251206/IMG_4540.CR2
< 80e03ecc9bbe85b189da6647ed0268b22b9e114bf59c0b085e616e7bafd53baa  /mnt/files/CANON/EOS_750D/20251206/IMG_4556.CR2
< 82fa2cb80120db7c204e1ec7644b6d9657e137b19ba30011c4ab2891c338d64d  /mnt/files/CANON/EOS_750D/20251206/IMG_4547.JPG
< 85c58e6458315735dcd049786130dfe17c67877c8aea0cadccb733149d0e59dd  /mnt/files/CANON/EOS_750D/20251206/IMG_4516.JPG
< 86402a77f5ea3af86338f520fffcf6dec55cc06ea2b9b85d8e15e9bbc8a11eec  /mnt/files/CANON/EOS_750D/20251206/IMG_4528.JPG
< 879228217185920aa6c0c9bfca3dd7735419c02c3ab077d2db3db34aef661d96  /mnt/files/CANON/EOS_750D/20251206/IMG_4488.JPG
< 87b0663b85cff636843dda57ae06c140df2ee09cfef35455cbdae23f2f0937ac  /mnt/files/CANON/EOS_750D/20251206/IMG_4583.CR2
< 89042f3e2fde742ecead2e629291247d56e2f679ffe0a502b66251f6450e8fbc  /mnt/files/CANON/EOS_750D/20251206/IMG_4586.CR2
< 89201d6d0191e7ffee651c9d5bb8e7d4037e294c4af6cddd061cb17be472fcdb  /mnt/files/CANON/EOS_750D/20251206/IMG_4563.CR2
< 8a155fd2ab5f5211ddfd173afacec5d6a8a79e9e43db8f4bd20f280debeb1818  /mnt/files/CANON/EOS_750D/20251206/IMG_4494.JPG
< 8ad536412dcabcdb3e366a3aa17815412d3b6e3dce872e15368ad78624b279da  /mnt/files/CANON/EOS_750D/20251206/IMG_4526.JPG
< 8c30d52f5039729ae01445d369d0c0c96316c0aaa37852bed6095fa7faf5dcca  /mnt/files/CANON/EOS_750D/20251206/IMG_4480.JPG
< 9031f29d751211e552e66a82cd5a8a0b95532011d2d724a94053e3a8f8813729  /mnt/files/CANON/EOS_750D/20251206/IMG_4579.CR2
< 906d255396793e07e86cbec9cfca3197f1ddefe0939e97a7ecae2bbeba8b572b  /mnt/files/CANON/EOS_750D/20251206/IMG_4518.JPG
< 91319c75cc7b523557a30115191c07e33aa30e3c45375a7648deab141ffe1095  /mnt/files/CANON/EOS_750D/20251206/IMG_4559.CR2
< 9512f21b9bfbd19037c04eb1a84a12de6860a06c14e446f7730bdcf07437ff2b  /mnt/files/CANON/EOS_750D/20251206/IMG_4487.JPG
< 97f0580df5bd3f6680cbeb7a499d4a099127d5fb6405ea15531f849975dc112d  /mnt/files/CANON/EOS_750D/20251206/IMG_4561.CR2
< 97f48544b309df12bbe9ae18531791254b46012d1181838ee81915bc753e2359  /mnt/files/CANON/EOS_750D/20251206/IMG_4548.CR2
< 9b221976deeb79141bd9b94b0f726000a67181dd5e0890840b5478490629569b  /mnt/files/CANON/EOS_750D/20251206/IMG_4477.JPG
< 9b2886df7344fba0bfcb3bd0ee3d73a944f77a0b3513afe0e14f0996bd3a2e34  /mnt/files/CANON/EOS_750D/20251206/IMG_4582.JPG
< 9be6902d4828c81ab819965f1f9e06ac98fbb3ef0f1cf0db1f920a1be0f222cc  /mnt/files/CANON/EOS_750D/20251206/IMG_4531.JPG
< 9c61194e5cdb73d6dc28ca17e61f282819d742b59aaacefd411d8d7f6f9c37ed  /mnt/files/CANON/EOS_750D/20251206/IMG_4508.JPG
< 9dbe479abfbd9da1a2956c6d3cb8711e9a37de5d3c46bc14039bf4fe4a9e653a  /mnt/files/CANON/EOS_750D/20251206/IMG_4533.CR2
< 9ea1311c1609d60ee4f82dfd7bd70d4f24b90d829146cb0546f65d02df34bc7b  /mnt/files/CANON/EOS_750D/20251206/IMG_4484.JPG
< 9f7bf9676b32668d530a674cbd9d60a389e049759332cc6373698b0c942232bc  /mnt/files/CANON/EOS_750D/20251206/IMG_4564.CR2
< a3932525b6b99d58f45d7c348c66147a14eaa0884a9c20ed24a80b43665c5460  /mnt/files/CANON/EOS_750D/20251206/IMG_4535.JPG
< a393b80378db96194a9d9d41d6eb910e8ca4a7f2915e73050ee936c4caaef8c0  /mnt/files/CANON/EOS_750D/20251206/IMG_4517.JPG
< a4db92f94b1a9b5e4c93d0950230f81a7f3f17f4226e2f7c3600c367ad161d55  /mnt/files/CANON/EOS_750D/20251206/IMG_4552.JPG
< a65fcf2ca02222d58297b8a09acc94d3a8de01930cb8e173742ad08ce1f896e9  /mnt/files/CANON/EOS_750D/20251206/IMG_4513.CR2
< a683984a9f558cf372e6ff445fde1f43bebae28fb951d34d4288eb017ef264fc  /mnt/files/CANON/EOS_750D/20251206/IMG_4509.JPG
< a8d35aa61ee1a321f86e0c9520426a9684f94c9a0f5c519c1f3f5043d2b67682  /mnt/files/CANON/EOS_750D/20251206/IMG_4562.JPG
< a96d539f6f62c26fc4736e3a85ef020ab5c164fa0baba752d7b809d78367aa9d  /mnt/files/CANON/EOS_750D/20251206/IMG_4531.CR2
< aa02fe789851e804084276499e21b5be3ab8a4f73b810885316c1bcf4b84a4e8  /mnt/files/CANON/EOS_750D/20251206/IMG_4495.CR2
< aafe5c5b29c93faf4420c0d5692987b33364e330e6f14ebdc25fbe3ca1d18b8c  /mnt/files/CANON/EOS_750D/20251206/IMG_4512.JPG
< ab329cd96150bbdce3219aff2981ede755cf3fcc64045aa49e285b2e994eb138  /mnt/files/CANON/EOS_750D/20251206/IMG_4576.CR2
< abce9e5a68864173839d5c4c5124f1870962fb0baf5692302ed62545bd0205d1  /mnt/files/CANON/EOS_750D/20251206/IMG_4532.CR2
< b19eebd07a5ebf65b6c1e8a138212fbd1f6d1ca467e0c621ff0bd41f07752f33  /mnt/files/CANON/EOS_750D/20251206/IMG_4540.JPG
< b5d526af4702263cd0ea2c06adfff6c515a77e924d069a07439e77f7bc4477f8  /mnt/files/CANON/EOS_750D/20251206/IMG_4569.JPG
< b7eaebf1b414d72f3a4cc17d4b2d2666180386cfb3e3ee89121d21f833c79bc4  /mnt/files/CANON/EOS_750D/20251206/IMG_4510.JPG
< ba21001c63f84cae3743cbdab7f8eaad8bec5fb2bcec42419a6ee88c5f1b6424  /mnt/files/CANON/EOS_750D/20251206/IMG_4525.JPG
< bae0d0b9f8100e4de44a1ec34a2dac361752921e7015f3911147d502d3b51981  /mnt/files/CANON/EOS_750D/20251206/IMG_4581.CR2
< bb2b51c7a72ca24f1348939b72f3e53d0d03df5b5817c98be6a5423ccc1a36b4  /mnt/files/CANON/EOS_750D/20251206/IMG_4542.JPG
< bb899515696b7851764888e45905e080cb389a02f54b3008bce113ce3c9dcf13  /mnt/files/CANON/EOS_750D/20251206/IMG_4478.CR2
< bbdc604acc385f54ed5c138824a0267d6eee8687a0af91963a8fc623461f12d5  /mnt/files/CANON/EOS_750D/20251206/IMG_4536.CR2
< be35d4be8db4f5519e3495199c423d4c1931e0e72dbab82e7a4d87988b75c09a  /mnt/files/CANON/EOS_750D/20251206/IMG_4573.JPG
< c53a36d9a475562d0c7a3904f1cbe006fce76ef78ee16de84662e0de5ee4e55f  /mnt/files/CANON/EOS_750D/20251206/IMG_4486.CR2
< c7c5efe9f292f21b92890c653337e66fbf9002a195e22fa73ffdd6eb9127b7d9  /mnt/files/CANON/EOS_750D/20251206/IMG_4571.JPG
< c91edc3cea9bcf0191d108e75b258270d24c29752571efc2b2279025c43314f8  /mnt/files/CANON/EOS_750D/20251206/IMG_4580.JPG
< c987f73ff46fb8b47eee029bc3882022264fdc32bb873ad33dea3df68f154eb1  /mnt/files/CANON/EOS_750D/20251206/IMG_4492.CR2
< ca5413acc1d70a667276af6ed643ce2a02791daefdd2a9de31b9ce6521ed1a13  /mnt/files/CANON/EOS_750D/20251206/IMG_4569.CR2
< cc7fca83d64062c504a36ca0eb118c82ef2ab70291c7e2e55e31d1dbd51a1058  /mnt/files/CANON/EOS_750D/20251206/IMG_4559.JPG
< ce27907b5e761dfd99846bc72cd34b61e80e7af55bb29697850ac5cf85cdd31b  /mnt/files/CANON/EOS_750D/20251206/IMG_4477.CR2
< cf1290ec18ab6879e1bceb398d17599b50ef0377de9024b8dd7d63ad21280a4d  /mnt/files/CANON/EOS_750D/20251206/IMG_4544.JPG
< cfe1c36992da01474b3c13d278588970e74063a22d9b17b262411102947cf6b3  /mnt/files/CANON/EOS_750D/20251206/IMG_4499.JPG
< d2501957f3ed09eb06becdff9892c822a2fd58140fe729fde9c4c140459339b9  /mnt/files/CANON/EOS_750D/20251206/IMG_4560.JPG
< d3e920dbf63a8f8f877bf6ff0be87af8a2d54b150b77c63d40ac551f174ac6bd  /mnt/files/CANON/EOS_750D/20251206/IMG_4526.CR2
< d556efb3f19c3a7008561c03f62cca8fe2ae62bce407c3110a3760cc2012d847  /mnt/files/CANON/EOS_750D/20251206/IMG_4557.CR2
< d5ba23de30f419e62d292a75fdb569fae8e4362f11a81eb68a3363282d9ffa25  /mnt/files/CANON/EOS_750D/20251206/IMG_4518.CR2
< d5fb5507e25dda16735638dd413ae8efe5d6b07dbda0efcaa6b39de73ddd4d01  /mnt/files/CANON/EOS_750D/20251206/IMG_4532.JPG
< d72cae73052959cd9d34d5b41d974f3b3086d610763757658fa0d7419d1b1d95  /mnt/files/CANON/EOS_750D/20251206/IMG_4554.JPG
< d86255ed6bff92ba6f3dfdd5ee2fe9fc65777f45fd3cc3234a655126c61a7829  /mnt/files/CANON/EOS_750D/20251206/IMG_4497.CR2
< dc3d0252988a2e60b8e16668b592ac0b227bca6f96d48b1adfc41e99d8706217  /mnt/files/CANON/EOS_750D/20251206/IMG_4530.CR2
< dc6c8b3dc44192ff644fdc046f946413b3c8196c28f9843ac2a1982d4f18076c  /mnt/files/CANON/EOS_750D/20251206/IMG_4497.JPG
< dd1729d831e53182ed0c709301557a0ccc50ac810312c7ce114a55ef7d589c70  /mnt/files/CANON/EOS_750D/20251206/IMG_4573.CR2
< ddd6ae9f871f285af3c81527dddd2bf6aaeffc20769a542dd193e90275c4a13e  /mnt/files/CANON/EOS_750D/20251206/IMG_4548.JPG
< de6c608605fb3483e8a7e4c18847e1ac6e0b4cb7c74e5c2d14ddcc1512a50a06  /mnt/files/CANON/EOS_750D/20251206/IMG_4565.JPG
< e0bddb71e6466e6fbbe88c5a66117ef756595fc48c2fb0e2a93d913effee08a9  /mnt/files/CANON/EOS_750D/20251206/IMG_4555.JPG
< e787d5b5e7d36fd676b3ba0e2c60a2d8ca327ab3cf12f4dfed7768d30fd10ea1  /mnt/files/CANON/EOS_750D/20251206/IMG_4552.CR2
< e8251c6474dd5b4456a27fc1126c51ee21d9cd12a219c2b78f1590758f8769c3  /mnt/files/CANON/EOS_750D/20251206/IMG_4541.CR2
< e98de9982f3c52779c83aa8e9f7c17e9bbea1599b6287fa52f384b34ab41584a  /mnt/files/CANON/EOS_750D/20251206/IMG_4529.JPG
< eb3c36ce812652329af5a721993637c8114410a0d67f2789b126afae494f317f  /mnt/files/CANON/EOS_750D/20251206/IMG_4557.JPG
< ebdd02815636e443e882a5738acb7854c8a3cfa3cb0ac3d00de343e52a92eab1  /mnt/files/CANON/EOS_750D/20251206/IMG_4571.CR2
< ed894266151289901e11b902b883482f929bac3b109b8083c1c41bb773066662  /mnt/files/CANON/EOS_750D/20251206/IMG_4513.JPG
< eda6815c24c5e4ca9cffc680d0f162a197856d8c85a2fa5146b33e030bde38d0  /mnt/files/CANON/EOS_750D/20251206/IMG_4560.CR2
< f33b25ed3eb91b701e33fb2db72242697b754fde4b3217b092847b42e6e31ad1  /mnt/files/CANON/EOS_750D/20251206/IMG_4500.CR2
< f46c9da315646574ebf103ffde287d32fe4d6adbc5a61fcad4b8d48fa0a1c0a3  /mnt/files/CANON/EOS_750D/20251206/IMG_4582.CR2
< f4e8ed21a72de43a265ad78bac1e3951a4670ed42c84320b58a839af83b656b0  /mnt/files/CANON/EOS_750D/20251206/IMG_4544.CR2
< f8b5c460087b243dc76fc9412fe07805be442d16d2d2ad9034b3bb3dfb475d9e  /mnt/files/CANON/EOS_750D/20251206/IMG_4537.CR2
< f8c4b6cca8fdceb84cfed5961016780c5066e2cacc7fc0c35120e91c30c73c50  /mnt/files/CANON/EOS_750D/20251206/IMG_4537.JPG
< fae5a018eb8743461e5924996e3ddf86c92bf59f82f2e298e1666d622df326fe  /mnt/files/CANON/EOS_750D/20251206/IMG_4529.CR2
< fb0c65eb1a85e22b9d8223bd3af6b5bc5cc0a61689cfaf31f00f3590a9cdeedd  /mnt/files/CANON/EOS_750D/20251206/IMG_4536.JPG
< fcbb6c2221c146e0ef2642da2ded6f4820ffcffd57e9b6d646d6ad1d65b86827  /mnt/files/CANON/EOS_750D/20251206/IMG_4566.CR2
< fcff9de7881c7906922fc204c4fb0e3948e95fea3c87cf59a50812c712f8ceb4  /mnt/files/CANON/EOS_750D/20251206/IMG_4490.JPG
< fd5049cef27875961aa848c38bd3fea350c973ecd247bd8df042cccb614a9df3  /mnt/files/CANON/EOS_750D/20251206/IMG_4493.JPG
---
> 000917a5d5521f8e2570f8092a51a295c4d4c567489f336ccf83978f152c2ce9  IMG_4558.JPG
> 0042a05478c18494f879ea31dd5143d5ea2e375ee359f5f2cb2ec52c15522d1f  IMG_4522.CR2
> 008eb06f7ee91e61737ca266f36f96cc2691482301731391ee160a6f7487e1f7  IMG_4517.CR2
> 0443f91bc3ae06d3d7aa441b72a22ed7b45076a9d3aa84a99920f14098141984  IMG_4524.CR2
> 04888cbf030243f80a7d83e86e44c42e6db5c8c434ba92c9ce2e76c8c3b40721  IMG_4538.JPG
> 0563ffcbb3324be21446ddc1ebfec35023ec958d79de6c960ea20d54a924a670  IMG_4587.CR2
> 066a7d077e0a917deb868b242c08ed5acdcdc31ec5d4d339da4192de3d09a394  IMG_4545.JPG
> 0bdf0713b554129ffe25e774a0f5b75bd906b118604b7f5411f191e431db7894  IMG_4516.CR2
> 0df0d542b17b368e824c38840d8cc6ccfb1e9fcb6a3ff8b34bdf8c004c3404b1  IMG_4485.JPG
> 0e25cc41b1338691e270ab5010946153d8b12b05fbbb86a353c9264863359147  IMG_4494.CR2
> 0fb267cae95add016492f53da8ff399ee538dbdb79bb5c9d6083fc27f897693a  IMG_4478.JPG
> 101e9e24e616ea7d4cbd99ab2199d0361f5751d3b2bdb572733b4a0c9702a7ea  IMG_4499.CR2
> 107f63d8d448d971c6ddc33bd9e60a44395eae207e353944ed9e80874574e123  IMG_4498.JPG
> 1080e566a72f4fed028a4b55f2523b6dc278704a7b5d7bcdfef1fe83b09b47bf  IMG_4515.JPG
> 11a74060671571be28d06426e2acf4851a37c3a47a6a54c70862b9a8220adf54  IMG_4543.JPG
> 126b4fe57f0854f5a2e23f0f0a53e81ac27cf9e56a348ac7e2407b0d48ad64f3  IMG_4521.JPG
> 15de341a06466fab7cac7db2a635e45e27ab8aa3abfe411d3edbdca50bbb5ff5  IMG_4491.JPG
> 164851ac0fe8fb922953515fb7faa9126207f5fca7f4baac365357eab76be41f  IMG_4566.JPG
> 16ccdf3a8429ba1b21c7ca8a6d428e0f19b37537f6a6b46112bc3625938a4185  IMG_4482.JPG
> 171f11c5b8e3869d378efa30e72557572eaae7e0113450e28520845fcd935a86  IMG_4539.JPG
> 177a6eb60e95e13a37197a9971b0eb3622d1e8bcb08c12a70dd98ca469601993  IMG_4488.CR2
> 18c7aa485d2b00a6be82edb09b6cb3e424eafba2a340ffe7b850c23339907f48  IMG_4556.JPG
> 1a98902a89f0244064ce3911a666dad2ac2f6a7beb96d12321dc32dff78c287a  IMG_4498.CR2
> 1ba9e46dddc9d88e01b8c64ea821902d1bd0894fed72628f947dad6926474519  IMG_4545.CR2
> 1d2648e114f0eee989d9b8a1ab885e52b3f7a803af0cddc1f41d4f7f48504152  IMG_4519.JPG
> 1f880f3793b530ab68b13d2ffda5830f0bd33182c1fd1c5bfb01133ad37e0389  IMG_4511.CR2
> 209d51f912b2a792a6c181a619df2698c9abc739b5d0404fe71afdae623b6426  IMG_4561.JPG
> 26c96b323e98a91ae054bb01bc1067659b1d5afff7eea86313f58d8f2cf628a4  IMG_4520.JPG
> 2ad8f33f9e100fe23c1f15ea893736d36ce61312699a3015468015a61ff88222  IMG_4563.JPG
> 2c102de5674985c306b695645410c7333505977b0f61b59faaf6769a69aeb5f0  IMG_4549.CR2
> 2d3159398dc0283ad6cb2b6606c5da867ce26b9eefb7325a63ab41f3ec908c33  IMG_4493.CR2
> 2f7aaa925f69c05025b1d6d5842ce03ecb4087de39f6e0572e4c500f084f8aea  IMG_4490.CR2
> 2fcfe5385b2780c5088987654b7f5dcb001e5e58c3af6bfbce4554ca4748b7ae  IMG_4511.JPG
> 3371af90f490df0fc6d8e6ba03bc90a61379e6f226cad820e1d6b4cab502c91f  IMG_4523.CR2
> 33f7c21ff6fbab63a7080ed9b39cf0d5a2fe26ecab5d46db2aab542a687cef5c  IMG_4523.JPG
> 34ef83870ee3874b3ca4c3a48c059ec683b7c5739dde283e52fc028893f1c783  IMG_4553.JPG
> 36046c196c9dafda83065242fdee4bda1fc6cfdf3e7e421671c97d433cbf9106  IMG_4482.CR2
> 36d4c254f2763a3218ac168c3cdebac97853f3afbd13910291f233a20b8019f9  IMG_4502.JPG
> 396c84f051507c37fabe76b67535da4e9178fc92d113f754c2905775bf13e438  IMG_4535.CR2
> 3a6a4c6e630281f04790240b6bb6721a2565ba1ae13556ffa92e76e749adad1f  IMG_4525.CR2
> 3a85669efd0fd6cba442e9cb6a07426ea067a94d07d16097109d0819b4e7d6e0  IMG_4522.JPG
> 3da6c286892cbed4e97b9ad0c03703fd8a117b2522e3866e80733382ab191f04  IMG_4558.CR2
> 42d6cde67882e4ed70ff457a46cabec68f560b3c46507319c607cf47d4c761d0  IMG_4538.CR2
> 44534cde417e975409bf6b33cce8be5a288e92d85a1f6353a0db45dc91084977  IMG_4549.JPG
> 471f33e0a4d9ab8e3b1852a4072731d8d0cfa4b24621e97e414613747b239ef0  IMG_4515.CR2
> 473ef5ee2c46b80771c5db861da0ee96c2aed6e1f5be9819974f0e317ebb4f8a  IMG_4547.CR2
> 48ae9210c005cc33fd9998d310388af699196d01f799fc0048d4ef4cccf215a1  IMG_4541.JPG
> 4a03760627edecfab66095b01b02b7393934876481204f11aa83eade39e3ff6c  IMG_4528.CR2
> 4cbc74dcbf7b6176941ed4394a0365ffffe4d1a912e7b4b9331e05f42d82844b  IMG_4509.CR2
> 4fff7265937d17efbc523ea3cfd5710258154994e6e45e360f55cca4fc131a03  IMG_4543.CR2
> 5166bd2824951b03587a668dfe9026bf4f65c8259494d97214f508326afd3873  IMG_4508.CR2
> 53e9bef19fa6472000073bb005d01295bc8879407636c6129675b0741140a501  IMG_4534.CR2
> 56933389edf046974a94231c64a07a21ca66abe2b62b0ec53db9beaf9dc9497d  IMG_4539.CR2
> 57e041a3ac4b2c8825bddc9ac75000fdfd04ecc2e16ee52bba2f048c92e8ea1b  IMG_4576.JPG
> 586a6df39b8e6d3b1563ae92ac7fdca92acab680a53be0361ebf92dc9430c459  IMG_4564.JPG
> 58dc164bca2c502f7ea40ac8377b069f4a6243a3a031c5a60e7616c553db6e75  IMG_4485.CR2
> 590dea20af1c9d4f8591353ffb05b80f592e77b1e596a816e168cae900068d5b  IMG_4484.CR2
> 595b375c108fca085d5e5ba138ab45933ad0c69be22c4d8987c0b56a456edd6f  IMG_4580.CR2
> 5a3fb55470d0c68796152e8ee5ad9970ecaf2748a1a8335a71ce295e8149601e  IMG_4500.JPG
> 5ce40c4f28152d2d22756ed476e0b686c350cdc709f46177eb4a2792b272ee14  IMG_4542.CR2
> 5db108507232620256a9e74c5f45d09dbf62fd67313206bdf3e7c437288ecd62  IMG_4521.CR2
> 5ef2cc57c26a8df8a30d00a0351d12bbfd41e0a9b6c71b9628c935cb5bc107a2  IMG_4533.JPG
> 61ae863b887d1c4d21461183b4de09fb0c967928e8564ac2133db914b8e7e910  IMG_4491.CR2
> 648186ace02eb21cc872a1de281cf3cce2f46f9a952639febfc7621fdf3427bd  IMG_4562.CR2
> 64d883ce30be505e00beeb33ebb80b77cbe79743d898bb688b5f746668d710f5  IMG_4553.CR2
> 6599e58281b2fc4c621bde89363429d17ef7fb0e61fcaa1dc5f7f55f1e9e99ca  IMG_4524.JPG
> 65d2799937b7c9c31e7600777d402cfa5d3b72d33d2129657dc59cfe2935b24a  IMG_4512.CR2
> 662f9221767f87165de9fb6b2faa15610d39f6b4c52b977b1684c8daf1f2256b  IMG_4586.JPG
> 6678069cb5c32fdc5e5cb38b0b5faa3274ec67793ce5a77801ac2d652d822988  IMG_4492.JPG
> 68e384d2e4b13f6b1578aaa817a8dd807246a73ebd899d10211c0f35f7625ac3  IMG_4565.CR2
> 6a7d45f057784bee52ef78e6174bef61d272db14fb4fc02db04e37b176749226  IMG_4519.CR2
> 6e6797817b73f10302c0962d9640ba6c79b958385a60a2069c205176c41112c0  IMG_4530.JPG
> 6ef991cfe5987bd5c70d45fa7088ad7f242a1e219697fefc3d708d7d3e616e52  IMG_4583.JPG
> 72a498bf1a19adcf2ec3278deafd6b0ebc1d8c142622f243504e1888188a1a4d  IMG_4520.CR2
> 736d3932f738c9279ed5987bf73228d692bce154be8f3e8da189597252b1c1b3  IMG_4510.CR2
> 744edda12bc7ac020849ed02d0e883a0748df3082a7c6222ab18d77db640c773  IMG_4534.JPG
> 7541844afebd4facac461bb0e3b047cf52e4ac8331ef562098bd2be33105c537  IMG_4486.JPG
> 7621bdc776feee2802469c5e37befedc40794cb2bf3e304b5deb04029cda5509  IMG_4502.CR2
> 791fd96fb5e3b18183692d98149eb97f82ccd35a4a9202f68643306aaadc9930  IMG_4495.JPG
> 7a6b26f3115648b01918b28ed02ba7de1949cdc5066d4230eb9c568a5a680640  IMG_4555.CR2
> 7c2b4bebd94989e7558e46e7da2a08e4c0716fcd769df6ee2215a40b95fc5bfe  IMG_4554.CR2
> 7d490d82b2408f3df9c9d954a75ddce7bb196ef0fed7fe5791c103597d9a0e52  IMG_4587.JPG
> 7e94f10efe75be1f7a2f2c7e24df25f70a6d7d7c37fb758e9dd5a8bdbfabade7  IMG_4581.JPG
> 7ec4c4cb01b8847dd59313f71a3740ba2becbc7052a35e99a9e350691e6ff800  IMG_4480.CR2
> 7f22b4ebe62fd67f923136c8fb5fcafe8059337fe3cad6d2bca36b5f81ff9d26  IMG_4579.JPG
> 7f7d09af86144a53dcedac5965ea0491c6c452b093fef2e173938bc02b510a27  IMG_4487.CR2
> 8032c01a62b05fa25c51cfe564a988f7995d3fec0fb4e86ec67cd9ad133b27d6  IMG_4540.CR2
> 80e03ecc9bbe85b189da6647ed0268b22b9e114bf59c0b085e616e7bafd53baa  IMG_4556.CR2
> 82fa2cb80120db7c204e1ec7644b6d9657e137b19ba30011c4ab2891c338d64d  IMG_4547.JPG
> 85c58e6458315735dcd049786130dfe17c67877c8aea0cadccb733149d0e59dd  IMG_4516.JPG
> 86402a77f5ea3af86338f520fffcf6dec55cc06ea2b9b85d8e15e9bbc8a11eec  IMG_4528.JPG
> 879228217185920aa6c0c9bfca3dd7735419c02c3ab077d2db3db34aef661d96  IMG_4488.JPG
> 87b0663b85cff636843dda57ae06c140df2ee09cfef35455cbdae23f2f0937ac  IMG_4583.CR2
> 89042f3e2fde742ecead2e629291247d56e2f679ffe0a502b66251f6450e8fbc  IMG_4586.CR2
> 89201d6d0191e7ffee651c9d5bb8e7d4037e294c4af6cddd061cb17be472fcdb  IMG_4563.CR2
> 8a155fd2ab5f5211ddfd173afacec5d6a8a79e9e43db8f4bd20f280debeb1818  IMG_4494.JPG
> 8ad536412dcabcdb3e366a3aa17815412d3b6e3dce872e15368ad78624b279da  IMG_4526.JPG
> 8c30d52f5039729ae01445d369d0c0c96316c0aaa37852bed6095fa7faf5dcca  IMG_4480.JPG
> 9031f29d751211e552e66a82cd5a8a0b95532011d2d724a94053e3a8f8813729  IMG_4579.CR2
> 906d255396793e07e86cbec9cfca3197f1ddefe0939e97a7ecae2bbeba8b572b  IMG_4518.JPG
> 91319c75cc7b523557a30115191c07e33aa30e3c45375a7648deab141ffe1095  IMG_4559.CR2
> 9512f21b9bfbd19037c04eb1a84a12de6860a06c14e446f7730bdcf07437ff2b  IMG_4487.JPG
> 97f0580df5bd3f6680cbeb7a499d4a099127d5fb6405ea15531f849975dc112d  IMG_4561.CR2
> 97f48544b309df12bbe9ae18531791254b46012d1181838ee81915bc753e2359  IMG_4548.CR2
> 9b221976deeb79141bd9b94b0f726000a67181dd5e0890840b5478490629569b  IMG_4477.JPG
> 9b2886df7344fba0bfcb3bd0ee3d73a944f77a0b3513afe0e14f0996bd3a2e34  IMG_4582.JPG
> 9be6902d4828c81ab819965f1f9e06ac98fbb3ef0f1cf0db1f920a1be0f222cc  IMG_4531.JPG
> 9c61194e5cdb73d6dc28ca17e61f282819d742b59aaacefd411d8d7f6f9c37ed  IMG_4508.JPG
> 9dbe479abfbd9da1a2956c6d3cb8711e9a37de5d3c46bc14039bf4fe4a9e653a  IMG_4533.CR2
> 9ea1311c1609d60ee4f82dfd7bd70d4f24b90d829146cb0546f65d02df34bc7b  IMG_4484.JPG
> 9f7bf9676b32668d530a674cbd9d60a389e049759332cc6373698b0c942232bc  IMG_4564.CR2
> a3932525b6b99d58f45d7c348c66147a14eaa0884a9c20ed24a80b43665c5460  IMG_4535.JPG
> a393b80378db96194a9d9d41d6eb910e8ca4a7f2915e73050ee936c4caaef8c0  IMG_4517.JPG
> a4db92f94b1a9b5e4c93d0950230f81a7f3f17f4226e2f7c3600c367ad161d55  IMG_4552.JPG
> a65fcf2ca02222d58297b8a09acc94d3a8de01930cb8e173742ad08ce1f896e9  IMG_4513.CR2
> a683984a9f558cf372e6ff445fde1f43bebae28fb951d34d4288eb017ef264fc  IMG_4509.JPG
> a8d35aa61ee1a321f86e0c9520426a9684f94c9a0f5c519c1f3f5043d2b67682  IMG_4562.JPG
> a96d539f6f62c26fc4736e3a85ef020ab5c164fa0baba752d7b809d78367aa9d  IMG_4531.CR2
> aa02fe789851e804084276499e21b5be3ab8a4f73b810885316c1bcf4b84a4e8  IMG_4495.CR2
> aafe5c5b29c93faf4420c0d5692987b33364e330e6f14ebdc25fbe3ca1d18b8c  IMG_4512.JPG
> ab329cd96150bbdce3219aff2981ede755cf3fcc64045aa49e285b2e994eb138  IMG_4576.CR2
> abce9e5a68864173839d5c4c5124f1870962fb0baf5692302ed62545bd0205d1  IMG_4532.CR2
> b19eebd07a5ebf65b6c1e8a138212fbd1f6d1ca467e0c621ff0bd41f07752f33  IMG_4540.JPG
> b5d526af4702263cd0ea2c06adfff6c515a77e924d069a07439e77f7bc4477f8  IMG_4569.JPG
> b7eaebf1b414d72f3a4cc17d4b2d2666180386cfb3e3ee89121d21f833c79bc4  IMG_4510.JPG
> ba21001c63f84cae3743cbdab7f8eaad8bec5fb2bcec42419a6ee88c5f1b6424  IMG_4525.JPG
> bae0d0b9f8100e4de44a1ec34a2dac361752921e7015f3911147d502d3b51981  IMG_4581.CR2
> bb2b51c7a72ca24f1348939b72f3e53d0d03df5b5817c98be6a5423ccc1a36b4  IMG_4542.JPG
> bb899515696b7851764888e45905e080cb389a02f54b3008bce113ce3c9dcf13  IMG_4478.CR2
> bbdc604acc385f54ed5c138824a0267d6eee8687a0af91963a8fc623461f12d5  IMG_4536.CR2
> be35d4be8db4f5519e3495199c423d4c1931e0e72dbab82e7a4d87988b75c09a  IMG_4573.JPG
> c53a36d9a475562d0c7a3904f1cbe006fce76ef78ee16de84662e0de5ee4e55f  IMG_4486.CR2
> c7c5efe9f292f21b92890c653337e66fbf9002a195e22fa73ffdd6eb9127b7d9  IMG_4571.JPG
> c91edc3cea9bcf0191d108e75b258270d24c29752571efc2b2279025c43314f8  IMG_4580.JPG
> c987f73ff46fb8b47eee029bc3882022264fdc32bb873ad33dea3df68f154eb1  IMG_4492.CR2
> ca5413acc1d70a667276af6ed643ce2a02791daefdd2a9de31b9ce6521ed1a13  IMG_4569.CR2
> cc7fca83d64062c504a36ca0eb118c82ef2ab70291c7e2e55e31d1dbd51a1058  IMG_4559.JPG
> ce27907b5e761dfd99846bc72cd34b61e80e7af55bb29697850ac5cf85cdd31b  IMG_4477.CR2
> cf1290ec18ab6879e1bceb398d17599b50ef0377de9024b8dd7d63ad21280a4d  IMG_4544.JPG
> cfe1c36992da01474b3c13d278588970e74063a22d9b17b262411102947cf6b3  IMG_4499.JPG
> d2501957f3ed09eb06becdff9892c822a2fd58140fe729fde9c4c140459339b9  IMG_4560.JPG
> d3e920dbf63a8f8f877bf6ff0be87af8a2d54b150b77c63d40ac551f174ac6bd  IMG_4526.CR2
> d556efb3f19c3a7008561c03f62cca8fe2ae62bce407c3110a3760cc2012d847  IMG_4557.CR2
> d5ba23de30f419e62d292a75fdb569fae8e4362f11a81eb68a3363282d9ffa25  IMG_4518.CR2
> d5fb5507e25dda16735638dd413ae8efe5d6b07dbda0efcaa6b39de73ddd4d01  IMG_4532.JPG
> d72cae73052959cd9d34d5b41d974f3b3086d610763757658fa0d7419d1b1d95  IMG_4554.JPG
> d86255ed6bff92ba6f3dfdd5ee2fe9fc65777f45fd3cc3234a655126c61a7829  IMG_4497.CR2
> dc3d0252988a2e60b8e16668b592ac0b227bca6f96d48b1adfc41e99d8706217  IMG_4530.CR2
> dc6c8b3dc44192ff644fdc046f946413b3c8196c28f9843ac2a1982d4f18076c  IMG_4497.JPG
> dd1729d831e53182ed0c709301557a0ccc50ac810312c7ce114a55ef7d589c70  IMG_4573.CR2
> ddd6ae9f871f285af3c81527dddd2bf6aaeffc20769a542dd193e90275c4a13e  IMG_4548.JPG
> de6c608605fb3483e8a7e4c18847e1ac6e0b4cb7c74e5c2d14ddcc1512a50a06  IMG_4565.JPG
> e0bddb71e6466e6fbbe88c5a66117ef756595fc48c2fb0e2a93d913effee08a9  IMG_4555.JPG
> e787d5b5e7d36fd676b3ba0e2c60a2d8ca327ab3cf12f4dfed7768d30fd10ea1  IMG_4552.CR2
> e8251c6474dd5b4456a27fc1126c51ee21d9cd12a219c2b78f1590758f8769c3  IMG_4541.CR2
> e98de9982f3c52779c83aa8e9f7c17e9bbea1599b6287fa52f384b34ab41584a  IMG_4529.JPG
> eb3c36ce812652329af5a721993637c8114410a0d67f2789b126afae494f317f  IMG_4557.JPG
> ebdd02815636e443e882a5738acb7854c8a3cfa3cb0ac3d00de343e52a92eab1  IMG_4571.CR2
> ed894266151289901e11b902b883482f929bac3b109b8083c1c41bb773066662  IMG_4513.JPG
> eda6815c24c5e4ca9cffc680d0f162a197856d8c85a2fa5146b33e030bde38d0  IMG_4560.CR2
> f33b25ed3eb91b701e33fb2db72242697b754fde4b3217b092847b42e6e31ad1  IMG_4500.CR2
> f46c9da315646574ebf103ffde287d32fe4d6adbc5a61fcad4b8d48fa0a1c0a3  IMG_4582.CR2
> f4e8ed21a72de43a265ad78bac1e3951a4670ed42c84320b58a839af83b656b0  IMG_4544.CR2
> f8b5c460087b243dc76fc9412fe07805be442d16d2d2ad9034b3bb3dfb475d9e  IMG_4537.CR2
> f8c4b6cca8fdceb84cfed5961016780c5066e2cacc7fc0c35120e91c30c73c50  IMG_4537.JPG
> fae5a018eb8743461e5924996e3ddf86c92bf59f82f2e298e1666d622df326fe  IMG_4529.CR2
> fb0c65eb1a85e22b9d8223bd3af6b5bc5cc0a61689cfaf31f00f3590a9cdeedd  IMG_4536.JPG
> fcbb6c2221c146e0ef2642da2ded6f4820ffcffd57e9b6d646d6ad1d65b86827  IMG_4566.CR2
> fcff9de7881c7906922fc204c4fb0e3948e95fea3c87cf59a50812c712f8ceb4  IMG_4490.JPG
> fd5049cef27875961aa848c38bd3fea350c973ecd247bd8df042cccb614a9df3  IMG_4493.JPG
WARNING: Hash verification failed! Cleaning up...
INFO: Deleting files from /mnt/vera
INFO: Dismounting VeraCrypt container from: /mnt/vera
INFO: VeraCrypt container dismounted
INFO: Deleting VeraCrypt container: /mnt/vera-drive/andrew/20251206_20260118_040454.vc        echo -e "${RED}ERROR: Hash verification FAILED! Files do not match.${NC}"
        echo -e "\n${RED}Detailed differences:${NC}"
        # Show a summary of missing, extra, and mismatched files
        awk '{print $2" "$1}' "$SOURCE_HASH_FILE" | sort > /tmp/source_hash_sorted.txt
        awk '{print $2" "$1}' "$MOUNT_HASH_FILE" | sort > /tmp/mount_hash_sorted.txt

        # Find files missing in mount
        comm -23 <(awk '{print $1}' /tmp/source_hash_sorted.txt) <(awk '{print $1}' /tmp/mount_hash_sorted.txt) > /tmp/missing_in_mount.txt
        # Find files extra in mount
        comm -13 <(awk '{print $1}' /tmp/source_hash_sorted.txt) <(awk '{print $1}' /tmp/mount_hash_sorted.txt) > /tmp/extra_in_mount.txt
        # Find files with mismatched hashes
        join -j 1 /tmp/source_hash_sorted.txt /tmp/mount_hash_sorted.txt | awk '$2 != $3 {print $1}' > /tmp/mismatched_hashes.txt

        if [ -s /tmp/missing_in_mount.txt ]; then
            echo -e "${YELLOW}Files present in source but missing in mount:${NC}"
            cat /tmp/missing_in_mount.txt
        fi
        if [ -s /tmp/extra_in_mount.txt ]; then
            echo -e "${YELLOW}Files present in mount but missing in source:${NC}"
            cat /tmp/extra_in_mount.txt
        fi
        if [ -s /tmp/mismatched_hashes.txt ]; then
            echo -e "${YELLOW}Files with mismatched hashes:${NC}"
            cat /tmp/mismatched_hashes.txt
        fi

        # Show raw diff for reference
        echo -e "\n${YELLOW}Raw diff output:${NC}"
        diff <(sort "$SOURCE_HASH_FILE") <(sort "$MOUNT_HASH_FILE") || true

        # Cleanup temporary hash files
        rm -f "$SOURCE_HASH_FILE" "$MOUNT_HASH_FILE"
        rm -f /tmp/source_hash_sorted.txt /tmp/mount_hash_sorted.txt /tmp/missing_in_mount.txt /tmp/extra_in_mount.txt /tmp/mismatched_hashes.txt

        # Cleanup and exit with status 1
        cleanup_on_failure "$MOUNT_POINT" "$CONTAINER_PATH"
        exit 1
    fi
    
    info "Hash verification PASSED! All files match perfectly."
    
    # Cleanup temporary hash files
    rm -f "$SOURCE_HASH_FILE" "$MOUNT_HASH_FILE"
    
    # Step 10: Dismount and exit successfully
    dismount_veracrypt_container "$MOUNT_POINT"
    
    info "=== Backup completed successfully ==="
    info "Container location: $CONTAINER_PATH"
    
    exit 0
}

# Run main function
main "$@"
