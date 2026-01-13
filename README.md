# VeraCrypt Backup Script

A bash script that automatically creates encrypted VeraCrypt containers from monthly archived data. Perfect for automated backup workflows with cron jobs.

## Features

- 🔐 **Secure Encryption**: Creates NTFS-formatted VeraCrypt containers with AES encryption and SHA-512 hashing
- 📅 **Automatic Date Handling**: Automatically backs up previous month's data (handles year rollover correctly)
- 🔑 **Flexible Authentication**: Supports both password-based and keyfile-based authentication (single or multiple keyfiles)
- 💾 **Smart Sizing**: Automatically calculates container size based on source data + 12MB buffer
- 🔄 **Cron-Friendly**: Built-in skip mode for safe automated retries
- 📊 **Verbose Logging**: Prints every file being transferred with size information
- ⚠️ **Safety Checks**: Validates free space, checks for existing containers, and provides helpful error messages
- 🎯 **Customizable Working Directory**: Can operate in any directory structure

## Requirements

- Linux operating system
- VeraCrypt installed and available in PATH
- `ntfs-3g` package (usually pre-installed on most Linux distributions)
- `bc` calculator utility
- Bash 4.0 or higher

## Installation

1. Clone the repository:
```bash
git clone https://github.com/AndrewHamiliDevelopment/veracrypt-backup-script.git
cd veracrypt-backup-script
```

2. Make the script executable:
```bash
chmod +x veracrypt_backup.sh
```

3. Set up authentication (at least one method required, both can be used together):

**Option A - Using Password:**
```bash
export VERACRYPT_PASSWORD='YourSecurePassword123'
```

**Option B - Using Single Keyfile:**
```bash
export VERACRYPT_KEYFILES='/path/to/your/keyfile'
```

**Option C - Using Multiple Keyfiles:**
```bash
export VERACRYPT_KEYFILES='/path/to/key1,/path/to/key2,/path/to/key3'
```

**Option D - Using Both Password and Keyfiles (Maximum Security):**
```bash
export VERACRYPT_PASSWORD='YourSecurePassword123'
export VERACRYPT_KEYFILES='/path/to/your/keyfile'
```

## Usage

### Basic Syntax

```bash
./veracrypt_backup.sh [OPTIONS] [WORKING_DIRECTORY]
```

### Options

- `-f, --force` - Force overwrite if container already exists
- `-s, --skip` - Skip backup if container already exists (recommended for cron jobs)
- `-h, --help` - Show help message

### Examples

**Backup from current directory:**
```bash
export VERACRYPT_PASSWORD='MyPassword'
./veracrypt_backup.sh
```

**Backup from specific directory:**
```bash
export VERACRYPT_KEYFILES='/mnt/securekey'
./veracrypt_backup.sh /backup/data
```

**Force overwrite existing container:**
```bash
export VERACRYPT_PASSWORD='MyPassword'
./veracrypt_backup.sh --force /backup/data
```

**Skip if container exists (for cron):**
```bash
export VERACRYPT_KEYFILES='/mnt/key1,/mnt/key2'
./veracrypt_backup.sh --skip /backup/data
```

**Maximum security with both password and keyfiles:**
```bash
export VERACRYPT_PASSWORD='MyPassword'
export VERACRYPT_KEYFILES='/mnt/securekey'
./veracrypt_backup.sh /backup/data
```

## How It Works

### Directory Structure

The script expects the following directory structure:

```
/working/directory/
├── 2025/
│   ├── 01/  (January data)
│   ├── 02/  (February data)
│   ├── 11/  (November data)
│   └── 12/  (December data)
└── 2026/
    └── 01/  (January data)
```

### Workflow

When run on the 1st of each month, the script:

