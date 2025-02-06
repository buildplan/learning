## Update Docker Pangolin Stack with a few commonds.

### This can also make a backup of whole stack with a single commond - use with `sudo`
### This can also send alerts on Discord with Discord Webhook API. 


```bash
#!/usr/bin/env bash

# Set strict error handling for better script safety
set -euo pipefail
IFS=$'\n\t'

# Core configuration variables
readonly BACKUP_BASE_DIR="./backups"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"
readonly CONFIG_DIR="./config"
readonly SERVICES=("pangolin" "gerbil" "traefik")

# Initialize backup directory for update operations
init_backup_dir() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    readonly BACKUP_DIR="${BACKUP_BASE_DIR}/${timestamp}"
    readonly LOG_FILE="${BACKUP_DIR}/update.log"
    readonly OLD_TAGS_FILE="${BACKUP_DIR}/old_tags.txt"
    
    mkdir -p "${BACKUP_DIR}"
    touch "${LOG_FILE}"
}

# Initialize logging for restore operations (without creating backup directory)
init_logging() {
    readonly LOG_FILE="/tmp/restore_$$.log"
    touch "${LOG_FILE}"
}

# Unified logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [%s] %s\n' "${timestamp}" "${level}" "${message}" | tee -a "${LOG_FILE}"
}

# Simple service status check
verify_services() {
    log "INFO" "Verifying services status..."
    
    local service_status
    service_status=$(docker compose ps)
    log "INFO" "Current service status:"
    echo "$service_status" | tee -a "${LOG_FILE}"
    
    local all_services_up=true
    for service in "${SERVICES[@]}"; do
        if ! docker compose ps "$service" | grep -q "Up"; then
            log "ERROR" "Service $service is not running"
            all_services_up=false
        fi
    done
    
    if [ "$all_services_up" = false ]; then
        log "ERROR" "Not all services are running"
        return 1
    fi
    
    log "INFO" "All services are running"
    return 0
}

# Extract current image tags
get_current_tags() {
    log "INFO" "Reading current image tags..."
    
    extract_tag() {
        local image_pattern=$1
        local tag
        tag=$(grep "image: $image_pattern" "${DOCKER_COMPOSE_FILE}" | head -n1 | awk -F: '{print $NF}' | tr -d ' "' || echo "")
        if [ -z "$tag" ]; then
            log "ERROR" "Failed to extract tag for $image_pattern"
            exit 1
        fi
        echo "$tag"
    }
    
    PANGOLIN_CURRENT=$(extract_tag "fosrl/pangolin")
    GERBIL_CURRENT=$(extract_tag "fosrl/gerbil")
    TRAEFIK_CURRENT=$(extract_tag "traefik")
}

# Interactive tag selection
get_new_tags() {
    log "INFO" "Requesting new image tags from user..."
    
    echo -e "\nCurrent versions:"
    echo "------------------------"
    
    echo "Current Pangolin tag: ${PANGOLIN_CURRENT}"
    read -p "Enter new Pangolin tag (or press enter to keep current): " PANGOLIN_NEW
    PANGOLIN_NEW=${PANGOLIN_NEW:-${PANGOLIN_CURRENT}}
    
    echo "Current Gerbil tag: ${GERBIL_CURRENT}"
    read -p "Enter new Gerbil tag (or press enter to keep current): " GERBIL_NEW
    GERBIL_NEW=${GERBIL_NEW:-${GERBIL_CURRENT}}
    
    echo "Current Traefik tag: ${TRAEFIK_CURRENT}"
    read -p "Enter new Traefik tag (or press enter to keep current): " TRAEFIK_NEW
    TRAEFIK_NEW=${TRAEFIK_NEW:-${TRAEFIK_CURRENT}}
    
    echo -e "\nSummary of changes:"
    echo "------------------------"
    echo "Pangolin: ${PANGOLIN_CURRENT} -> ${PANGOLIN_NEW}"
    echo "Gerbil: ${GERBIL_CURRENT} -> ${GERBIL_NEW}"
    echo "Traefik: ${TRAEFIK_CURRENT} -> ${TRAEFIK_NEW}"
    echo "------------------------"
    
    read -p "Proceed with these changes? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log "INFO" "Update cancelled by user"
        exit 1
    fi
}

# Graceful service shutdown
graceful_shutdown() {
    log "INFO" "Starting graceful shutdown of services..."
    docker compose stop -t 30
    docker compose down --timeout 1
    log "INFO" "Services stopped"
}

# Create backup of current state
create_backup() {
    log "INFO" "Starting backup process..."
    
    log "INFO" "Saving current image tags..."
    grep "image:" "${DOCKER_COMPOSE_FILE}" > "${OLD_TAGS_FILE}"
    
    if [ -d "./config" ]; then
        log "INFO" "Backing up config directory..."
        cp -r "./config" "${BACKUP_DIR}/"
    fi
    
    cp "${DOCKER_COMPOSE_FILE}" "${BACKUP_DIR}/"
    
    log "INFO" "Backup completed successfully"
}

# Update service images
update_images() {
    log "INFO" "Starting update process..."
    
    graceful_shutdown
    
    log "INFO" "Updating image tags..."
    local tmp_file
    tmp_file=$(mktemp)
    
    cp "${DOCKER_COMPOSE_FILE}" "$tmp_file"
    
    if [ -n "${PANGOLIN_NEW}" ]; then
        sed -i "s|image: fosrl/pangolin:${PANGOLIN_CURRENT}|image: fosrl/pangolin:${PANGOLIN_NEW}|g" "$tmp_file"
    fi
    
    if [ -n "${GERBIL_NEW}" ]; then
        sed -i "s|image: fosrl/gerbil:${GERBIL_CURRENT}|image: fosrl/gerbil:${GERBIL_NEW}|g" "$tmp_file"
    fi
    
    if [ -n "${TRAEFIK_NEW}" ]; then
        sed -i "s|image: traefik:${TRAEFIK_CURRENT}|image: traefik:${TRAEFIK_NEW}|g" "$tmp_file"
    fi
    
    mv "$tmp_file" "${DOCKER_COMPOSE_FILE}"
    
    log "INFO" "Pulling new images..."
    docker compose pull
    
    log "INFO" "Starting updated stack..."
    docker compose up -d
    
    sleep 10  # Give services time to start
    verify_services
}

# Validate backup directory contents
validate_backup() {
    local backup_dir="$1"
    
    if [ ! -d "${backup_dir}" ] || [ ! -r "${backup_dir}" ]; then
        log "ERROR" "Invalid or unreadable backup directory: ${backup_dir}"
        return 1
    fi
    
    if [ ! -f "${backup_dir}/docker-compose.yml" ] || [ ! -r "${backup_dir}/docker-compose.yml" ]; then
        log "ERROR" "Missing or unreadable docker-compose.yml"
        return 1
    fi
    
    if [ ! -d "${backup_dir}/config" ] || [ ! -r "${backup_dir}/config" ]; then
        log "ERROR" "Missing or unreadable config backup"
        return 1
    fi
    
    return 0
}

# Restore from backup
restore_backup() {
    local backup_dir="$1"
    
    log "INFO" "Starting restoration process from ${backup_dir}"
    
    if ! validate_backup "${backup_dir}"; then
        log "ERROR" "Backup validation failed"
        return 1
    fi
    
    graceful_shutdown
    
    log "INFO" "Restoring files..."
    if [ -d "${CONFIG_DIR}" ]; then
        rm -rf "${CONFIG_DIR}"
    fi
    
    cp -r "${backup_dir}/config" "./"
    cp "${backup_dir}/docker-compose.yml" "./"
    
    log "INFO" "Starting restored services..."
    docker compose up -d
    
    sleep 10  # Give services time to start
    verify_services
}

# Find the most recent backup
find_latest_backup() {
    local latest_backup
    latest_backup=$(find "${BACKUP_BASE_DIR}" -mindepth 1 -maxdepth 1 -type d -name "2*" | sort -r | head -n 1)
    
    if [ -z "${latest_backup}" ]; then
        log "ERROR" "No valid backup found in ${BACKUP_BASE_DIR}"
        return 1
    fi
    
    echo "${latest_backup}"
}


# Discord Webhook URL (REPLACE with your actual webhook URL)
readonly DISCORD_WEBHOOK="https://DISCORD_WEBHOOK_URL"

# Function to send Discord notification
send_discord_notification() {
    local message="$1"
    curl -H "Content-Type: application/json" -X POST -d '{"content": "'"$message"'"}' "$DISCORD_WEBHOOK"
}

# Main execution
main() {
    # Send notification at the beginning of the script
    send_discord_notification "Script execution started."

    case "${1:-}" in
        "update")
            init_backup_dir
            get_current_tags
            get_new_tags
            create_backup
            if ! update_images; then
                log "ERROR" "Update failed"
                send_discord_notification "Update failed." # Send notification on failure
                exit 1
            fi
            log "INFO" "Update completed successfully"
            send_discord_notification "Update completed successfully." # Send notification on success
            ;;
        "restore")
            init_logging
            local backup_dir
            if [ -n "${2:-}" ]; then
                backup_dir="$2"
            else
                backup_dir=$(find_latest_backup)
                if [ $? -ne 0 ]; then
                    log "ERROR" "Failed to find latest backup"
                    send_discord_notification "Restore failed: Could not find backup."
                    exit 1
                fi
            fi
            
            if ! validate_backup "${backup_dir}"; then
                log "ERROR" "Invalid backup directory specified: ${backup_dir}"
                send_discord_notification "Restore failed: Invalid backup directory."
                exit 1
            fi
            
            if ! restore_backup "${backup_dir}"; then
                log "ERROR" "Restoration failed"
                send_discord_notification "Restore failed."
                exit 1
            fi
            log "INFO" "Restoration completed successfully"
            send_discord_notification "Restore completed successfully."
            ;;
        "backup")
            init_backup_dir
            get_current_tags
            create_backup
            log "INFO" "Backup created successfully"
            send_discord_notification "Backup created successfully."
            ;;
        *)
            log "ERROR" "Usage: $0 {update|restore|backup [backup_dir]}"
            send_discord_notification "Invalid script usage."
            exit 1
            ;;
    esac

    # Send notification at the end of the script (if it reaches here)
    send_discord_notification "Script execution finished."
}

# Execute main if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

```


