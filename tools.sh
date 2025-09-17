#!/bin/bash
# OC Tools - Bulk Fix & Data Collection Utility
# Sources utils.sh for logging and settings parsing


source ./utils.sh

# Wrapper to return a sanitized user home directory path suitable for
# command-substitution. Some callers previously did `get_home_directory | tail -n1`
# to avoid friendly log lines being captured. Centralize that here so all callers
# get the final non-empty stdout line (stripped of CRs).
get_user_home() {
  local username="$1"
  local out line
  # Capture stdout from helper (suppress helper stderr) and pick the last
  # non-empty line. This makes callers robust if helper prints human-readable
  # messages to stderr or in unexpected situations.
  out=$(get_home_directory "$username" 2>/dev/null || true)
  line=$(printf '%s\n' "$out" | awk 'NF{l=$0} END{print l}')
  # Remove any trailing CR characters that might sneak in
  line=$(printf '%s' "$line" | tr -d '\r')
  printf '%s' "$line"
}

# Convert bytes to a human-readable string (e.g. 1234567 -> 1.18 MB)
# Usage: bytes_to_human <bytes>
bytes_to_human() {
  local bytes=${1:-0}
  local unit="B"
  local value=$bytes
  if [ "$bytes" -ge 1099511627776 ]; then
    unit="TB"
    value=$(awk "BEGIN {printf \"%.2f\", $bytes/1099511627776}")
  elif [ "$bytes" -ge 1073741824 ]; then
    unit="GB"
    value=$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")
  elif [ "$bytes" -ge 1048576 ]; then
    unit="MB"
    value=$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")
  elif [ "$bytes" -ge 1024 ]; then
    unit="KB"
    value=$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")
  fi
  printf "%s %s" "$value" "$unit"
}

# Show recent journal entries for a systemd service (last 5 lines).
# Usage: show_recent_journal <service>
show_recent_journal() {
  local svc="$1"
  if ! command -v journalctl >/dev/null 2>&1; then
    echo -e "${YELLOW}WARN${NC}: journalctl not available; cannot show recent logs for $svc"
    return 0
  fi

  echo "--- Recent logs: $svc (last 5 lines) ---"

  # If running as root, call directly
  if [ "$(id -u)" -eq 0 ]; then
    journalctl -u "$svc" -n 5 --no-pager 2>/dev/null || echo "(no journal entries or permission denied)"
    return 0
  fi

  # Try non-interactive sudo if available
  if command -v sudo >/dev/null 2>&1; then
    # -n makes sudo fail rather than prompt; if it fails, fall back to instruction
    if sudo -n journalctl -u "$svc" -n 5 --no-pager >/dev/null 2>&1; then
      sudo -n journalctl -u "$svc" -n 5 --no-pager 2>/dev/null || echo "(no journal entries)"
      return 0
    else
      echo -e "${YELLOW}WARN${NC}: journalctl requires elevated privileges to read $svc logs. Run with sudo to view logs."
      return 0
    fi
  fi

  # No sudo available and not root
  echo -e "${YELLOW}WARN${NC}: Not running as root and sudo not available; cannot read system journal for $svc"
  echo "Try: sudo journalctl -u $svc -n 5 --no-pager"
  return 0
}


