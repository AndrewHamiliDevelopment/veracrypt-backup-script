#!/bin/bash

set -e  # Exit on error
set -u  # Exit on undefined variable

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_file() {
    echo -e "${BLUE}[FILE]${NC} $1"
}

# Function to show usage
usage() {
    echo "Usage: $0 [OPTIONS] [WORKING_DIRECTORY]"
    echo ""
    echo "Arguments:"
    echo "  WORKING_DIRECTORY    Optional. The base directory where YYYY/MM folders are located."
    echo "                       Defaults to current directory if not specified."
    echo ""
    echo "Options:"
    echo "  -f, --force          Force overwrite if container already exists"
    echo "  -s, --skip           Skip backup if container already exists (useful for cron)"
    echo "  -p, --path PATH      Back up a specific file or directory path directly (bypasses YYYY/MM layout)"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Environment Variables (REQUIRED - must set at least ONE):"
    echo "  VERACRYPT_PASSWORD   Password string for container encryption"
    echo "  VERACRYPT_KEYFILES   Comma-separated paths to keyfiles (e.g., /path/key1,/path/key2)"
    echo ""
    echo "  Note: Both VERACRYPT_PASSWORD and VERACRYPT_KEYFILES can be set together for layered"
    echo "        authentication. The script will use both password and keyfiles when mounting."
    echo ""
    echo "Examples:"
    echo "  # Password-only authentication"
    echo "  export VERACRYPT_PASSWORD='MySecurePassword123'"
    echo "  $0 /backup/data"
    echo ""
    echo "  # Keyfile-only authentication"
    echo "  export VERACRYPT_KEYFILES='/mnt/securekey,/home/user/.key2'"
    echo "  $0 --skip /backup/data"
    echo ""
    echo "  # Layered authentication (password + keyfiles)"
    echo "  export VERACRYPT_PASSWORD='MySecurePassword123'"
    echo "  export VERACRYPT_KEYFILES='/mnt/securekey'"
    echo "  $0 /backup/data"
    echo ""
    echo "  # Back up a specific path directly"
    echo "  export VERACRYPT_PASSWORD='MySecurePassword123'"
    echo "  $0 --path /home/user/important-docs"
    echo ""
    echo "  # Back up a specific file"
    echo "  export VERACRYPT_KEYFILES='/mnt/securekey'"
    echo "  $0 --path /home/user/database.sql --force"
    echo ""
    exit 1
}

# Parse command line arguments
FORCE_OVERWRITE=false
SKIP_IF_EXISTS=false
WORKING_DIR=""
EXACT_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        -f|--force)
            FORCE_OVERWRITE=true
            shift
            ;;
        -s|--skip)
            SKIP_IF_EXISTS=true
            shift
            ;;
        -p|--path)
            if [ -z "${2:-}" ]; then
                print_error "Option $1 requires an argument"
                usage
            fi
            EXACT_PATH="$2"
            shift 2
            ;;
        -*)
            print_error "Unknown option: $1"
            usage
            ;;
        *)
            if [ -z "$WORKING_DIR" ]; then
                WORKING_DIR="$1"
            else
                print_error "Multiple working directories specified!"
                usage
            fi
            shift
            ;;
    esac
done

# Check for conflicting options
if [ "$FORCE_OVERWRITE" = true ] && [ "$SKIP_IF_EXISTS" = true ]; then
    print_error "Cannot use both --force and --skip options together!"
    exit 1
fi

# Validate authentication method
USE_PASSWORD=false
USE_KEYFILES=false
KEYFILES_ARRAY=()

if [ -n "${VERACRYPT_PASSWORD:-}" ] && [ -n "${VERACRYPT_KEYFILES:-}" ]; then
    # Both authentication methods provided - use layered authentication
    USE_PASSWORD=true
    USE_KEYFILES=true
    IFS=',' read -ra KEYFILES_ARRAY <<< "$VERACRYPT_KEYFILES"
    print_info "Using layered authentication (password + ${#KEYFILES_ARRAY[@]} keyfile(s))"
    
    # Validate each keyfile exists
    for keyfile in "${KEYFILES_ARRAY[@]}"; do
        # Trim whitespace
        keyfile=$(echo "$keyfile" | xargs)
        if [ ! -f "$keyfile" ]; then
            print_error "Keyfile does not exist: $keyfile"
            exit 1
        fi
        print_info "  - Keyfile found: $keyfile"
    done
