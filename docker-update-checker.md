
## Implement the ability to monitor docker containers, check logs and Discord alets.


```bash
#!/bin/bash

# --- Configuration ---
DISCORD_WEBHOOK_URL="YOUR_DISCORD_WEBHOOK_URL_HERE"
CONTAINER_NAMES=("pangolin" "gerbil" "traefik")
LOG_LINES_TO_CHECK=20
CHECK_FREQUENCY_MINUTES=5

# --- Functions ---

send_discord_message() {
  local message="$1"
  local color="$2"

  if [ -z "$color" ]; then
    color="good"
  fi

  local color_code=$(get_color_code "$color")

  if command -v jq >/dev/null 2>&1; then
    payload=$(jq -n \
      --arg message "$message" \
      --arg color "$color_code" \
      '{content: "", embeds: [{title: "Docker Monitor Alert", description: $message, color: ($color | if . | tonumber? then . else null end) }] }')
  else
    payload='{"content": "", "embeds": [{"title": "Docker Monitor Alert", "description": "'"$message"'", "color": '"$color_code"'"}]}'
  fi

  curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null
}

get_color_code() {
    local color_name="$1"
    case "$color_name" in
      "good") echo 3066993 ;;
      "warning") echo 16705372 ;;
      "danger") echo 15158332 ;;
      *) echo "$color_name" ;;
    esac
}

check_container_status() {
    # ... (same as before) ...
  local container_name="$1"
  local status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null)

  if [ -z "$status" ]; then
    send_discord_message ":x: Error: Container '$container_name' not found." "danger"
    return 1
  fi

  local health_status="not configured"
   if docker inspect "$container_name" | jq -e '.State.Health' >/dev/null 2>&1; then
       health_status=$(docker inspect -f '{{.State.Health.Status}}' "$container_name")
   fi

  if [ "$status" != "running" ]; then
    send_discord_message ":warning: Container '$container_name' is not running. Status: $status, Health: $health_status" "danger"
  else
    if [ "$health_status" = "healthy" ]; then
      send_discord_message ":white_check_mark: Container '$container_name' is running and healthy. Status: $status, Health: $health_status" "good"
    elif [ "$health_status" = "unhealthy" ]; then
      send_discord_message ":x: Container '$container_name' is running but UNHEALTHY. Status: $status, Health: $health_status" "danger"
    else
      send_discord_message ":information_source: Container '$container_name' is running. Status: $status, Health: $health_status" "warning"
    fi
  fi
}
check_for_updates() {
      # ... (same as before) ...
    local container_name="$1"
    local image_name=$(docker inspect -f '{{.Config.Image}}' "$container_name")

    local registry=""
    local full_image_name=""
    local image=""
    local tag="latest"

    if [[ "$image_name" =~ (.+/)?([^:]+)(:(.+))? ]]; then
      registry="${BASH_REMATCH[1]}"
      image="${BASH_REMATCH[2]}"
      tag="${BASH_REMATCH[4]:-latest}"
    fi
    registry=${registry%/}

    if [ -z "$registry" ]; then
      registry="registry-1.docker.io"
      full_image_name="library/$image"
    else
      full_image_name="$image"
    fi

    if ! command -v skopeo >/dev/null 2>&1; then
      send_discord_message ":x: Error: skopeo is not installed.  Please install it: \`sudo apt install skopeo -y\`" "danger"
      return 1
    fi

    local local_digest=$(docker inspect -f '{{index .RepoDigests 0}}' "$image_name" | cut -d '@' -f 2)
    remote_digest=$(skopeo inspect "docker://$registry/$full_image_name:$tag" | jq -r '.Digest')

    if [ -z "$remote_digest" ] || [ -z "$local_digest" ]; then
        send_discord_message ":x: Error while checking for updates of image: $image_name" "danger"
        return 1;
    fi

    if [ "$remote_digest" != "$local_digest" ]; then
      send_discord_message ":arrow_up: Update available for '$image_name'.\n  Current: $local_digest\n  New: $remote_digest" "warning"
    else
      send_discord_message ":information_source: No updates available for '$image_name'. Current digest is up-to-date: $local_digest" "good"

    fi
}

check_logs() {
  local container_name="$1"
  local print_to_stdout="${2:-false}"

  local logs=$(docker logs --tail "$LOG_LINES_TO_CHECK" "$container_name" 2>&1)

  if [ $? -ne 0 ]; then
    send_discord_message ":x: Error: Could not retrieve logs for '$container_name'." "danger"
    return 1  # Important: Return an error code
  fi

  if [ "$print_to_stdout" = "true" ]; then
      echo "Logs for container '$container_name':"
      echo "$logs"
      echo "-------------------------"
  fi

  if echo "$logs" | grep -i -E 'error|warning' >/dev/null; then
    send_discord_message ":exclamation: Errors/Warnings found in '$container_name' logs:\n\`\`\`\n$logs\n\`\`\`" "warning"
  else
     send_discord_message ":information_source: No errors or warnings found in '$container_name' last $LOG_LINES_TO_CHECK logs lines. " "good"
  fi
}

# --- Main Execution ---

if [ "$#" -gt 0 ]; then
    case "$1" in
        logs)
            if [ "$#" -eq 2 ]; then  # Check if a container name is provided
                check_logs "$2" "true"
            elif [ "$#" -eq 1 ]; then
                for container in "${CONTAINER_NAMES[@]}"; do
                    check_logs "$container" "true"
                done

            else
                echo "Usage: $0 logs [container_name]"
                exit 1
            fi
            ;;
        *)
            echo "Usage: $0 [logs [container_name]]"
            exit 1
            ;;
    esac
else
    # No arguments, run full monitoring
    for container in "${CONTAINER_NAMES[@]}"; do
        check_container_status "$container"
        check_for_updates "$container"
        check_logs "$container"
    done
fi

echo "Docker monitoring script completed."
exit 0
```

**How to Use:**

*   **Full Monitoring:**
    ```bash
    ./docker_monitor.sh
    ```
    Runs all checks and sends Discord messages.

*   **Check Logs for All Containers (print to console):**
    ```bash
    ./docker_monitor.sh logs
    ```
    Checks logs for *all* containers in `CONTAINER_NAMES` and prints to the console.

*   **Check Logs for a Specific Container (print to console):**
    ```bash
    ./docker_monitor.sh logs pangolin
    ```
    Checks logs *only* for the container named "pangolin" and prints to the console.  Replace "pangolin" with the actual container name.

**Example Output (for specific container):**

```
$ ./docker_monitor.sh logs pangolin
Logs for container 'pangolin':
[2023-10-27 14:35:00] INFO: Application started
[2023-10-27 14:35:10] INFO: Request processed successfully
-------------------------
```

This output shows the logs printed to the console, in addition to any Discord messages that might be sent based on errors/warnings found in the logs. This enhanced argument handling makes the script much more flexible and useful for targeted debugging.