collect_logs() {
  echo -e "Collecting logs and configs..."

  # Determine dry-run mode: env DRY_RUN=true forces dry-run, otherwise ask interactively
  local dry_run=0
  if [ "${DRY_RUN:-}" = "true" ] || [ "${DRY_RUN:-}" = "1" ]; then
    dry_run=1
  else
    if confirm_prompt "Perform dry-run (list files only) before creating archive? (y/n): " "n"; then
      dry_run=1
    fi
  fi

  # Prepare temp dir
  local tmpdir="collected_logs"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"

  # Always include current settings file
  if [ -f "$SETTINGS_FILE" ]; then
    echo "Including: $SETTINGS_FILE"
    if [ $dry_run -eq 0 ]; then cp -a "$SETTINGS_FILE" "$tmpdir/" 2>/dev/null || true; fi
  else
  echo -e "Warning: settings file not found at $SETTINGS_FILE"
  fi

  # Static default: system logs
  echo "Including: /var/log (glob)"
  if [ $dry_run -eq 0 ]; then
    cp -a /var/log/* "$tmpdir/" 2>/dev/null || true
  fi

  # Read configured logpath from settings.json (if available)
  if command -v jq >/dev/null 2>&1; then
    local cfg_logpath
    cfg_logpath=$(read_json_value "logpath" "$SETTINGS_FILE" 2>/dev/null || true)
    if [ -n "$cfg_logpath" ]; then
      # Resolve relative paths similar to init_logging()
      if [[ "$cfg_logpath" != /* ]]; then
        if [ "$(id -u)" -eq 0 ]; then
          cfg_logpath="$SCRIPT_DIR/$cfg_logpath"
        else
          local user_home
          user_home=$(eval echo ~$(whoami))
          cfg_logpath="$user_home/$cfg_logpath"
        fi
      fi
      echo "Including: $cfg_logpath"
      if [ $dry_run -eq 0 ]; then
        if [ -d "$cfg_logpath" ]; then
          cp -a "$cfg_logpath" "$tmpdir/" 2>/dev/null || true
        elif [ -f "$cfg_logpath" ]; then
          cp -a "$cfg_logpath" "$tmpdir/" 2>/dev/null || true
        else
          echo -e "Warning: configured logpath not found: $cfg_logpath"
        fi
      fi
    fi
  else
  echo -e "jq not found; skipping reading logpath from $SETTINGS_FILE"
  fi

  # Include bitcoin config and data dir if set in settings
  if command -v jq >/dev/null 2>&1; then
    local btc_conf
    btc_conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
    if [ -n "$btc_conf" ]; then
      echo "Including: $btc_conf"
      if [ $dry_run -eq 0 ]; then
        if [ -f "$btc_conf" ]; then
          cp -a "$btc_conf" "$tmpdir/" 2>/dev/null || true
        else
          echo -e "Warning: bitcoin default_conf not found: $btc_conf"
        fi
      fi
    fi
    # NOTE: bitcoin.default_data is intentionally ignored entirely and will not
    # be read or referenced here to avoid accidental collection of large or
    # sensitive data directories.
  fi

  # Show what would be archived in dry-run and exit
  if [ $dry_run -eq 1 ]; then
    echo
    echo "Dry-run complete. Files/directories that would be included (top-level):"
    ls -1A "$tmpdir" 2>/dev/null || echo "(no files collected)"
    rm -rf "$tmpdir"
    return 0
  fi

  # Create timestamped archive name using hostname and YYYYMMDD (UTC)
  local host
  host=$(hostname -s 2>/dev/null || echo "host")
  local ts
  ts=$(date -u +"%Y%m%d")
  local base_name="collected_logs-${host}-${ts}"

  # Create tar.gz archive (no zip; tar chosen to avoid zip dependency)
  local targzname="${base_name}.tar.gz"
  if tar -czf "$targzname" "$tmpdir" > /dev/null 2>&1; then
    rm -rf "$tmpdir"
  echo -e "Logs and configs collected into $targzname."
    COLLECTED_LOG_ARCHIVE="$targzname"
    export COLLECTED_LOG_ARCHIVE
    return 0
  fi

  echo -e "Failed to create archive for collected logs. Temporary files are in $tmpdir"
}



# Recreate bitcoin.conf by backing up the current file (if present) and
# then running the bitcoin-conf-generator.sh script.
recreate_bitcoin_conf() {
  echo -e "Recreating bitcoin.conf (backup + generate)..."
  local conf
  conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$conf" ]; then
    echo -e "${RED}FAIL${NC}: bitcoin.default_conf not set in $SETTINGS_FILE"
    return 1
  fi

  if [ -f "$conf" ]; then
    local ts
    ts=$(date -u +"%Y%m%d-%H%M%S")
    local bak="${conf}.bak-${ts}"
    if cp -a "$conf" "$bak" 2>/dev/null; then
      echo -e "${GREEN}PASS${NC}: Backed up existing bitcoin.conf to $bak"
    else
      echo -e "${YELLOW}WARN${NC}: Failed to backup existing bitcoin.conf to $bak (permissions?)"
    fi
  else
    echo -e "${YELLOW}WARN${NC}: bitcoin.conf not present at $conf; generator will create a new one"
  fi

  if [ -x ./bitcoin-conf-generator.sh ] || [ -f ./bitcoin-conf-generator.sh ]; then
    ./bitcoin-conf-generator.sh
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}PASS${NC}: bitcoin-conf-generator.sh completed successfully"
      return 0
    else
      echo -e "${RED}FAIL${NC}: bitcoin-conf-generator.sh exited with error"
      return 2
    fi
  else
    echo -e "${RED}FAIL${NC}: bitcoin-conf-generator.sh not found or not executable in $(pwd)"
    return 3
  fi
}


# Check permissions and existence for default_conf and default_data paths
check_conf_and_data_permissions() {
  echo -e "Checking permissions for bitcoin.default_conf and bitcoin.default_data..."
  local conf data
  conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
  data=$(read_json_value "bitcoin.default_data" "$SETTINGS_FILE" 2>/dev/null || true)

  if [ -n "$conf" ]; then
    if [ -e "$conf" ]; then
      local info
      info=$(stat -c "%U:%G %a" "$conf" 2>/dev/null || echo "(stat failed)")
      echo -e "${GREEN}PASS${NC}: bitcoin.default_conf exists: $conf -> $info"
    else
      echo -e "${RED}FAIL${NC}: bitcoin.default_conf not found: $conf"
    fi
  else
    echo -e "${YELLOW}WARN${NC}: bitcoin.default_conf not set in $SETTINGS_FILE"
  fi

  if [ -n "$data" ]; then
    if [ -e "$data" ]; then
      local dinfo
      dinfo=$(stat -c "%U:%G %a" "$data" 2>/dev/null || echo "(stat failed)")
      echo -e "${GREEN}PASS${NC}: bitcoin.default_data exists: $data -> $dinfo"
    else
      echo -e "${YELLOW}WARN${NC}: bitcoin.default_data not found: $data (this may be expected)"
    fi
  else
    echo -e "${YELLOW}WARN${NC}: bitcoin.default_data not set in $SETTINGS_FILE"
  fi
}


# Check that datum_gateway_config.json has coinbase_tag_secondary set
check_coinbase_tag_secondary() {
  echo -e "Checking datum_gateway_config.json for coinbase_tag_secondary..."
  # Attempt to find the datum config in the user's home directory
  local username user_home cfg_path
  username=$(read_json_value "user.username" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$username" ]; then
    echo -e "${YELLOW}WARN${NC}: user.username not set in $SETTINGS_FILE"
    return 1
  fi
  user_home=$(get_user_home "$username" || true)
  if [ -z "$user_home" ]; then
    echo -e "${YELLOW}WARN${NC}: Could not determine home directory for $username"
    return 1
  fi

  cfg_path="$user_home/datum/datum_gateway_config.json"
  # Sanitize path (remove common CR that can sneak in from files) and prefer a permissive existence check
  cfg_path=$(printf "%s" "$cfg_path" | tr -d '\r')
  if [ ! -e "$cfg_path" ]; then
    echo -e "${RED}FAIL${NC}: datum config not found at $cfg_path"
    echo "Diagnostic: listing path and parent directory:"
    ls -ld "$cfg_path" "$(dirname "$cfg_path")" 2>/dev/null || true
    echo "Diagnostic: raw bytes of computed path (hex):"
    printf '%s' "$cfg_path" | od -An -t x1 -v | sed 's/^/ /'
    return 2
  fi
  # File exists - report that we found it
  echo -e "${GREEN}PASS${NC}: datum config found at $cfg_path"
  # Ensure file is not empty
  if [ ! -s "$cfg_path" ]; then
    echo -e "${RED}FAIL${NC}: datum config exists but is empty: $cfg_path"
    ls -l "$cfg_path" 2>/dev/null || true
    return 2
  fi
  if [ ! -r "$cfg_path" ]; then
    echo -e "${YELLOW}WARN${NC}: datum config exists but is not readable by this process: $cfg_path"
    ls -l "$cfg_path" 2>/dev/null || true
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}WARN${NC}: jq not available; cannot parse $cfg_path"
    return 3
  fi

  local val
  # coinbase_tag_secondary lives under the "mining" object in datum config
  val=$(jq -r '.mining.coinbase_tag_secondary // empty' "$cfg_path" 2>/dev/null || true)
  if [ -n "$val" ]; then
    echo -e "${GREEN}PASS${NC}: coinbase_tag_secondary is set to '$val' in $cfg_path"
    return 0
  else
    echo -e "${RED}FAIL${NC}: coinbase_tag_secondary is missing or empty in $cfg_path"
    return 4
  fi
}


# Check RPC credentials in bitcoin.conf and (optionally) try a basic RPC call
check_rpc_credentials() {
  echo -e "Checking RPC credentials in bitcoin.conf and connectivity..."
  local conf
  conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$conf" ]; then
    echo -e "${RED}FAIL${NC}: bitcoin.default_conf not configured in $SETTINGS_FILE"
    return 1
  fi
  if [ ! -f "$conf" ]; then
    echo -e "${RED}FAIL${NC}: bitcoin.conf not found at $conf"
    return 2
  fi

  # Look for rpcuser/rpcpassword or rpcauth
  local rpcuser rpcpass rpcauth rpcport
  rpcuser=$(grep -E '^[[:space:]]*rpcuser[[:space:]]*=' "$conf" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
  rpcpass=$(grep -E '^[[:space:]]*rpcpassword[[:space:]]*=' "$conf" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
  rpcauth=$(grep -E '^[[:space:]]*rpcauth[[:space:]]*=' "$conf" 2>/dev/null | head -n1 || true)
  rpcport=$(grep -E '^[[:space:]]*rpcport[[:space:]]*=' "$conf" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)

  if [ -n "$rpcauth" ]; then
    echo -e "${GREEN}PASS${NC}: rpcauth entry present in $conf"
  elif [ -n "$rpcuser" ] && [ -n "$rpcpass" ]; then
    echo -e "${GREEN}PASS${NC}: rpcuser and rpcpassword found in $conf"
  else
    echo -e "${RED}FAIL${NC}: No rpcuser/rpcpassword or rpcauth found in $conf"
  fi

  # Try a quick connectivity check using bitcoin-cli if available
  if command -v bitcoin-cli >/dev/null 2>&1; then
    if bitcoin-cli -conf="$conf" getblockchaininfo >/dev/null 2>&1; then
      echo -e "${GREEN}PASS${NC}: bitcoin-cli RPC call succeeded (bitcoind reachable)"
      return 0
    else
      echo -e "${RED}FAIL${NC}: bitcoin-cli RPC call failed (bitcoind may be down or credentials incorrect)"
      return 3
    fi
  else
    echo -e "${YELLOW}WARN${NC}: bitcoin-cli not installed; skipping live RPC connectivity test"
    return 4
  fi
}


# Check that datum_gateway_config.json RPC credentials match bitcoin.conf RPC credentials
check_datum_rpc_match() {
  echo -e "Checking datum RPC credentials match bitcoind configuration..."

  # Determine bitcoin.conf path
  local btc_conf
  btc_conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$btc_conf" ] || [ ! -f "$btc_conf" ]; then
    echo -e "${RED}FAIL${NC}: bitcoin.default_conf not found or not configured ($btc_conf)"
    return 1
  fi

  # Determine datum config path
  local username user_home datum_cfg
  username=$(read_json_value "user.username" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$username" ]; then
    echo -e "${YELLOW}WARN${NC}: user.username not set in $SETTINGS_FILE"
    return 2
  fi
  user_home=$(get_user_home "$username" || true)
  if [ -z "$user_home" ]; then
    echo -e "${YELLOW}WARN${NC}: Could not determine home directory for $username"
    return 2
  fi
  datum_cfg="$user_home/datum/datum_gateway_config.json"
  datum_cfg=$(printf "%s" "$datum_cfg" | tr -d '\r')
  if [ ! -e "$datum_cfg" ]; then
    echo -e "${RED}FAIL${NC}: datum config not found at $datum_cfg"
    echo "Diagnostic: listing path and parent directory:"
    ls -ld "$datum_cfg" "$(dirname "$datum_cfg")" 2>/dev/null || true
    echo "Diagnostic: raw bytes of computed path (hex):"
    printf '%s' "$datum_cfg" | od -An -t x1 -v | sed 's/^/ /'
    return 3
  fi
  if [ ! -r "$datum_cfg" ]; then
    echo -e "${YELLOW}WARN${NC}: datum config exists but is not readable by this process: $datum_cfg"
    ls -l "$datum_cfg" 2>/dev/null || true
    return 3
  fi

  # Require jq to parse datum config
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}WARN${NC}: jq not installed; cannot parse $datum_cfg"
    return 4
  fi

  # Extract values
  local datum_user datum_pass
  datum_user=$(jq -r '.bitcoind.rpcuser // empty' "$datum_cfg" 2>/dev/null || true)
  datum_pass=$(jq -r '.bitcoind.rpcpassword // empty' "$datum_cfg" 2>/dev/null || true)

  # Extract bitcoind auth info
  local rpcuser rpcpass rpcauth
  rpcuser=$(grep -E '^[[:space:]]*rpcuser[[:space:]]*=' "$btc_conf" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
  rpcpass=$(grep -E '^[[:space:]]*rpcpassword[[:space:]]*=' "$btc_conf" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
  rpcauth=$(grep -E '^[[:space:]]*rpcauth[[:space:]]*=' "$btc_conf" 2>/dev/null | head -n1 || true)

  local pass=0
  # Compare usernames
  if [ -n "$rpcauth" ]; then
    # rpcauth has format rpcauth=username:... ; extract username
    local ra_user
    ra_user=$(echo "$rpcauth" | cut -d'=' -f2 | cut -d':' -f1 || true)
    if [ -n "$ra_user" ]; then
      if [ "$datum_user" = "$ra_user" ]; then
        echo -e "${GREEN}PASS${NC}: datum RPC username matches rpcauth username ($ra_user)"
      else
        echo -e "${RED}FAIL${NC}: datum RPC username ('$datum_user') does not match rpcauth username ($ra_user)"
        pass=1
      fi
    else
      echo -e "${YELLOW}WARN${NC}: could not parse username from rpcauth entry"
      pass=1
    fi
    # rpcauth stores a salted hash in bitcoin.conf so we can't compare
    # the stored hash to the datum password. Some tooling writes the
    # generated plaintext password to rpcinfo.bin in the user's home; try
    # to read and compare that when available for a stronger check.
    if [ -n "$datum_pass" ]; then
      local rpcinfo_file generated_pw
      if [ -n "$user_home" ] && [ -r "$user_home/rpcinfo.bin" ]; then
        rpcinfo_file="$user_home/rpcinfo.bin"
      elif [ -r "/home/$username/rpcinfo.bin" ]; then
        rpcinfo_file="/home/$username/rpcinfo.bin"
      fi

      if [ -n "$rpcinfo_file" ]; then
        # Try to extract the plaintext password after the 'Your password:' label
        generated_pw=$(awk -F': ' '/Your password/ { if (NF>1) {print $2; exit} else { if (getline) print; exit } }' "$rpcinfo_file" 2>/dev/null || true)
        # Trim whitespace
        generated_pw=$(printf '%s' "$generated_pw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ -n "$generated_pw" ]; then
          if [ "$datum_pass" = "$generated_pw" ]; then
            echo -e "${GREEN}PASS${NC}: datum RPC password matches generated password from $rpcinfo_file"
          else
            echo -e "${RED}FAIL${NC}: datum RPC password does not match generated password from $rpcinfo_file"
            pass=1
          fi
        else
          echo -e "${YELLOW}WARN${NC}: rpcinfo.bin present but password could not be parsed: $rpcinfo_file"
          pass=1
        fi
      else
        echo -e "${YELLOW}WARN${NC}: bitcoin.conf uses rpcauth; datum password cannot be compared against stored rpcauth hash (rpcinfo.bin not found)"
        pass=1
      fi
    fi
  else
    # bitcoind uses rpcuser/rpcpassword - compare both
    if [ -n "$rpcuser" ]; then
      if [ "$datum_user" = "$rpcuser" ]; then
        echo -e "${GREEN}PASS${NC}: datum RPC username matches bitcoin.conf rpcuser ($rpcuser)"
      else
        echo -e "${RED}FAIL${NC}: datum RPC username ('$datum_user') does not match bitcoin.conf rpcuser ($rpcuser)"
        pass=1
      fi
    else
      echo -e "${YELLOW}WARN${NC}: bitcoin.conf has no rpcuser set; cannot compare username"
      pass=1
    fi

    if [ -n "$rpcpass" ]; then
      if [ "$datum_pass" = "$rpcpass" ]; then
        echo -e "${GREEN}PASS${NC}: datum RPC password matches bitcoin.conf rpcpassword"
      else
        echo -e "${RED}FAIL${NC}: datum RPC password does not match bitcoin.conf rpcpassword"
        pass=1
      fi
    else
      echo -e "${YELLOW}WARN${NC}: bitcoin.conf has no rpcpassword set; cannot compare password"
      pass=1
    fi
  fi

  if [ $pass -eq 0 ]; then
    return 0
  else
    return 5
  fi
}


# Check free space on the volume hosting bitcoin.default_data
check_default_data_free_space() {
  echo -e "Checking free space on volume hosting bitcoin.default_data..."
  local default_data target avail_kb avail_mb threshold_mb
  default_data=$(read_json_value "bitcoin.default_data" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$default_data" ]; then
    echo -e "${YELLOW}WARN${NC}: bitcoin.default_data not set in $SETTINGS_FILE"
    return 2
  fi

  # If target doesn't exist, use its parent directory for df
  if [ ! -e "$default_data" ]; then
    target=$(dirname "$default_data")
  else
    target="$default_data"
  fi

  if ! command -v df >/dev/null 2>&1; then
    echo -e "${YELLOW}WARN${NC}: df utility not available; cannot determine free space for $default_data"
    return 3
  fi

  avail_kb=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
  avail_mb=0
  if [ -n "$avail_kb" ] && [ "$avail_kb" -gt 0 ] 2>/dev/null; then
    avail_mb=$((avail_kb/1024))
  fi

  threshold_mb=${BITCOIN_MIN_FREE_MB:-1024}

  if [ "$avail_kb" -eq 0 ]; then
    echo -e "${YELLOW}WARN${NC}: Could not determine free space on the volume hosting $default_data"
    return 4
  fi

  if [ "$avail_mb" -lt "$threshold_mb" ]; then
    echo -e "${YELLOW}WARN${NC}: Available free space on volume hosting $default_data is ${avail_mb}MB (recommended >= ${threshold_mb}MB)."
    return 1
  else
    echo -e "${GREEN}PASS${NC}: Available space on volume hosting $default_data: ${avail_mb}MB"
    return 0
  fi
}



apply_service_retooling() {
  echo -e "Applying service retooling to prevent lengthy startup..."

  # Find existing systemd service file for bitcoin_knots or bitcoin
  local candidates=( "/etc/systemd/system/bitcoin_knots.service" "/usr/lib/systemd/system/bitcoin_knots.service" "/lib/systemd/system/bitcoin_knots.service" "/etc/systemd/system/bitcoin.service" "/usr/lib/systemd/system/bitcoin.service" "/lib/systemd/system/bitcoin.service" )
  local svc_path=""
  for p in "${candidates[@]}"; do
    if [ -f "$p" ]; then
      svc_path="$p"
      break
    fi
  done

  if [ -z "$svc_path" ]; then
    echo -e "${YELLOW}WARN${NC}: No existing bitcoin service file found in standard locations."
    if confirm_prompt "Run generate-bitcoin-service.sh to create a service file now? (y/n): " "n"; then
      if [ -x ./generate-bitcoin-service.sh ] || [ -f ./generate-bitcoin-service.sh ]; then
        ./generate-bitcoin-service.sh
        echo -e "${GREEN}PASS${NC}: generate-bitcoin-service.sh executed (verify manually)."
      else
        echo -e "${RED}FAIL${NC}: generate-bitcoin-service.sh not found in repository."
      fi
    else
      echo "Skipping service generation.";
    fi
    return 0
  fi

  echo "Found existing service file: $svc_path"

  # Backup original
  local ts
  ts=$(date -u +"%Y%m%d-%H%M%S")
  local bak="${svc_path}.bak-${ts}"
  if cp -a "$svc_path" "$bak" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: Backed up original service to $bak"
  else
    echo -e "${YELLOW}WARN${NC}: Failed to back up original service to $bak (permissions?)"
  fi

  # Read username and default_conf from settings
  local username default_conf
  username=$(read_json_value "user.username" "$SETTINGS_FILE" 2>/dev/null || true)
  default_conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
  default_conf=${default_conf:-/etc/bitcoin/bitcoin.conf}

  # Desired ExecStart (keep binary path, enforce conf and notify args)
  local desired_exec
  desired_exec="ExecStart=/usr/local/bin/bitcoind -conf=${default_conf} -startupnotify='systemd-notify --ready' -shutdownnotify='systemd-notify --stopping'"

  # Create temp modified file
  local tmpfile="${svc_path}.tmp"
  cp "$svc_path" "$tmpfile" 2>/dev/null || { echo -e "${RED}FAIL${NC}: Could not copy service file to temp file."; return 1; }

  # Replace ExecStart lines with desired exec (account for multiple ExecStart lines)
  # Remove continuation lines that start with a dash
  sed -i '/^[[:space:]]*-/d' "$tmpfile"
  if grep -q '^ExecStart=' "$tmpfile"; then
    sed -i "s|^ExecStart=.*|${desired_exec}|g" "$tmpfile"
    echo -e "${GREEN}PASS${NC}: ExecStart updated in temporary service file."
  else
    # Insert ExecStart under [Service]
    sed -i "/\[Service\]/a ${desired_exec}" "$tmpfile"
    echo -e "${GREEN}PASS${NC}: ExecStart inserted into temporary service file."
  fi

  # Ensure Environment=PATH is present under [Service]
  if ! grep -q '^Environment=PATH=' "$tmpfile"; then
    sed -i '/\[Service\]/a Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$tmpfile"
    echo -e "${GREEN}PASS${NC}: Environment=PATH added."
  else
    echo -e "${GREEN}PASS${NC}: Environment=PATH already present."
  fi

  # Ensure RuntimeDirectory and RuntimeDirectoryMode present
  if ! grep -q '^RuntimeDirectory=' "$tmpfile"; then
    sed -i '/\[Service\]/a RuntimeDirectory=bitcoind\nRuntimeDirectoryMode=0710' "$tmpfile"
    echo -e "${GREEN}PASS${NC}: RuntimeDirectory entries added."
  else
    echo -e "${GREEN}PASS${NC}: RuntimeDirectory already present."
  fi

  # Remove StateDirectory and ConfigurationDirectory entries to avoid mismatches
  if grep -q '^StateDirectory=' "$tmpfile" || grep -q '^ConfigurationDirectory=' "$tmpfile"; then
    sed -i '/^StateDirectory=/d' "$tmpfile"
    sed -i '/^ConfigurationDirectory=/d' "$tmpfile"
    echo -e "${GREEN}PASS${NC}: Removed StateDirectory/ConfigurationDirectory entries to preserve user pathing."
  fi

  # Remove problematic ExecStartPre that chgrp /etc/bitcoin
  if grep -q '^ExecStartPre=/bin/chgrp bitcoin /etc/bitcoin' "$tmpfile"; then
    sed -i '/^ExecStartPre=\/bin\/chgrp/d' "$tmpfile"
    echo -e "${GREEN}PASS${NC}: Removed ExecStartPre chgrp on /etc/bitcoin to avoid permission surprises."
  fi

  # If User/Group are present and we found username in settings, update them to match
  if [ -n "$username" ]; then
    if grep -q '^User=' "$tmpfile"; then
      sed -i "s|^User=.*|User=${username}|g" "$tmpfile"
      echo -e "${GREEN}PASS${NC}: User set to $username in service file."
    fi
    if grep -q '^Group=' "$tmpfile"; then
      sed -i "s|^Group=.*|Group=${username}|g" "$tmpfile"
      echo -e "${GREEN}PASS${NC}: Group set to $username in service file."
    fi
  fi

  # Show a short diff-like preview (lines changed)
  echo "--- Changes preview (matching lines around ExecStart and Service headers) ---"
  grep -nE '(^\[Service\]|^ExecStart=|^Environment=PATH=|^RuntimeDirectory=|^RuntimeDirectoryMode=|^User=|^Group=)' "$svc_path" || true
  echo "---- new ----"
  grep -nE '(^\[Service\]|^ExecStart=|^Environment=PATH=|^RuntimeDirectory=|^RuntimeDirectoryMode=|^User=|^Group=)' "$tmpfile" || true

  # Ask before applying
  if confirm_prompt "Apply these changes to $svc_path now? (y/n): " "n"; then
    if cp "$tmpfile" "$svc_path" 2>/dev/null; then
      chmod 644 "$svc_path" 2>/dev/null || true
      rm -f "$tmpfile"
      echo -e "${GREEN}PASS${NC}: Service file updated at $svc_path"
      # Reload systemd
      if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null && echo -e "${GREEN}PASS${NC}: systemd daemon-reload executed." || echo -e "${YELLOW}WARN${NC}: systemctl daemon-reload failed or not permitted."
      fi
    else
      echo -e "${RED}FAIL${NC}: Failed to copy modified service into place (permissions?). Temporary file retained at $tmpfile"
      return 1
    fi
  else
    echo "Aborted applying changes; temporary modified file left at $tmpfile"
  fi

  echo -e "Service retooling completed."
}


fix_bitcoin_cli() {
  echo -e "Checking and (optionally) fixing bitcoin-cli datadir symlink..."

  # Determine user and paths
  local username user_home bitcoin_dir default_data ts backup_target
  username=$(read_json_value "user.username" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$username" ]; then
    echo -e "${YELLOW}WARN${NC}: user.username not set in $SETTINGS_FILE"
    read -p "Enter the username that owns the bitcoin/datum installation: " username
    username=${username:-bitcoin}
  fi

  user_home=$(get_user_home "$username" || true)
  if [ -z "$user_home" ]; then
    echo -e "${RED}FAIL${NC}: Could not determine home directory for $username"
    return 1
  fi

  bitcoin_dir="$user_home/.bitcoin"
  default_data=$(read_json_value "bitcoin.default_data" "$SETTINGS_FILE" 2>/dev/null || true)

  echo "--- Current state checks ---"

  # Check bitcoin_dir existence/type
  if [ -L "$bitcoin_dir" ]; then
    local target
    target=$(readlink -f "$bitcoin_dir" 2>/dev/null || true)
    if [ -n "$target" ]; then
      if [ -n "$default_data" ] && [ "$target" = "$default_data" ]; then
        echo -e "${GREEN}PASS${NC}: $bitcoin_dir is a symlink pointing to configured default_data: $target"
      else
        echo -e "${YELLOW}WARN${NC}: $bitcoin_dir is a symlink pointing to: $target"
      fi
    else
      echo -e "${YELLOW}WARN${NC}: $bitcoin_dir is a symlink but target could not be resolved"
    fi
  elif [ -d "$bitcoin_dir" ]; then
    echo -e "${YELLOW}WARN${NC}: $bitcoin_dir exists and is a directory (not a symlink). This may prevent bitcoin-cli from using the configured datadir by default."
  else
    echo -e "${RED}FAIL${NC}: $bitcoin_dir does not exist"
  fi

  # Check configured default_data
  if [ -n "$default_data" ]; then
    if [ -d "$default_data" ] || [ -L "$default_data" ]; then
      echo -e "${GREEN}PASS${NC}: bitcoin.default_data is configured as: $default_data (exists)"
    else
      echo -e "${YELLOW}WARN${NC}: bitcoin.default_data is configured as: $default_data (does not exist)"
    fi
  else
    echo -e "${YELLOW}WARN${NC}: bitcoin.default_data not set in $SETTINGS_FILE"
  fi

  echo
  echo "Planned action if applied:"
  if [ -n "$default_data" ]; then
    echo " - Ensure $bitcoin_dir is a symlink to: $default_data"
    echo " - If $bitcoin_dir exists (dir or symlink to a different target), it will be moved to a backup named ${bitcoin_dir}.backup_<timestamp>"
  else
    echo " - You will be prompted to provide a data directory to link to $bitcoin_dir"
  fi

  # Add generator-style warnings and maintenance window note
  echo
  echo -e "${YELLOW}If you choose to apply this change, the script will: ${NC}"
  echo -e "  1. Rename any existing $bitcoin_dir directory or symlink to a backup with a timestamp (e.g., ${bitcoin_dir}.backup_YYYYMMDD_HHMMSS)."
  echo -e "  2. Create a symlink from the target data directory to $bitcoin_dir so bitcoin-cli will use it by default."
  echo
  echo -e "${RED}IMPORTANT:${NC} This does NOT delete your data, but the original $bitcoin_dir will no longer be used by default. If this is a new installation, $bitcoin_dir should not contain any critical information."
  echo
  echo -e "${YELLOW}WARNING:${NC} Applying this change may require restarting the datum service and can be disruptive to connected miners. Perform during a maintenance window."

  if ! confirm_prompt "Apply the bitcoin-cli fix (create/replace symlink at $bitcoin_dir)? (y/n): " "n"; then
    echo "Aborted. No changes made."
    return 0
  fi

  # Ensure we have a target to symlink to
  if [ -z "$default_data" ]; then
    read -p "Enter the full path of the data directory to link (e.g. /var/lib/bitcoind): " default_data
    default_data=${default_data:-}
    if [ -z "$default_data" ]; then
      echo -e "${RED}FAIL${NC}: No data directory provided; aborting." 
      return 2
    fi
  fi

  # If target does not exist, warn and offer to create
  if [ ! -e "$default_data" ]; then
    echo -e "${YELLOW}WARN${NC}: Target data directory $default_data does not exist."
    if confirm_prompt "Create $default_data now? (y/n): " "n"; then
      if mkdir -p "$default_data" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}: Created $default_data"
      else
        echo -e "${RED}FAIL${NC}: Failed to create $default_data (permissions?)"
        return 3
      fi
    else
      echo "Aborted - target directory missing. No changes made." 
      return 4
    fi
  fi

  # free-space check is handled by check_default_data_free_space()

  # Backup existing bitcoin_dir if present
  if [ -e "$bitcoin_dir" ] || [ -L "$bitcoin_dir" ]; then
    ts=$(date -u +%Y%m%d_%H%M%S)
    backup_target="${bitcoin_dir}.backup_${ts}"
    if mv "$bitcoin_dir" "$backup_target" 2>/dev/null; then
      echo -e "${GREEN}PASS${NC}: Backed up existing $bitcoin_dir to $backup_target"
    else
      echo -e "${YELLOW}WARN${NC}: Failed to back up $bitcoin_dir to $backup_target (permissions?)"
      echo "Attempting to remove $bitcoin_dir to continue..."
      if rm -rf "$bitcoin_dir" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}: Removed $bitcoin_dir"
      else
        echo -e "${RED}FAIL${NC}: Could not back up or remove existing $bitcoin_dir; aborting."
        return 5
      fi
    fi
  fi

  # Create the symlink
  if ln -sfn "$default_data" "$bitcoin_dir" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: Created symlink: $bitcoin_dir -> $default_data"
    # Attempt to set ownership to the user if possible
    if chown -h "$username:$username" "$bitcoin_dir" 2>/dev/null; then
      echo -e "${GREEN}PASS${NC}: Set ownership on symlink to $username:$username"
    else
      echo -e "${YELLOW}WARN${NC}: Could not change ownership of symlink (insufficient permissions)"
    fi
    echo -e "${GREEN}PASS${NC}: bitcoin-cli should now work without specifying --datadir when run as $username"
    return 0
  else
    echo -e "${RED}FAIL${NC}: Failed to create symlink $bitcoin_dir -> $default_data (permissions?)"
    return 6
  fi
}



set_datum_log_level() {
  echo -e "Setting datum log level in datum_gateway_config.json..."

  # Mapping table
  echo "Log level mapping:"
  echo "0  all"
  echo "1  debug"
  echo "2  info (recommended)"
  echo "3  warn"
  echo "4  error"
  echo "5  fatal"
  echo

  # Locate datum config
  local username user_home cfg_path
  username=$(read_json_value "user.username" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$username" ]; then
    echo -e "${YELLOW}WARN${NC}: user.username not set in $SETTINGS_FILE"
    read -p "Enter the username that owns the datum installation: " username
    username=${username:-bitcoin}
  fi

  user_home=$(get_user_home "$username" || true)
  if [ -z "$user_home" ]; then
    echo -e "${RED}FAIL${NC}: Could not determine home directory for $username"
    return 1
  fi

  cfg_path="$user_home/datum/datum_gateway_config.json"
  cfg_path=$(printf "%s" "$cfg_path" | tr -d '\r')
  if [ ! -e "$cfg_path" ]; then
    echo -e "${RED}FAIL${NC}: datum config not found at $cfg_path"
    echo "Diagnostic: listing path and parent directory:"
    ls -ld "$cfg_path" "$(dirname "$cfg_path")" 2>/dev/null || true
    echo "Diagnostic: raw bytes of computed path (hex):"
    printf '%s' "$cfg_path" | od -An -t x1 -v | sed 's/^/ /'
    return 2
  fi
  if [ ! -r "$cfg_path" ]; then
    echo -e "${YELLOW}WARN${NC}: datum config exists but is not readable by this process: $cfg_path"
    ls -l "$cfg_path" 2>/dev/null || true
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}FAIL${NC}: jq is required to modify $cfg_path. Please install jq and retry."
    return 3
  fi

  # Read current value
  local cur
  cur=$(jq -r '.logger.log_level_file // empty' "$cfg_path" 2>/dev/null || true)
  if [ -z "$cur" ]; then
    echo -e "Current datum log level: (not set)"
  else
    echo -e "Current datum log level: $cur"
  fi

  # Ask the user if they want to change the log level before prompting
  if ! confirm_prompt "Do you want to change the datum log level? (y/n): " "n"; then
    echo "No changes requested. Exiting without modifying datum log level."
    return 0
  fi

  # Prompt for new value with current as default
  local new
  read -p "Enter desired numeric log level (0-5) [current: ${cur:-none}]: " new
  new=${new:-$cur}

  # Validate
  if ! [[ "$new" =~ ^[0-5]$ ]]; then
    echo -e "${RED}FAIL${NC}: Invalid log level: $new. Must be 0-5."
    return 4
  fi

  if [ "$new" = "$cur" ]; then
    echo -e "${YELLOW}WARN${NC}: New level is the same as the current level ($cur). No changes made."
    return 0
  fi

  # Confirm change with the user showing explicit before/after
  echo "About to change datum log level:"
  echo "  was: ${cur:-unset}"
  echo "  will be: $new"
  if ! confirm_prompt "Proceed with this change? (y/n): " "n"; then
    echo "Aborted. No changes made."
    return 0
  fi

  # Backup current config
  local bak
  bak="${cfg_path}.bak-$(date -u +%Y%m%d-%H%M%S)"
  if cp -a "$cfg_path" "$bak" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: Backed up datum config to $bak"
  else
    echo -e "${YELLOW}WARN${NC}: Failed to backup datum config to $bak (permissions?)"
  fi

  # Update the JSON value (numeric)
  local tmpfile
  tmpfile="${cfg_path}.tmp"
  # Use --argjson so the value is written as a number, not a string
  if jq --argjson lvl "$new" '.logger.log_level_file = $lvl' "$cfg_path" > "$tmpfile" 2>/dev/null; then
    if mv "$tmpfile" "$cfg_path" 2>/dev/null; then
      echo -e "${GREEN}PASS${NC}: Updated datum log level in $cfg_path"
    else
      echo -e "${RED}FAIL${NC}: Failed to move updated config into place"
      [ -f "$tmpfile" ] && rm -f "$tmpfile"
      return 5
    fi
  else
    echo -e "${RED}FAIL${NC}: Failed to update $cfg_path (jq error)"
    [ -f "$tmpfile" ] && rm -f "$tmpfile"
    return 5
  fi

  # Notify about restart
  echo
  echo "To apply the change you must restart the datum service. This may force connected miners to reconnect (potentially large volume)."
  if confirm_prompt "Restart datum.service now? (y/n): " "n"; then
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl restart datum.service 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}: datum.service restarted successfully."
      else
        echo -e "${RED}FAIL${NC}: Failed to restart datum.service (permissions or service name?). You may run: sudo systemctl restart datum.service"
      fi
    else
      echo -e "${YELLOW}WARN${NC}: systemctl not available; restart manually: sudo systemctl restart datum.service"
    fi
  else
    echo "To restart the service later and apply changes run:"
    echo "  sudo systemctl restart datum.service"
    echo "Be aware restarting may cause miners to reconnect."
  fi
}


# Bitcoin Chain Sync Status Monitor
sync_status_monitor() {
  echo -e "Starting Bitcoin Chain Sync Status Monitor. Press Ctrl-C to exit."

  # Determine bitcoin.conf and data dir from settings
  local btc_conf default_data df_target run_as_user
  btc_conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
  default_data=$(read_json_value "bitcoin.default_data" "$SETTINGS_FILE" 2>/dev/null || true)
  # Determine user to run bitcoin-cli as (if configured)
  run_as_user=$(read_json_value "user.username" "$SETTINGS_FILE" 2>/dev/null || true)

  # Helper to invoke bitcoin-cli as the configured user when possible.
  # Usage: run_bitcoin_cli <args...>
  run_bitcoin_cli() {
    local args
    args=("$@")

    # Prefer sudo when available
    if [ -n "$run_as_user" ] && command -v sudo >/dev/null 2>&1; then
      sudo -u "$run_as_user" -- bitcoin-cli "${args[@]}"
      return $?
    fi

    # Fallback to runuser (some distros) without requiring a full login shell
    if [ -n "$run_as_user" ] && command -v runuser >/dev/null 2>&1; then
      runuser -u "$run_as_user" -- bitcoin-cli "${args[@]}"
      return $?
    fi

    # Last-resort: su -c (may require password when not root)
    if [ -n "$run_as_user" ]; then
      su - "$run_as_user" -c "bitcoin-cli ${args[*]}"
      return $?
    fi

    # If no user configured or all else failed, run directly
    bitcoin-cli "${args[@]}"
    return $?
  }

  # Ensure bitcoin-cli is available at least when run as the configured user
  if ! command -v bitcoin-cli >/dev/null 2>&1; then
    # If bitcoin-cli not in PATH for current user, still attempt to run as configured user later
    echo -e "${YELLOW}WARN${NC}: bitcoin-cli not found in current PATH. Will attempt to invoke as configured user if possible."
  fi

  # Choose df target
  if [ -n "$default_data" ] && [ -d "$default_data" ]; then
    df_target="$default_data"
  elif [ -n "$default_data" ]; then
    df_target="$(dirname "$default_data")"
  else
    df_target="/var/lib/bitcoind"
  fi

  # Cleanup on Ctrl-C
  trap 'echo; echo "Exiting sync monitor."; exit 0' INT TERM

  while true; do
    # Build the output in an in-memory buffer (string) so we can clear the
    # screen once and print the fully-formed output. This reduces flicker
    # when commands (like bitcoin-cli or journalctl) are slow to respond.
    local buffer
    buffer=""

    buffer+=$'=== Bitcoin Chain Sync Status Monitor (press Ctrl-C to quit) ===\n\n'

    # Get blockchain sync info (invoke via helper which runs as configured user when possible)
    local info
    if [ -n "$btc_conf" ] && [ -f "$btc_conf" ]; then
      info=$(run_bitcoin_cli -conf="$btc_conf" getblockchaininfo 2>/dev/null || true)
    else
      info=$(run_bitcoin_cli getblockchaininfo 2>/dev/null || true)
    fi

    if [ -z "$info" ]; then
      buffer+=$(printf '%b\n' "${YELLOW}WARN${NC}: bitcoin-cli failed to return getblockchaininfo (bitcoind down or auth issue).")
      buffer+=$'\n'
    else
      local chain blocks headers progress ibd size_on_disk pct
      chain=$(jq -r '.chain // empty' <<<"$info" 2>/dev/null || echo "?")
      blocks=$(jq -r '.blocks // empty' <<<"$info" 2>/dev/null || echo "?")
      headers=$(jq -r '.headers // empty' <<<"$info" 2>/dev/null || echo "?")
      progress=$(jq -r '.verificationprogress // 0' <<<"$info" 2>/dev/null || echo 0)
      ibd=$(jq -r '.initialblockdownload // false' <<<"$info" 2>/dev/null || echo false)
      size_on_disk=$(jq -r '.size_on_disk // empty' <<<"$info" 2>/dev/null || echo "?")

      # Convert to human readable if numeric
      local size_on_disk_human="$size_on_disk"
      if [[ "$size_on_disk" =~ ^[0-9]+$ ]]; then
        size_on_disk_human=$(bytes_to_human "$size_on_disk")
      fi

      # Format screen output
      pct=$(awk "BEGIN {printf \"%.2f\", $progress * 100}")
      buffer+=$(printf '%b\n' "Chain: ${GREEN}${chain}${NC}  |  Blocks: ${GREEN}${blocks}${NC} / ${GREEN}${headers}${NC}  |  Progress: ${GREEN}${pct}%${NC}")
      buffer+=$'\n'
      buffer+=$(printf '%b\n' "IBD: ${YELLOW}${ibd}${NC}  |  Size on disk: ${GREEN}${size_on_disk_human}${NC}")
      buffer+=$'\n'
    fi

    # Get disk usage info
    if command -v df >/dev/null 2>&1; then
      local used_pct disk_pct_free
      used_pct=$(df -h "$df_target" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
      if [[ "$used_pct" =~ ^[0-9]+$ ]]; then
        disk_pct_free=$((100 - used_pct))
        buffer+=$(printf '%b\n' "Disk Free (approx): ${GREEN}${disk_pct_free}%${NC} (target: $df_target)")
      else
        buffer+=$(printf '%b\n' "${YELLOW}WARN${NC}: Could not read disk usage for $df_target")
      fi
    else
      buffer+=$(printf '%b\n' "${YELLOW}WARN${NC}: df utility not available; cannot determine disk usage")
    fi

    buffer+=$'\n'
    buffer+=$(printf '\nUpdated: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')")
    buffer+=$'\n'
    buffer+=$'\n'
    

    # Append recent journal output for services (capture their output so it goes into the buffer)
    # show_recent_journal prints its own header; capture it and append to buffer
    buffer+=$(show_recent_journal bitcoin_knots.service 2>/dev/null || echo "(no journal entries or permission denied)\n")
    buffer+=$'\n\n'
    buffer+=$(show_recent_journal datum.service 2>/dev/null || echo "(no journal entries or permission denied)\n")

    # Now clear the screen once and print the collected buffer
    clear
    printf '%s' "$buffer"

    sleep 2
  done
}


# Main menu loop
while true; do
  echo ""
  echo "==== OCEAN Tools Menu ===="
  echo "1) Collect logs/configs"
  echo "2) Recreate bitcoin.conf (backup + generator)"
  echo "3) Check bitcoin.conf & data permissions"
  echo "4) Check free space for bitcoin.default_data"
  echo "5) Check datum coinbase_tag_secondary"
  echo "6) Check bitcoind RPC credentials/connectivity"
  echo "7) Check datum vs bitcoind RPC credentials"
  echo "8) Apply service retooling"
  echo "9) Apply fix for bitcoin-cli"
  echo "10) Set datum log level"
  echo "12) Bitcoin Chain Sync Status Monitor"
  echo "11) Exit"
  read -p "Choose an option: " choice

  case $choice in
  1) collect_logs ;;
  2) recreate_bitcoin_conf ;;
  3) check_conf_and_data_permissions ;;
  4) check_default_data_free_space ;;
  5) check_coinbase_tag_secondary ;;
  6) check_rpc_credentials ;;
  7) check_datum_rpc_match ;;
  8) apply_service_retooling ;;
  9) fix_bitcoin_cli ;;
  10) set_datum_log_level ;;
  12) sync_status_monitor ;;
  11) break ;;
    *) echo "Invalid option." ;;
  esac
done
