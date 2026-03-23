#!/bin/bash

# Source shared utility functions
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging for this script
init_logging "generate_datum_service"

log "Starting Datum service generation script..."

# Call get_username interactively (it exports GET_USERNAME). Avoid command
# substitution because that runs the function in a subshell and breaks prompts.
if get_username; then
    # get_username now exports GET_USERNAME for callers; fall back to stdout if needed
    if [ -n "$GET_USERNAME" ]; then
        username="$GET_USERNAME"
        # Added whitespace to separate log from screen output
        echo ""
    else
        # Backward compatibility: capture printed output
        username=$(get_username)
    fi
else
    log_display "${RED}Failed to get valid username. Exiting.${NC}"
    exit 1
fi

# Get user's home directory using the shared function
user_home=$(get_home_directory "$username")
if [ $? -ne 0 ]; then
    log_display "${RED}Failed to get home directory. Exiting.${NC}"
    exit 1
fi

log "Using home directory: $user_home"

# Get init system
init_sys=$(get_init_system)
log "Using init system: $init_sys"

if [ "$init_sys" = "sysvinit" ]; then
    log "Creating sysvinit script at /etc/init.d/datum"
    cat > /etc/init.d/datum << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          datum
# Required-Start:    \$network \$local_fs bitcoin_knots
# Required-Stop:     \$network \$local_fs bitcoin_knots
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: starts datum gateway
# Description:       starts datum gateway using start-stop-daemon
### END INIT INFO

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
DAEMON=$user_home/datum/bin/datum_gateway
NAME=datum
USER=$username
DESC="Datum Gateway"
CONFIG=$user_home/datum/datum_gateway_config.json

test -x \$DAEMON || exit 0

set -e

case "\$1" in
  start)
	echo -n "Starting \$DESC: "
	start-stop-daemon --start --quiet --background --make-pidfile --pidfile /var/run/\$NAME.pid --chuid \$USER --exec \$DAEMON -- --config=\$CONFIG
	echo "\$NAME."
	;;
  stop)
	echo -n "Stopping \$DESC: "
	start-stop-daemon --stop --quiet --pidfile /var/run/\$NAME.pid
	echo "\$NAME."
	;;
  restart|force-reload)
	echo -n "Restarting \$DESC: "
	start-stop-daemon --stop --quiet --pidfile /var/run/\$NAME.pid
	sleep 1
	start-stop-daemon --start --quiet --background --make-pidfile --pidfile /var/run/\$NAME.pid --chuid \$USER --exec \$DAEMON -- --config=\$CONFIG
	echo "\$NAME."
	;;
  status)
    if [ -f /var/run/\$NAME.pid ]; then
        pid=\$(cat /var/run/\$NAME.pid)
        if ps -p \$pid > /dev/null; then
            echo "\$NAME is running with pid \$pid"
            exit 0
        else
            echo "\$NAME is not running (stale pid file)"
            exit 1
        fi
    else
        echo "\$NAME is not running"
        exit 3
    fi
    ;;
  *)
	N=/etc/init.d/\$NAME
	echo "Usage: \$N {start|stop|restart|force-reload|status}" >&2
	exit 1
	;;
esac

exit 0
EOF
    chmod 755 /etc/init.d/datum
    log "sysvinit script created at /etc/init.d/datum"
    
    if confirm_prompt "Do you want to enable and start the service now? (y/n): "; then
        log "User chose to enable and start the service"
        update-rc.d datum defaults
        /etc/init.d/datum start
        log_display "${GREEN}Service enabled and started.${NC}"
    else
        log "User chose not to enable and start the service"
        echo "You can manually start the service with: /etc/init.d/datum start"
    fi
    log "Datum service generation completed."
    exit 0
fi

# Write the content to the service file (systemd logic)
log "Creating Datum service file at /usr/lib/systemd/system/datum.service"
cat > /usr/lib/systemd/system/datum.service << EOF
[Unit]
Description=Datum Gateway Service
After=network.target

[Service]
LimitNOFILE=65535
ExecStart=$user_home/datum/bin/datum_gateway --config=$user_home/datum/datum_gateway_config.json
Restart=always
User=$username
Group=$username

[Install]
WantedBy=multi-user.target
EOF

# Check if the operation was successful
if [ $? -eq 0 ]; then
    log_display "${GREEN}File 'datum.service' has been created and user inserted correctly.${NC}"
    log "Service configuration saved to: /usr/lib/systemd/system/datum.service"
    
    # Enable and start the service if requested
    if confirm_prompt "Do you want to enable and start the service now? (y/n): "; then
        log "User chose to enable and start the service"
        log "Running: systemctl daemon-reload"
        systemctl daemon-reload
        log "Running: systemctl enable datum.service"
        systemctl enable datum.service
        log "Running: systemctl start datum.service"
        systemctl start datum.service
        log_display "${GREEN}Service enabled and started.${NC}"
        
        # Check service status
        log "Checking service status..."
        echo "Checking service status..."
        # Capture service status to log file while also showing on screen
        systemctl status datum.service | tee -a "$LOG_FILE"
    else
        log "User chose not to enable and start the service"
        echo "You can manually start the service with: systemctl start datum.service"
    fi
else
    log_display "${RED}An error occurred while creating or editing the file.${NC}"
    exit 1
fi

log "Datum service generation completed."