1. **Determines Previous Month**: Calculates previous month/year (handles year rollover)
2. **Checks Free Space**: Verifies sufficient disk space is available
3. **Validates Source Directory**: Confirms `YYYY/MM` directory exists
4. **Calculates Container Size**: Source directory size + 12MB buffer
5. **Checks Authentication**: Validates password or keyfiles are configured
6. **Creates Container**: Builds encrypted VeraCrypt container with NTFS filesystem
7. **Mounts Container**: Securely mounts the container to temporary location
8. **Copies Files**: Transfers all files while preserving timestamps
9. **Dismounts Container**: Safely dismounts and finalizes the container

### Example Timeline

| Run Date | Previous Month | Source Directory | Container Created |
|----------|---------------|------------------|-------------------|
| Dec 1, 2025 | Nov 2025 | `/backup/data/2025/11/` | `202511.imgc` |
| Jan 1, 2026 | Dec 2025 | `/backup/data/2025/12/` | `202512.imgc` |
| Feb 1, 2026 | Jan 2026 | `/backup/data/2026/01/` | `202601.imgc` |

## Automated Backups with Cron

### Method 1: Environment Variable in Cron

```cron
# Run on 1st of every month at 2:00 AM
0 2 1 * * VERACRYPT_PASSWORD='YourPassword' /path/to/veracrypt_backup.sh --skip /backup/data >> /var/log/veracrypt_backup.log 2>&1
```

### Method 2: Wrapper Script (More Secure)

Create a wrapper script `/usr/local/bin/veracrypt-backup-wrapper.sh`:

```bash
#!/bin/bash
export VERACRYPT_KEYFILES='/mnt/securekey,/root/.backup_key'
/path/to/veracrypt_backup.sh --skip /backup/data >> /var/log/veracrypt_backup.log 2>&1
```

Then in crontab:
```cron
0 2 1 * * /usr/local/bin/veracrypt-backup-wrapper.sh
```

### Method 3: Systemd Timer (Recommended for Modern Systems)

Create `/etc/systemd/system/veracrypt-backup.service`:

```ini
[Unit]
Description=VeraCrypt Monthly Backup
After=network.target

[Service]
Type=oneshot
Environment="VERACRYPT_KEYFILES=/mnt/securekey"
ExecStart=/path/to/veracrypt_backup.sh --skip /backup/data
StandardOutput=append:/var/log/veracrypt_backup.log
StandardError=append:/var/log/veracrypt_backup.log
```

Create `/etc/systemd/system/veracrypt-backup.timer`:

```ini
[Unit]
Description=Run VeraCrypt Backup on 1st of Month
Requires=veracrypt-backup.service

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start:
```bash
sudo systemctl enable veracrypt-backup.timer
sudo systemctl start veracrypt-backup.timer
```

## Authentication Methods

### Password Authentication

Set the `VERACRYPT_PASSWORD` environment variable:

```bash
export VERACRYPT_PASSWORD='YourSecurePassword123'
```

**Pros:**
- Simple to set up
- No external files needed

**Cons:**
- Password visible in process list if not careful
- Less secure than keyfiles for automated systems

### Keyfile Authentication

Set the `VERACRYPT_KEYFILES` environment variable with comma-separated paths:

```bash
# Single keyfile
export VERACRYPT_KEYFILES='/mnt/securekey'