elif [ -n "${VERACRYPT_PASSWORD:-}" ]; then
    USE_PASSWORD=true
    print_info "Using password authentication"
elif [ -n "${VERACRYPT_KEYFILES:-}" ]; then
    USE_KEYFILES=true
    # Split comma-separated keyfiles into array
    IFS=',' read -ra KEYFILES_ARRAY <<< "$VERACRYPT_KEYFILES"
    print_info "Using keyfile authentication (${#KEYFILES_ARRAY[@]} keyfile(s))"
    
    # Validate each keyfile exists
    for keyfile in "${KEYFILES_ARRAY[@]}"; do
        # Trim whitespace
        keyfile=$(echo "$keyfile" | xargs)
        if [ ! -f "$keyfile" ]; then
            print_error "Keyfile does not exist: $keyfile"
            exit 1
        fi
        print_info "  - Keyfile found: $keyfile"
    done
else
    print_error "No authentication method specified!"
    print_error "Please set VERACRYPT_PASSWORD and/or VERACRYPT_KEYFILES environment variable."
    echo ""
    echo "Examples:"
    echo "  export VERACRYPT_PASSWORD='MySecurePassword123'"
    echo "  export VERACRYPT_KEYFILES='/mnt/securekey'"
    echo "  export VERACRYPT_KEYFILES='/mnt/key1,/mnt/key2,/home/user/.key3'"
    echo ""
    echo "  # For layered authentication, set both:"
    echo "  export VERACRYPT_PASSWORD='MySecurePassword123'"
    echo "  export VERACRYPT_KEYFILES='/mnt/securekey'"
    exit 1
fi

# Mode flag: exact path mode vs. YYYY/MM directory mode
EXACT_PATH_MODE=false

# If --path is provided, it takes precedence over WORKING_DIRECTORY
if [ -n "$EXACT_PATH" ]; then
    EXACT_PATH_MODE=true
    
    # Validate exact path exists
    if [ ! -e "$EXACT_PATH" ]; then
        print_error "Path '$EXACT_PATH' does not exist!"
        exit 1
    fi
    
    # Convert to absolute path
    if [ -d "$EXACT_PATH" ]; then
        EXACT_PATH="$(cd "$EXACT_PATH" && pwd)"
    else
        EXACT_PATH="$(cd "$(dirname "$EXACT_PATH")" && pwd)/$(basename "$EXACT_PATH")"
    fi
    
    # Determine container directory (where to save the container)
    if [ -n "$WORKING_DIR" ]; then
        # If WORKING_DIR is provided alongside --path, use it as the output directory
        if [ ! -d "$WORKING_DIR" ]; then
            print_error "Output directory '$WORKING_DIR' does not exist!"
            exit 1
        fi
        CONTAINER_DIR="$(cd "$WORKING_DIR" && pwd)"
    else
        # Default: save container in the same directory as the path (or parent if it's a file)
        if [ -d "$EXACT_PATH" ]; then
            CONTAINER_DIR="$(dirname "$EXACT_PATH")"
        else
            CONTAINER_DIR="$(dirname "$EXACT_PATH")"
        fi
    fi
    
    # Determine container name based on basename and current YYYYMM
    BASENAME=$(basename "$EXACT_PATH")
    CURRENT_YYYYMM=$(date +%Y%m)
    CONTAINER_NAME="${CONTAINER_DIR}/${BASENAME}-${CURRENT_YYYYMM}.imgc"
    TARGET_DIR="$EXACT_PATH"
    
    MOUNT_POINT="/tmp/veracrypt_mount_$$"
else
    # Set default working directory if not specified (only for YYYY/MM mode)
    if [ -z "$WORKING_DIR" ]; then
        WORKING_DIR="$(pwd)"
    fi
    
    # Validate working directory for YYYY/MM mode
    if [ ! -d "$WORKING_DIR" ]; then
        print_error "Working directory '$WORKING_DIR' does not exist!"
        exit 1
    fi
    
    # Convert to absolute path
    WORKING_DIR="$(cd "$WORKING_DIR" && pwd)"
    
    # Get previous month and year
    # This handles year rollover correctly (e.g., if current is January, previous is December of last year)
    PREV_MONTH=$(date -d "last month" +%m)
    PREV_YEAR=$(date -d "last month" +%Y)
    
    TARGET_DIR="${WORKING_DIR}/${PREV_YEAR}/${PREV_MONTH}"
    CONTAINER_NAME="${WORKING_DIR}/${PREV_YEAR}${PREV_MONTH}.imgc"
    MOUNT_POINT="/tmp/veracrypt_mount_$$"