2.  Make it executable:

```
chmod +x update-stack.sh
```

#### Core Features

The script provides two main functions:

1.  **Update Mode**: Safely updates your services to new versions while creating backups
2.  **Restore Mode**: Returns your stack to a previous working state

Each operation includes built-in safety checks and comprehensive logging.

#### Updating Your Stack

To update your Pangolin stack, follow these steps:

1.  Start the update process:

```
./update-stack.sh update
```

2.  You’ll see your current versions displayed:

```
Current versions:
------------------------
Current Pangolin tag: 1.0.0-beta.9
Current Gerbil tag: 1.0.0-beta.3
Current Traefik tag: v3.1
```

3.  For each service, you can:
    
    -   Press Enter to keep the current version
    -   Type a new version number to upgrade/downgrade
4.  Review the summary of changes:
    

```
Summary of changes:
------------------------
Pangolin: 1.0.0-beta.9 -> 1.0.0-beta.10
Gerbil: 1.0.0-beta.3 -> 1.0.0-beta.3
Traefik: v3.1 -> v3.2
------------------------
```

5.  Confirm the changes by typing ‘y’ when prompted

During the update, the script will:

-   Create a timestamped backup
-   Safely stop all services
-   Update the specified versions
-   Restart the stack
-   Verify all services are running properly

