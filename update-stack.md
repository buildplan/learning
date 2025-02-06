## Update Docker Pangolin Stack with a few commonds.

### This can also make a backup of whole stack with a single commond - use with `sudo`

```
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