fi

# Cleanup function
cleanup() {
    if [ -d "$MOUNT_POINT" ]; then
        print_info "Cleaning up mount point..."
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Function to get directory size in KB
get_dir_size() {
    du -sk "$1" | cut -f1
}

# Function to get free space in KB
get_free_space() {
    df -k "$1" | tail -1 | awk '{print $4}'
}

# Function to get file size in a human-readable format
get_human_size() {
    local size_kb=$1
    if [ "$size_kb" -lt 1024 ]; then
        echo "${size_kb}KB"
    elif [ "$size_kb" -lt 1048576 ]; then
        echo "$(echo "scale=2; $size_kb/1024" | bc)MB"
    else
        echo "$(echo "scale=2; $size_kb/1048576" | bc)GB"
    fi
}

# Main script starts here
print_info "Starting VeraCrypt backup process..."

if [ "$EXACT_PATH_MODE" = true ]; then
    print_info "Mode: Exact path backup"
    print_info "Source path: $TARGET_DIR"
    print_info "Container: $CONTAINER_NAME"
else
    print_info "Mode: YYYY/MM directory backup"
    print_info "Working directory: $WORKING_DIR"
    print_info "Target: Previous month's data (${PREV_YEAR}-${PREV_MONTH})"
fi

# Step 1: Check free space in the container output directory
if [ "$EXACT_PATH_MODE" = true ]; then
    print_info "Checking free space in output directory..."
    FREE_SPACE=$(get_free_space "$CONTAINER_DIR")
else
    print_info "Checking free space in working directory..."
    FREE_SPACE=$(get_free_space "$WORKING_DIR")
fi
print_info "Free space available: $(get_human_size $FREE_SPACE)"

# Step 2: Check if source exists
if [ "$EXACT_PATH_MODE" = true ]; then
    # In exact path mode, TARGET_DIR can be a file or directory
    if [ -d "$TARGET_DIR" ]; then
        print_info "Checking if directory '$TARGET_DIR' exists..."
        print_success "Directory '$TARGET_DIR' found"
    elif [ -f "$TARGET_DIR" ]; then
        print_info "Checking if file '$TARGET_DIR' exists..."
        print_success "File '$TARGET_DIR' found"
    else
        print_error "Path '$TARGET_DIR' does not exist!"
        exit 1
    fi
else
    # In YYYY/MM mode, TARGET_DIR must be a directory
    print_info "Checking if directory '$TARGET_DIR' exists..."
    if [ ! -d "$TARGET_DIR" ]; then
        print_error "Directory '$TARGET_DIR' does not exist!"
        exit 1
    fi
    print_success "Directory '$TARGET_DIR' found"
fi

# Step 3: Calculate size and compare with free space
if [ -d "$TARGET_DIR" ]; then
    print_info "Calculating size of '$TARGET_DIR'..."
    DIR_SIZE=$(get_dir_size "$TARGET_DIR")
    print_info "Directory size: $(get_human_size $DIR_SIZE)"
else
    # It's a file
    print_info "Calculating size of '$TARGET_DIR'..."
    FILE_SIZE_BYTES=$(stat -c "%s" "$TARGET_DIR" 2>/dev/null || stat -f "%z" "$TARGET_DIR" 2>/dev/null)
    DIR_SIZE=$((FILE_SIZE_BYTES / 1024))
    # Ensure at least 1 KB
    [ "$DIR_SIZE" -lt 1 ] && DIR_SIZE=1
    print_info "File size: $(get_human_size $DIR_SIZE)"
fi

# Calculate required container size (directory size + 12MB in KB)
ADDITIONAL_SIZE=$((12 * 1024))  # 12MB in KB
CONTAINER_SIZE=$((DIR_SIZE + ADDITIONAL_SIZE))
print_info "Required container size: $(get_human_size $CONTAINER_SIZE)"

# Check if we have enough free space
if [ "$FREE_SPACE" -le "$CONTAINER_SIZE" ]; then
    print_error "Not enough free space! Required: $(get_human_size $CONTAINER_SIZE), Available: $(get_human_size $FREE_SPACE)"
    exit 1
fi
print_success "Sufficient free space available"

# Check if container already exists
if [ -f "$CONTAINER_NAME" ]; then
    EXISTING_SIZE=$(stat -c "%s" "$CONTAINER_NAME" 2>/dev/null || stat -f "%z" "$CONTAINER_NAME" 2>/dev/null)
    EXISTING_SIZE_KB=$((EXISTING_SIZE / 1024))
    EXISTING_DATE=$(stat -c "%y" "$CONTAINER_NAME" 2>/dev/null || stat -f "%Sm" "$CONTAINER_NAME" 2>/dev/null)
    
    print_warning "Container '$CONTAINER_NAME' already exists!"
    print_info "Existing container size: $(get_human_size $EXISTING_SIZE_KB)"
    print_info "Existing container date: $EXISTING_DATE"
    
    if [ "$SKIP_IF_EXISTS" = true ]; then
        print_success "Skip mode enabled - exiting successfully without overwriting"
        exit 0
    elif [ "$FORCE_OVERWRITE" = true ]; then
        print_warning "Force mode enabled - removing existing container..."
        rm -f "$CONTAINER_NAME"
        print_success "Existing container removed"
    else
        print_error "Container already exists. Use --force to overwrite or --skip to exit cleanly"
        print_info "Suggested actions:"
        print_info "  - Run with --skip flag for safe cron retry: $0 --skip $WORKING_DIR"
        print_info "  - Run with --force flag to overwrite: $0 --force $WORKING_DIR"
        print_info "  - Manually inspect/remove: $CONTAINER_NAME"
        exit 1
    fi
fi

# Step 4: Create VeraCrypt container
print_info "Creating VeraCrypt container '$CONTAINER_NAME' with NTFS filesystem..."
# Convert KB to bytes for VeraCrypt (multiply by 1024)
CONTAINER_SIZE_BYTES=$((CONTAINER_SIZE * 1024))

if [ "$USE_PASSWORD" = true ] && [ "$USE_KEYFILES" = true ]; then
    # Use layered authentication (password + keyfiles)
    KEYFILES_PARAM=$(IFS=, ; echo "${KEYFILES_ARRAY[*]}")
    echo -n "$VERACRYPT_PASSWORD" | veracrypt --text \
        --create "$CONTAINER_NAME" \
        --volume-type=normal \
        --size="$CONTAINER_SIZE_BYTES" \
        --encryption=AES \
        --hash=sha512 \
        --filesystem=NTFS \
        --keyfiles="$KEYFILES_PARAM" \
        --pim=0 \
        --random-source=/dev/urandom \
        --stdin \
        --non-interactive
elif [ "$USE_PASSWORD" = true ]; then
    # Use password authentication only
    echo -n "$VERACRYPT_PASSWORD" | veracrypt --text \
        --create "$CONTAINER_NAME" \
        --volume-type=normal \
        --size="$CONTAINER_SIZE_BYTES" \
        --encryption=AES \
        --hash=sha512 \
        --filesystem=NTFS \
        --pim=0 \
        --random-source=/dev/urandom \
        --stdin \
        --non-interactive
else
    # Use keyfile authentication only
    KEYFILES_PARAM=$(IFS=, ; echo "${KEYFILES_ARRAY[*]}")
    veracrypt --text \
        --create "$CONTAINER_NAME" \
        --volume-type=normal \
        --size="$CONTAINER_SIZE_BYTES" \
        --encryption=AES \
        --hash=sha512 \
        --filesystem=NTFS \
        --keyfiles="$KEYFILES_PARAM" \
        --pim=0 \
        --random-source=/dev/urandom \
        -k "" \
        --non-interactive
fi

if [ $? -eq 0 ]; then
    print_success "VeraCrypt container created successfully"
else
    print_error "Failed to create VeraCrypt container"
    exit 1
fi

# Create mount point
print_info "Creating mount point..."
mkdir -p "$MOUNT_POINT"

# Mount the container
print_info "Mounting VeraCrypt container..."

if [ "$USE_PASSWORD" = true ] && [ "$USE_KEYFILES" = true ]; then
    # Mount with layered authentication (password + keyfiles)
    KEYFILES_PARAM=$(IFS=, ; echo "${KEYFILES_ARRAY[*]}")
    echo -n "$VERACRYPT_PASSWORD" | veracrypt --text \
        --keyfiles="$KEYFILES_PARAM" \
        --pim=0 \
        --protect-hidden=no \
        --stdin \
        "$CONTAINER_NAME" \
        "$MOUNT_POINT"
elif [ "$USE_PASSWORD" = true ]; then
    # Mount with password only
    echo -n "$VERACRYPT_PASSWORD" | veracrypt --text \
        --pim=0 \
        --protect-hidden=no \
        --stdin \
        "$CONTAINER_NAME" \
        "$MOUNT_POINT"
else
    # Mount with keyfiles only
    KEYFILES_PARAM=$(IFS=, ; echo "${KEYFILES_ARRAY[*]}")
    veracrypt --text \
        --keyfiles="$KEYFILES_PARAM" \
        --pim=0 \
        --protect-hidden=no \
        -k "" \
        "$CONTAINER_NAME" \
        "$MOUNT_POINT"
fi

if [ $? -eq 0 ]; then
    print_success "Container mounted successfully at '$MOUNT_POINT'"
else
    print_error "Failed to mount container"
    exit 1
fi

# Copy files preserving timestamps and print each file
print_info "Copying from '$TARGET_DIR' to container..."
print_info "Transfer log:"
echo ""

if [ -d "$TARGET_DIR" ]; then
    # TARGET_DIR is a directory - copy contents
    # Count total files and directories
    TOTAL_ITEMS=$(find "$TARGET_DIR" -mindepth 1 | wc -l)
    print_info "Total items to transfer: $TOTAL_ITEMS"
    echo ""
    
    # Copy with verbose output showing each file
    find "$TARGET_DIR" -mindepth 1 | while read -r item; do
        RELATIVE_PATH="${item#$TARGET_DIR/}"
        
        if [ -d "$item" ]; then
            # Create directory
            mkdir -p "$MOUNT_POINT/$RELATIVE_PATH"
            print_file "Creating directory: $RELATIVE_PATH"
        elif [ -f "$item" ]; then
            # Copy file with timestamp preservation
            cp --preserve=timestamps "$item" "$MOUNT_POINT/$RELATIVE_PATH"
            FILE_SIZE=$(stat -f "%z" "$item" 2>/dev/null || stat -c "%s" "$item" 2>/dev/null)
            if [ -n "$FILE_SIZE" ]; then
                if [ "$FILE_SIZE" -lt 1024 ]; then
                    SIZE_STR="${FILE_SIZE}B"
                elif [ "$FILE_SIZE" -lt 1048576 ]; then
                    SIZE_STR="$(echo "scale=2; $FILE_SIZE/1024" | bc)KB"
                else
                    SIZE_STR="$(echo "scale=2; $FILE_SIZE/1048576" | bc)MB"
                fi
                print_file "Copied: $RELATIVE_PATH ($SIZE_STR)"
            else
                print_file "Copied: $RELATIVE_PATH"
            fi
        fi
    done
else
    # TARGET_DIR is a single file - copy the file
    FILENAME=$(basename "$TARGET_DIR")
    print_info "Total items to transfer: 1"
    echo ""
    
    cp --preserve=timestamps "$TARGET_DIR" "$MOUNT_POINT/$FILENAME"
    FILE_SIZE=$(stat -f "%z" "$TARGET_DIR" 2>/dev/null || stat -c "%s" "$TARGET_DIR" 2>/dev/null)
    if [ -n "$FILE_SIZE" ]; then
        if [ "$FILE_SIZE" -lt 1024 ]; then
            SIZE_STR="${FILE_SIZE}B"
        elif [ "$FILE_SIZE" -lt 1048576 ]; then
            SIZE_STR="$(echo "scale=2; $FILE_SIZE/1024" | bc)KB"
        else
            SIZE_STR="$(echo "scale=2; $FILE_SIZE/1048576" | bc)MB"
        fi
        print_file "Copied: $FILENAME ($SIZE_STR)"
    else
        print_file "Copied: $FILENAME"
    fi
fi

COPY_EXIT_CODE=$?

echo ""
if [ $COPY_EXIT_CODE -eq 0 ]; then
    print_success "All files copied successfully"
else
    print_error "Failed to copy some files"
    # Attempt to dismount before exiting
    veracrypt --text --dismount "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi

# Step 5: Dismount the volume
print_info "Dismounting VeraCrypt volume..."
veracrypt --text --dismount "$MOUNT_POINT"

if [ $? -eq 0 ]; then
    print_success "Volume dismounted successfully"
else
    print_error "Failed to dismount volume"
    exit 1
fi

print_success "Backup process completed successfully!"
print_info "Container location: $CONTAINER_NAME"
print_info "Container size: $(get_human_size $CONTAINER_SIZE)"

exit 0