#### Restoring Your Stack

You have two options for restoration:

1.  Restore to the most recent backup:

```
./update-stack.sh restore
```

2.  Restore to a specific backup:

```
./update-stack.sh restore ./backups/20250205_062549
```

The restoration process:

1.  Validates the backup’s integrity
2.  Gracefully stops current services
3.  Restores configuration files
4.  Restarts the stack with the backup’s settings
5.  Verifies service health

#### Understanding Backups

Each backup is stored in the `./backups` directory with a timestamp format (e.g., `20250205_062549`). A backup contains:

-   `docker-compose.yml`: The complete stack configuration
-   `config/`: All configuration files
-   `update.log`: Detailed operation logs
-   `old_tags.txt`: Record of service versions

You can also do a manual backup of your stack any time by running this:

```
./update-stack.sh backup
```

#### Best Practices

To get the most out of the script, follow these guidelines:

**Before Updates**

1.  Review release notes for the new versions
2.  Test updates in a non-production environment first
3.  Ensure you have enough disk space for backups
4.  Document any custom configurations

**During Operations**

1.  Never interrupt the script during execution
2.  Monitor the logs for any warnings or errors
3.  Wait for the final verification step to complete

**Backup Management**

1.  Keep at least three recent backups
2.  Regularly test restore operations
3.  Clean up old backups periodically
4.  Store critical backups in a separate location

**Troubleshooting Guide**

If you encounter issues, follow these steps:

**Update Failed**

1.  Check the logs in `./backups/[timestamp]/update.log`
2.  Verify Docker has enough resources
3.  Ensure all image versions exist in the registry
4.  Try restoring to the previous state

**Restore Failed**

1.  Verify the backup directory exists and is complete
2.  Check file permissions
3.  Ensure enough disk space is available
4.  Review service logs: `docker compose logs`

Common Error Solutions:

```
# If services won't start
docker compose logs

# If permission errors occur
sudo chown -R $(id -u):$(id -g) ./backups

# If cleanup is needed
docker system prune
```

**Maintenance Tasks**

Regular maintenance helps keep your system healthy:

**Clean Old Backups**

```
# Remove backups older than 30 days
find ./backups -type d -mtime +30 -exec rm -rf {} +
```
**Remove Unused Images**

```
# Clean up old Docker images
docker image prune -a --filter "until=168h"
```

**Verify Backup Integrity**

```
# List and check recent backups
ls -ltr ./backups/
./update-stack.sh restore ./backups/[timestamp] # Test restore
```
**Logging and Monitoring**

The script maintains detailed logs of all operations:

-   **Update Logs**: `./backups/[timestamp]/update.log`
-   **Restore Logs**: `/tmp/restore_[pid].log`

Monitor these logs for:

-   Service state changes
-   Error messages
-   Version changes
-   Operation timing

**Security Considerations**

The script includes several security features:

1.  Validates input parameters
2.  Uses secure file permissions
3.  Implements graceful shutdowns
4.  Maintains operation logs
5.  Verifies service healt