# Multiple keyfiles
export VERACRYPT_KEYFILES='/mnt/key1,/home/user/.key2,/etc/backup.key'
```

**Pros:**
- More secure for automated backups
- Can use multiple keyfiles for added security
- No password in memory

**Cons:**
- Requires managing keyfile(s)
- Keyfiles must be accessible when script runs

### Combined Password + Keyfile Authentication

For maximum security, you can use both a password and keyfiles together:

```bash
export VERACRYPT_PASSWORD='YourSecurePassword123'
export VERACRYPT_KEYFILES='/mnt/securekey'
```

**Pros:**
- Highest level of security (layered authentication)
- Requires both something you know (password) and something you have (keyfiles)
- Even if keyfiles are compromised, password still provides protection

**Cons:**
- More complex to set up and manage
- Requires both password and keyfiles available for decryption

## Error Handling

### Common Errors

**No authentication method:**
```
[ERROR] No authentication method specified!
[ERROR] Please set VERACRYPT_PASSWORD and/or VERACRYPT_KEYFILES environment variable.
```
**Solution:** Set at least one of the authentication environment variables.

**Container already exists:**
```
[WARNING] Container '/backup/data/202511.imgc' already exists!
[ERROR] Container already exists. Use --force to overwrite or --skip to exit cleanly
```
**Solution:** Use `--skip` flag (for cron) or `--force` flag (for manual reruns).

**Directory not found:**
```
[ERROR] Directory '/backup/data/2025/11/' does not exist!
```
**Solution:** Ensure the YYYY/MM directory structure exists and contains data.

**Insufficient disk space:**
```
[ERROR] Not enough free space! Required: 500.00MB, Available: 250.00MB
```
**Solution:** Free up disk space or move to a location with more space.

**Keyfile not found:**
```
[ERROR] Keyfile does not exist: /mnt/securekey
```
**Solution:** Verify the keyfile path is correct and accessible.

## Output Example

```
[INFO] Starting VeraCrypt backup process...
[INFO] Working directory: /backup/data
[INFO] Target: Previous month's data (2025-11)
[INFO] Using keyfile authentication (1 keyfile(s))
[INFO]   - Keyfile found: /mnt/securekey
[INFO] Checking free space in working directory...
[INFO] Free space available: 10.50GB
[SUCCESS] Directory '/backup/data/2025/11/' found
[INFO] Directory size: 245.67MB
[INFO] Required container size: 257.67MB
[SUCCESS] Sufficient free space available
[INFO] Creating VeraCrypt container with NTFS filesystem...
[SUCCESS] VeraCrypt container created successfully
[SUCCESS] Container mounted successfully
[INFO] Transfer log:

[FILE] Creating directory: documents
[FILE] Copied: documents/report.pdf (2.5MB)
[FILE] Copied: documents/notes.txt (15.3KB)
[FILE] Creating directory: images
[FILE] Copied: images/photo1.jpg (4.2MB)
[FILE] Copied: images/photo2.jpg (3.8MB)

[SUCCESS] All files copied successfully
[SUCCESS] Volume dismounted successfully
[SUCCESS] Backup process completed successfully!
[INFO] Container location: /backup/data/202511.imgc
[INFO] Container size: 257.67MB
```

## Security Considerations

1. **Keyfile Storage**: Store keyfiles on separate, secure media (USB drives, encrypted partitions)
2. **File Permissions**: Restrict script permissions:
   ```bash
   chmod 700 veracrypt_backup.sh
   chown root:root veracrypt_backup.sh
   ```
3. **Log Files**: Ensure log files have appropriate permissions:
   ```bash
   chmod 600 /var/log/veracrypt_backup.log
   ```
4. **Environment Variables**: In production, avoid storing passwords in plain text. Use keyfiles or secure credential management systems.
5. **Container Storage**: Store created containers on encrypted or physically secure storage.

## Troubleshooting

### VeraCrypt Not Found

```bash
# Install VeraCrypt on Ubuntu/Debian
sudo add-apt-repository ppa:unit193/encryption
sudo apt update
sudo apt install veracrypt

# Or download from official website
wget https://launchpad.net/veracrypt/trunk/1.25.9/+download/veracrypt-1.25.9-Ubuntu-22.04-amd64.deb
sudo dpkg -i veracrypt-*.deb
```

### NTFS Support Missing

```bash
# Ubuntu/Debian
sudo apt-get install ntfs-3g

# RHEL/CentOS/Fedora
sudo yum install ntfs-3g
```

### Permission Denied

Run with appropriate permissions or use sudo:
```bash
sudo ./veracrypt_backup.sh /backup/data
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is open source and available under the MIT License.

## Author

Created by Andrew Hamili

## Support

For issues, questions, or contributions, please visit:
https://github.com/AndrewHamiliDevelopment/veracrypt-backup-script/issues
