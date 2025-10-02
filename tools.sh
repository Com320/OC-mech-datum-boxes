#!/bin/bash
# OC Tools - Bulk Fix & Data Collection Utility
# Sources utils.sh for logging and settings parsing

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is not installed."
    read -p "Would you like to install jq? (y/n): " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo "Installing jq..."
        apt update && apt install -y jq
        if [ $? -eq 0 ]; then
            echo "jq installed successfully."
        else
            echo "Failed to install jq. Please install it manually."
            exit 1
        fi
    else
        echo "jq is required to proceed. Exiting."
        exit 1
    fi
else
    echo ""
fi

source ./utils.sh

# ------------------------------
# Configurable constants (centralized)
# ------------------------------
JOURNAL_LINES=${JOURNAL_LINES:-200}                 # Lines of journal to capture in archives
RECENT_JOURNAL_LINES=${RECENT_JOURNAL_LINES:-5}     # Lines of journal to show in monitor sections
SYNC_MONITOR_INTERVAL=${SYNC_MONITOR_INTERVAL:-2}   # Seconds between monitor refreshes
ARCHIVE_PREFIX=${ARCHIVE_PREFIX:-collected_logs}    # Base name prefix for collected archive
DATUM_CONFIG_REL=${DATUM_CONFIG_REL:-datum/datum_gateway_config.json}
DATUM_LOG_LEVEL_KEY=${DATUM_LOG_LEVEL_KEY:-.logger.log_level_file}
DATUM_LOG_FILE_KEY=${DATUM_LOG_FILE_KEY:-.logger.log_file}

# Standardized exit codes (document once; reuse across check functions)
# 0 SUCCESS
# 1 CONFIG_OR_DEP_MISSING (required config file or dependency not found)
# 2 NOT_FOUND_OR_RESOLVE_FAILED (specific file/username/path resolution failure)
# 3 PERMISSION_OR_UNREADABLE (unreadable / insufficient privilege)
# 4 VALUE_MISSING_OR_INVALID (expected value absent or invalid)
# 5 MISMATCH (comparison revealed mismatch)
# 6 RUNTIME_ERROR (unexpected runtime failure)
# 7 ABORTED (user cancelled an action intentionally)
EXIT_SUCCESS=0
EXIT_CONFIG_OR_DEP_MISSING=1
EXIT_RESOLVE_FAILED=2
EXIT_UNREADABLE=3
EXIT_VALUE_INVALID=4
EXIT_MISMATCH=5
EXIT_RUNTIME_ERROR=6
EXIT_ABORTED=7
# Global dependency guard (fail fast if jq missing; many functions rely on it).
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}FATAL${NC}: 'jq' is required but not installed or not in PATH. Please install jq before using this script." >&2
  exit $EXIT_CONFIG_OR_DEP_MISSING
fi

# Require an actual root shell (not sudo invocation) similar to main.sh safeguards
require_root_shell() {
  echo -e "${RED}This script must be run from a root login shell, not via 'sudo <script>'.${NC}"
  echo "Switch to a root shell with one of:"
  echo "  sudo -i"
  echo "  su -"
  echo "Then rerun tools.sh from that shell."
  exit $EXIT_RUNTIME_ERROR
}

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  require_root_shell
elif [ "$(id -u)" -ne 0 ]; then
  require_root_shell
fi


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

# ------------------------------
# Helper consolidation functions
# ------------------------------

# Hidden self-test (option 99)
self_test_helpers() {
  echo -e "Running self-test of helper invariants..."
  local failures=0

  # jq presence (should be ensured by global guard)
  if command -v jq >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}: jq present"
  else
    echo -e "${RED}FAIL${NC}: jq missing despite global guard"
    failures=$((failures+1))
  fi

  # bitcoin.conf resolution
  if conf=$(resolve_bitcoin_conf 2>/dev/null); then
    echo -e "${GREEN}PASS${NC}: resolve_bitcoin_conf -> $conf"
  else
    echo -e "${YELLOW}WARN${NC}: resolve_bitcoin_conf could not locate bitcoin.conf"
  fi

  # datum config resolution
  if dcfg=$(resolve_datum_config_path 2>/dev/null); then
    echo -e "${GREEN}PASS${NC}: resolve_datum_config_path -> $dcfg"
    ensure_file_present_readable "$dcfg" "datum config" || failures=$((failures+1))
  else
    echo -e "${YELLOW}WARN${NC}: resolve_datum_config_path could not resolve (username unset or file missing)"
  fi

  # Redaction test
  local tmpbtc
  tmpbtc=$(mktemp /tmp/mock-btc-conf.XXXXXX)
  printf 'rpcauth=user:hashhere\nother=1\n' > "$tmpbtc"
  redact_rpcauth_inplace "$tmpbtc"
  if grep -q 'rpcauth=<REDACTED>' "$tmpbtc"; then
    echo -e "${GREEN}PASS${NC}: redact_rpcauth_inplace"
  else
    echo -e "${RED}FAIL${NC}: redact_rpcauth_inplace"
    failures=$((failures+1))
  fi
  rm -f "$tmpbtc" 2>/dev/null || true

  # Journal capture test
  local tmpjournal
  tmpjournal=$(mktemp /tmp/mock-journal.XXXXXX)
  capture_service_journal "nonexistent-service-name" 5 "$tmpjournal"
  if [ -s "$tmpjournal" ]; then
    echo -e "${GREEN}PASS${NC}: capture_service_journal produced output"
  else
    echo -e "${RED}FAIL${NC}: capture_service_journal produced empty output"
    failures=$((failures+1))
  fi
  rm -f "$tmpjournal" 2>/dev/null || true

  if [ $failures -eq 0 ]; then
    echo -e "${GREEN}Self-test PASSED${NC}"
    return $EXIT_SUCCESS
  else
    echo -e "${RED}Self-test FAILED ($failures failure[s])${NC}"
    return $EXIT_RUNTIME_ERROR
  fi
}

# Resolve configured username (silent if unset)
resolve_username() {
  read_json_value "user.username" "$SETTINGS_FILE" 2>/dev/null || true
}

# Resolve bitcoin.conf path (prefers settings, falls back to /etc/bitcoin/bitcoin.conf)
resolve_bitcoin_conf() {
  local btc_conf
  btc_conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -n "$btc_conf" ] && [ -f "$btc_conf" ]; then
    printf '%s' "$btc_conf"
    return 0
  fi
  if [ -f /etc/bitcoin/bitcoin.conf ]; then
    printf '/etc/bitcoin/bitcoin.conf'
    return 0
  fi
  return 1
}

# Extract datadir from a bitcoin.conf path
read_bitcoin_datadir() {
  local conf="$1" line datadir
  [ -f "$conf" ] || return 1
  line=$(grep -E '^[[:space:]]*datadir[[:space:]]*=' "$conf" 2>/dev/null | head -n1 | cut -d'=' -f2- || true)
  datadir=$(echo -n "$line" | xargs)
  [ -n "$datadir" ] || return 2
  case "$datadir" in
    ~*) datadir=$(eval echo "$datadir") ;;
  esac
  printf '%s' "$datadir"
}

# Resolve datum config path (returns empty if username missing or file absent)
resolve_datum_config_path() {
  local username user_home cfg
  username=$(resolve_username)
  [ -n "$username" ] || return 1
  user_home=$(get_user_home "$username" 2>/dev/null || true)
  [ -n "$user_home" ] || return 2
  cfg="$user_home/$DATUM_CONFIG_REL"
  cfg=$(printf '%s' "$cfg" | tr -d '\r')
  [ -e "$cfg" ] || return 3
  printf '%s' "$cfg"
}

# Ensure file exists, non-empty, readable. Usage: ensure_file_present_readable <path> <desc>
# Returns: 0 ok, 1 missing, 2 empty, 3 unreadable.
ensure_file_present_readable() {
  local path="$1" desc="$2"
  if [ ! -e "$path" ]; then
    echo -e "${RED}FAIL${NC}: ${desc} not found at $path"
    return 1
  fi
  echo -e "${GREEN}PASS${NC}: ${desc} found at $path"
  if [ ! -s "$path" ]; then
    echo -e "${RED}FAIL${NC}: ${desc} exists but is empty: $path"
    return 2
  fi
  if [ ! -r "$path" ]; then
    echo -e "${YELLOW}WARN${NC}: ${desc} exists but not readable: $path"
    return 3
  fi
  return 0
}

# Redact rpcauth line in-place (idempotent)
redact_rpcauth_inplace() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -i -E 's/^[[:space:]]*rpcauth[[:space:]]*=.*/rpcauth=<REDACTED>/' "$file" 2>/dev/null || true
}

# Capture service journal to file (requires root). Usage: capture_service_journal <service> <lines> <outfile>
capture_service_journal() {
  local svc="$1" lines="$2" out="$3"
  if ! command -v journalctl >/dev/null 2>&1; then
    printf 'journalctl unavailable on system\n' > "$out"
    return 0
  fi
  : > "$out" || return 0
  journalctl -u "$svc" -n "$lines" --no-pager > "$out" 2>/dev/null || printf '(no journal entries or permission denied)\n' > "$out"
}

# Fetch datum log file path from config (stdout) if readable
resolve_datum_log_file() {
  local cfg="$1" logf
  [ -f "$cfg" ] || return 1
  logf=$(jq -r "$DATUM_LOG_FILE_KEY // empty" "$cfg" 2>/dev/null || true)
  [ -n "$logf" ] || return 2
  case "$logf" in
    ~*) logf=$(eval echo "$logf") ;;
  esac
  printf '%s' "$logf"
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

  echo -e "${YELLOW}WARN${NC}: journalctl requires elevated privileges to read $svc logs. Run tools.sh from a root shell to view output."
  echo "If you need to check manually: journalctl -u $svc -n 5 --no-pager"
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
  local btc_conf=""
  if [ -d "$tmpdir" ]; then
    if confirm_prompt "Temporary collection directory '$tmpdir' already exists. Delete and start over? (y/n): " "n"; then
      rm -rf "$tmpdir"
    else
      echo "Aborted by user. Collection cancelled.";
      return $EXIT_ABORTED
    fi
  fi
  if ! mkdir -p "$tmpdir"; then
    echo -e "${RED}FAIL${NC}: Unable to create temporary directory $tmpdir"
    return $EXIT_RUNTIME_ERROR
  fi

  # Always include current settings file
  if [ -f "$SETTINGS_FILE" ]; then
    echo "Including: $SETTINGS_FILE"
    if [ $dry_run -eq 0 ]; then cp -a "$SETTINGS_FILE" "$tmpdir/" 2>/dev/null || true; fi
  else
  echo -e "Warning: settings file not found at $SETTINGS_FILE"
  fi

  # Collect recent systemd journal entries for the services we care about
  echo "Including: recent systemd journal entries for bitcoin_knots.service and datum.service (last ${JOURNAL_LINES} lines)"
  if [ $dry_run -eq 1 ]; then
    echo "Would capture: journal-bitcoin_knots.txt (last ${JOURNAL_LINES} lines)"
    echo "Would capture: journal-datum.txt (last ${JOURNAL_LINES} lines)"
  else
    local j1="$tmpdir/journal-bitcoin_knots.txt"
    local j2="$tmpdir/journal-datum.txt"
    capture_service_journal "bitcoin_knots.service" "$JOURNAL_LINES" "$j1"
    echo "Including: $j1"
    capture_service_journal "datum.service" "$JOURNAL_LINES" "$j2"
    echo "Including: $j2"
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

  # Resolve bitcoin.conf (settings or fallback) once
  local resolved_btc_conf
  if resolved_btc_conf=$(resolve_bitcoin_conf); then
    btc_conf="$resolved_btc_conf"
  fi

  if [ -n "$btc_conf" ] && [ -f "$btc_conf" ]; then
    echo "Including: $btc_conf"
    if [ $dry_run -eq 0 ]; then
      cp -a "$btc_conf" "$tmpdir/" 2>/dev/null || true
      redact_rpcauth_inplace "$tmpdir/$(basename "$btc_conf")"
    fi
  fi

  # Try to extract datadir from bitcoin.conf and include debug.log from there
  if [ -n "${btc_conf:-}" ] && [ -f "$btc_conf" ]; then
    local btc_datadir
    btc_datadir=$(grep -E '^[[:space:]]*datadir[[:space:]]*=' "$btc_conf" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
    if [ -n "$btc_datadir" ]; then
      # Expand ~ if present
      case "$btc_datadir" in
        ~*) btc_datadir=$(eval echo "$btc_datadir") ;;
      esac
      if [ -d "$btc_datadir" ]; then
        if [ $dry_run -eq 1 ]; then
          echo "Would include: $btc_datadir/debug.log"
        else
          if [ -f "$btc_datadir/debug.log" ]; then
            echo "Including: $btc_datadir/debug.log"
            cp -a "$btc_datadir/debug.log" "$tmpdir/" 2>/dev/null || true
          else
            echo -e "Warning: debug.log not found in $btc_datadir"
          fi
        fi
      else
        echo -e "Warning: datadir from $btc_conf not found or not a directory: $btc_datadir"
      fi
    fi
  fi

  # Collect datum config and redact sensitive values, then include datum log file
  # Prefer a path under the user's home (user.username in settings) or fallback to /home/bitcoin/datum
  local datum_cfg_src datum_cfg_dst datum_log
  local cfg_username
  cfg_username=$(read_json_value "user.username" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -n "$cfg_username" ]; then
    datum_cfg_src="/home/$cfg_username/datum/datum_gateway_config.json"
  else
    datum_cfg_src="/home/bitcoin/datum/datum_gateway_config.json"
  fi
  if [ -f "$datum_cfg_src" ]; then
    echo "Including: $datum_cfg_src"
    if [ $dry_run -eq 0 ]; then
      datum_cfg_dst="$tmpdir/$(basename "$datum_cfg_src")"
      # Use jq to redact sensitive fields (we assume jq is available)
      jq --arg r "<REDACTED>" '.bitcoind.rpcuser = $r | .bitcoind.rpcpassword = $r | .api.admin_password = $r | .mining.pool_address = $r' "$datum_cfg_src" > "$datum_cfg_dst" 2>/dev/null || {
        # If jq fails for any reason, fall back to copying the file (no redaction)
        cp -a "$datum_cfg_src" "$datum_cfg_dst" 2>/dev/null || true
      }

      # Parse logger.log_file to include datum.log (use jq)
      datum_log=$(jq -r '.logger.log_file // empty' "$datum_cfg_src" 2>/dev/null || true)
      if [ -n "$datum_log" ]; then
        # Expand ~ if present
        case "$datum_log" in
          ~*) datum_log=$(eval echo "$datum_log") ;;
        esac
        if [ -f "$datum_log" ]; then
          echo "Including: $datum_log"
          cp -a "$datum_log" "$tmpdir/" 2>/dev/null || true
        else
          echo -e "Warning: datum log file referenced in config not found: $datum_log"
        fi
      fi
    fi
  else
    echo -e "Warning: datum config not found at $datum_cfg_src"
  fi

  # NOTE: bitcoin.default_data intentionally ignored to avoid large collections.

  # Show what would be archived in dry-run and exit
  if [ $dry_run -eq 1 ]; then
    echo
    echo "Dry-run complete. Files/directories that would be included (top-level):"
    ls -1A "$tmpdir" 2>/dev/null || echo "(no files collected)"
    rm -rf "$tmpdir"
    return $EXIT_SUCCESS
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
    return $EXIT_SUCCESS
  fi

  echo -e "Failed to create archive for collected logs. Temporary files are in $tmpdir"
  return $EXIT_RUNTIME_ERROR
}



# Recreate bitcoin.conf by backing up the current file (if present) and
# then running the bitcoin-conf-generator.sh script.
recreate_bitcoin_conf() {
  echo -e "Recreating bitcoin.conf (backup + generate)..."
  local conf
  conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$conf" ]; then
    echo -e "${RED}FAIL${NC}: bitcoin.default_conf not set in $SETTINGS_FILE"
    return $EXIT_CONFIG_OR_DEP_MISSING
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
      return $EXIT_SUCCESS
    else
      echo -e "${RED}FAIL${NC}: bitcoin-conf-generator.sh exited with error"
      return $EXIT_RUNTIME_ERROR
    fi
  else
    echo -e "${RED}FAIL${NC}: bitcoin-conf-generator.sh not found or not executable in $(pwd)"
    return $EXIT_CONFIG_OR_DEP_MISSING
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
  local cfg_path
  if ! cfg_path=$(resolve_datum_config_path); then
    echo -e "${RED}FAIL${NC}: Unable to resolve datum config (username unset/missing file)."
    return $EXIT_RESOLVE_FAILED
  fi
  ensure_file_present_readable "$cfg_path" "datum config" || {
    return $EXIT_RESOLVE_FAILED
  }
  local val
  val=$(jq -r '.mining.coinbase_tag_secondary // empty' "$cfg_path" 2>/dev/null || true)
  if [ -n "$val" ]; then
    echo -e "${GREEN}PASS${NC}: coinbase_tag_secondary is set to '$val' in $cfg_path"
    return $EXIT_SUCCESS
  fi
  echo -e "${RED}FAIL${NC}: coinbase_tag_secondary is missing or empty in $cfg_path"
  return $EXIT_VALUE_INVALID
}


# Check RPC credentials in bitcoin.conf and (optionally) try a basic RPC call
check_rpc_credentials() {
  echo -e "Checking RPC credentials in bitcoin.conf and connectivity..."
  local conf
  conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$conf" ]; then
    echo -e "${RED}FAIL${NC}: bitcoin.default_conf not configured in $SETTINGS_FILE"
    return $EXIT_CONFIG_OR_DEP_MISSING
  fi
  if [ ! -f "$conf" ]; then
    echo -e "${RED}FAIL${NC}: bitcoin.conf not found at $conf"
    return $EXIT_RESOLVE_FAILED
  fi

  # Look for rpcuser/rpcpassword or rpcauth
  local rpcuser rpcpass rpcauth rpcport status
  rpcuser=$(grep -E '^[[:space:]]*rpcuser[[:space:]]*=' "$conf" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
  rpcpass=$(grep -E '^[[:space:]]*rpcpassword[[:space:]]*=' "$conf" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
  rpcauth=$(grep -E '^[[:space:]]*rpcauth[[:space:]]*=' "$conf" 2>/dev/null | head -n1 || true)
  rpcport=$(grep -E '^[[:space:]]*rpcport[[:space:]]*=' "$conf" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)

  status=$EXIT_SUCCESS

  if [ -n "$rpcauth" ]; then
    echo -e "${GREEN}PASS${NC}: rpcauth entry present in $conf"
  elif [ -n "$rpcuser" ] && [ -n "$rpcpass" ]; then
    echo -e "${GREEN}PASS${NC}: rpcuser and rpcpassword found in $conf"
  else
    echo -e "${RED}FAIL${NC}: No rpcuser/rpcpassword or rpcauth found in $conf"
    status=$EXIT_VALUE_INVALID
  fi

  # Try a quick connectivity check using bitcoin-cli if available
  if command -v bitcoin-cli >/dev/null 2>&1; then
    if bitcoin-cli -conf="$conf" getblockchaininfo >/dev/null 2>&1; then
      echo -e "${GREEN}PASS${NC}: bitcoin-cli RPC call succeeded (bitcoind reachable)"
      return $status
    else
      echo -e "${RED}FAIL${NC}: bitcoin-cli RPC call failed (bitcoind may be down or credentials incorrect)"
      if [ "$status" -lt "$EXIT_RUNTIME_ERROR" ]; then
        status=$EXIT_RUNTIME_ERROR
      fi
    fi
  else
    echo -e "${YELLOW}WARN${NC}: bitcoin-cli not installed; skipping live RPC connectivity test"
    if [ "$status" -lt "$EXIT_CONFIG_OR_DEP_MISSING" ]; then
      status=$EXIT_CONFIG_OR_DEP_MISSING
    fi
  fi

  return $status
}


# Check that datum_gateway_config.json RPC credentials match bitcoin.conf RPC credentials
check_datum_rpc_match() {
  echo -e "Checking datum RPC credentials match bitcoind configuration..."

  local btc_conf datum_cfg username user_home
  if ! btc_conf=$(resolve_bitcoin_conf); then
    echo -e "${RED}FAIL${NC}: Could not resolve bitcoin.conf (neither settings nor /etc/bitcoin/bitcoin.conf)"
    return $EXIT_RESOLVE_FAILED
  fi
  datum_cfg=$(resolve_datum_config_path 2>/dev/null || true)
  if [ -z "$datum_cfg" ]; then
    echo -e "${RED}FAIL${NC}: datum config could not be resolved (missing username / file)."
    return $EXIT_RESOLVE_FAILED
  fi
  # Pull the username & home only if needed for rpcinfo.bin
  username=$(resolve_username)
  user_home=$(get_user_home "$username" 2>/dev/null || true)

  # Require jq to parse datum config
  # jq guaranteed by global guard

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
    return $EXIT_SUCCESS
  else
    return $EXIT_MISMATCH
  fi
}


# Check free space on the volume hosting bitcoin.default_data
check_default_data_free_space() {
  echo -e "Checking free space on volume hosting bitcoin.default_data..."
  local default_data target avail_kb avail_mb threshold_mb
  default_data=$(read_json_value "bitcoin.default_data" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$default_data" ]; then
    echo -e "${YELLOW}WARN${NC}: bitcoin.default_data not set in $SETTINGS_FILE"
    return $EXIT_CONFIG_OR_DEP_MISSING
  fi

  # If target doesn't exist, use its parent directory for df
  if [ ! -e "$default_data" ]; then
    target=$(dirname "$default_data")
  else
    target="$default_data"
  fi

  if ! command -v df >/dev/null 2>&1; then
    echo -e "${YELLOW}WARN${NC}: df utility not available; cannot determine free space for $default_data"
    return $EXIT_CONFIG_OR_DEP_MISSING
  fi

  avail_kb=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
  avail_mb=0
  if [ -n "$avail_kb" ] && [ "$avail_kb" -gt 0 ] 2>/dev/null; then
    avail_mb=$((avail_kb/1024))
  fi

  threshold_mb=${BITCOIN_MIN_FREE_MB:-1024}

  if [ "$avail_kb" -eq 0 ]; then
    echo -e "${YELLOW}WARN${NC}: Could not determine free space on the volume hosting $default_data"
    return $EXIT_RUNTIME_ERROR
  fi

  if [ "$avail_mb" -lt "$threshold_mb" ]; then
    echo -e "${YELLOW}WARN${NC}: Available free space on volume hosting $default_data is ${avail_mb}MB (recommended >= ${threshold_mb}MB)."
    return $EXIT_VALUE_INVALID
  else
    echo -e "${GREEN}PASS${NC}: Available space on volume hosting $default_data: ${avail_mb}MB"
    return $EXIT_SUCCESS
  fi
}



apply_service_retooling() {
  echo -e "Applying service retooling to prevent lengthy startup..."

  # Find existing systemd service file for bitcoin_knots or bitcoin
  local candidates=( "/etc/systemd/system/bitcoin_knots.service" "/usr/lib/systemd/system/bitcoin_knots.service" "/lib/systemd/system/bitcoin_knots.service" "/etc/systemd/system/bitcoin.service" "/usr/lib/systemd/system/bitcoin.service" "/lib/systemd/system/bitcoin.service" )
  local svc_path="" svc_unit="" was_active=0 svc_state="unknown" restart_code=$EXIT_SUCCESS
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
    return $EXIT_SUCCESS
  fi

  svc_unit=$(basename "$svc_path")
  if command -v systemctl >/dev/null 2>&1; then
    svc_state=$(systemctl is-active "$svc_unit" 2>/dev/null || true)
    if [ "$svc_state" = "active" ] || [ "$svc_state" = "activating" ]; then
      was_active=1
    fi
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
  cp "$svc_path" "$tmpfile" 2>/dev/null || { echo -e "${RED}FAIL${NC}: Could not copy service file to temp file."; return $EXIT_RUNTIME_ERROR; }

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
      return $EXIT_RUNTIME_ERROR
    fi
  else
    echo "Aborted applying changes; temporary modified file left at $tmpfile"
    return $EXIT_ABORTED
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if [ $was_active -eq 1 ]; then
      echo
      echo "Service $svc_unit was ${svc_state:-active} before changes."
      if confirm_prompt "Restart $svc_unit now to apply changes? (y/n): " "y"; then
        if systemctl restart "$svc_unit" 2>/dev/null; then
          echo -e "${GREEN}PASS${NC}: $svc_unit restarted successfully."
        else
          echo -e "${RED}FAIL${NC}: Failed to restart $svc_unit automatically. Please run 'systemctl restart $svc_unit' manually."
          restart_code=$EXIT_RUNTIME_ERROR
        fi
      else
        echo "To apply changes later, run: systemctl restart $svc_unit"
      fi
    else
      echo
      echo "Service $svc_unit was not active before changes (state: ${svc_state:-unknown})."
      if confirm_prompt "Attempt to restart $svc_unit anyway? (y/n): " "n"; then
        if systemctl restart "$svc_unit" 2>/dev/null; then
          echo -e "${GREEN}PASS${NC}: $svc_unit restarted successfully."
        else
          echo -e "${RED}FAIL${NC}: Failed to restart $svc_unit automatically. Please run 'systemctl restart $svc_unit' manually."
          restart_code=$EXIT_RUNTIME_ERROR
        fi
      else
        echo "Skipping restart because the service was not active prior to changes."
      fi
    fi
  else
    echo -e "${YELLOW}WARN${NC}: systemctl not available; cannot restart $svc_unit automatically."
  fi

  echo -e "Service retooling completed."
  return $restart_code
}


fix_bitcoin_cli() {
  echo -e "Checking and (optionally) fixing bitcoin-cli datadir symlink..."

  # Determine user and paths
  local username user_home bitcoin_dir default_conf default_data ts backup_target backup_source=""
  username=$(read_json_value "user.username" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$username" ]; then
    echo -e "${YELLOW}WARN${NC}: user.username not set in $SETTINGS_FILE"
    read -p "Enter the username that owns the bitcoin/datum installation: " username
    username=${username:-bitcoin}
  fi

  user_home=$(get_user_home "$username" || true)
  if [ -z "$user_home" ]; then
    echo -e "${RED}FAIL${NC}: Could not determine home directory for $username"
    return $EXIT_RESOLVE_FAILED
  fi

  default_conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$default_conf" ]; then
    echo -e "${RED}FAIL${NC}: bitcoin.default_conf not set in $SETTINGS_FILE; cannot proceed with bitcoin-cli repair."
    return $EXIT_CONFIG_OR_DEP_MISSING
  fi
  if [ -e "$default_conf" ]; then
    if [ -f "$default_conf" ] || [ -L "$default_conf" ]; then
      echo -e "${GREEN}PASS${NC}: Located bitcoin.default_conf at $default_conf"
    else
      echo -e "${RED}FAIL${NC}: bitcoin.default_conf at $default_conf is not a file or symlink; aborting."
      return $EXIT_VALUE_INVALID
    fi
  else
    echo -e "${RED}FAIL${NC}: bitcoin.default_conf path $default_conf does not exist; update settings.json or create the file before rerunning."
    return $EXIT_RESOLVE_FAILED
  fi

  default_data=$(read_json_value "bitcoin.default_data" "$SETTINGS_FILE" 2>/dev/null || true)
  if [ -z "$default_data" ]; then
    echo -e "${RED}FAIL${NC}: bitcoin.default_data not set in $SETTINGS_FILE; cannot proceed with bitcoin-cli repair."
    return $EXIT_CONFIG_OR_DEP_MISSING
  fi

  if [ -d "$default_data" ]; then
    echo -e "${GREEN}PASS${NC}: Located bitcoin.default_data directory at $default_data"
  elif [ -L "$default_data" ]; then
    local resolved_default_data
    resolved_default_data=$(readlink -f "$default_data" 2>/dev/null || true)
    if [ -n "$resolved_default_data" ] && [ -d "$resolved_default_data" ]; then
      echo -e "${GREEN}PASS${NC}: bitcoin.default_data symlink resolves to $resolved_default_data"
    else
      echo -e "${RED}FAIL${NC}: bitcoin.default_data at $default_data is a symlink that does not resolve to a directory."
      return $EXIT_RESOLVE_FAILED
    fi
  else
    echo -e "${RED}FAIL${NC}: bitcoin.default_data path $default_data does not exist or is not a directory; fix the path and rerun."
    return $EXIT_RESOLVE_FAILED
  fi

  # Ensure the bitcoin-cli binary is available in expected post-build locations
  local cli_source="" cli_dest_dir cli_dest tmp_cli system_cli_dest system_stage candidate
  cli_dest_dir="$user_home/bitcoin/bin"
  cli_dest="$cli_dest_dir/bitcoin-cli"
  system_cli_dest="/usr/local/bin/bitcoin-cli"

  if command -v bitcoin-cli >/dev/null 2>&1; then
    candidate=$(command -v bitcoin-cli)
    if [ -x "$candidate" ]; then
      cli_source="$candidate"
    fi
  fi

  if [ -z "$cli_source" ]; then
    for candidate in "$system_cli_dest" \
      "/usr/bin/bitcoin-cli" \
      "$cli_dest" \
      "$user_home/bitcoin/bin/bitcoin-cli" \
      "$user_home/bitcoin/src/bitcoin-cli" \
      "$user_home/bitcoin/src/bitcoin/bitcoin-cli" \
      "$user_home/bitcoin/src/bitcoin/build/bin/bitcoin-cli"; do
      if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        cli_source="$candidate"
        break
      fi
    done
  fi

  if [ -z "$cli_source" ] && [ -d "$user_home/bitcoin" ]; then
    candidate=$(find "$user_home/bitcoin" -maxdepth 5 -type f -name bitcoin-cli 2>/dev/null | head -n1)
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      cli_source="$candidate"
    fi
  fi

  if [ -n "$cli_source" ] && [ -x "$cli_source" ]; then
    if ! mkdir -p "$cli_dest_dir"; then
      echo -e "${RED}FAIL${NC}: Unable to create $cli_dest_dir for bitcoin-cli copy"
      return $EXIT_RUNTIME_ERROR
    fi
    chown "$username:$username" "$cli_dest_dir" 2>/dev/null || true

    if [ "$cli_source" = "$cli_dest" ]; then
      echo -e "${GREEN}PASS${NC}: bitcoin-cli already present at $cli_dest"
    elif [ -x "$cli_dest" ] && cmp -s "$cli_source" "$cli_dest" 2>/dev/null; then
      echo -e "${GREEN}PASS${NC}: bitcoin-cli in $cli_dest_dir is up to date"
    else
      tmp_cli=$(mktemp "$cli_dest_dir/.bitcoin-cli.XXXXXX") || {
        echo -e "${RED}FAIL${NC}: Unable to stage bitcoin-cli copy in $cli_dest_dir"
        return $EXIT_RUNTIME_ERROR
      }

      if cp "$cli_source" "$tmp_cli" 2>/dev/null; then
        chmod 755 "$tmp_cli" 2>/dev/null || true
        if mv "$tmp_cli" "$cli_dest" 2>/dev/null; then
          chown "$username:$username" "$cli_dest" 2>/dev/null || true
          echo -e "${GREEN}PASS${NC}: bitcoin-cli copied to $cli_dest"
        else
          rm -f "$tmp_cli" 2>/dev/null || true
          echo -e "${RED}FAIL${NC}: Failed to move staged bitcoin-cli into $cli_dest"
          return $EXIT_RUNTIME_ERROR
        fi
      else
        rm -f "$tmp_cli" 2>/dev/null || true
        echo -e "${RED}FAIL${NC}: Failed to copy bitcoin-cli from $cli_source"
        return $EXIT_RUNTIME_ERROR
      fi
    fi
  else
    echo -e "${YELLOW}WARN${NC}: bitcoin-cli binary not found; skipping repair of $cli_dest"
  fi

  # Ensure /usr/local/bin/bitcoin-cli exists and matches the best available source
  if [ -z "$cli_source" ] && [ -x "$cli_dest" ]; then
    cli_source="$cli_dest"
  fi

  if [ -n "$cli_source" ] && [ -x "$cli_source" ]; then
    if [ "$cli_source" = "$system_cli_dest" ]; then
      echo -e "${GREEN}PASS${NC}: bitcoin-cli already present at $system_cli_dest"
    elif [ -x "$system_cli_dest" ] && cmp -s "$cli_source" "$system_cli_dest" 2>/dev/null; then
      echo -e "${GREEN}PASS${NC}: bitcoin-cli in /usr/local/bin is up to date"
    else
      system_stage=$(mktemp /tmp/bitcoin-cli.XXXXXX) || {
        echo -e "${RED}FAIL${NC}: Unable to stage bitcoin-cli for /usr/local/bin install"
        return $EXIT_RUNTIME_ERROR
      }
      if cp "$cli_source" "$system_stage" 2>/dev/null; then
        chmod 755 "$system_stage" 2>/dev/null || true
        if mv "$system_stage" "$system_cli_dest" 2>/dev/null; then
          chown root:root "$system_cli_dest" 2>/dev/null || true
          echo -e "${GREEN}PASS${NC}: bitcoin-cli copied to $system_cli_dest"
        else
          rm -f "$system_stage" 2>/dev/null || true
          echo -e "${RED}FAIL${NC}: Failed to move staged bitcoin-cli into $system_cli_dest"
          return $EXIT_RUNTIME_ERROR
        fi
      else
        rm -f "$system_stage" 2>/dev/null || true
        echo -e "${RED}FAIL${NC}: Failed to copy bitcoin-cli from $cli_source for system install"
        return $EXIT_RUNTIME_ERROR
      fi
    fi
  else
    echo -e "${YELLOW}WARN${NC}: No bitcoin-cli binary available to repair /usr/local/bin/bitcoin-cli"
  fi

  bitcoin_dir="$user_home/.bitcoin"

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
    if [ -d "$bitcoin_dir/wallets" ] || [ -d "$bitcoin_dir/wallet" ]; then
      echo -e "${RED}FAIL${NC}: $bitcoin_dir contains wallet data (wallets/wallet); refusing to modify to avoid wallet loss."
      echo "Handle wallet migration manually before rerunning this fix."
      return $EXIT_ABORTED
    fi
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
    return $EXIT_ABORTED
  fi

  # free-space check is handled by check_default_data_free_space()

  # Backup existing bitcoin_dir if present
  if [ -e "$bitcoin_dir" ] || [ -L "$bitcoin_dir" ]; then
    ts=$(date -u +%Y%m%d_%H%M%S)
    backup_target="${bitcoin_dir}.backup_${ts}"
    if mv "$bitcoin_dir" "$backup_target" 2>/dev/null; then
      echo -e "${GREEN}PASS${NC}: Backed up existing $bitcoin_dir to $backup_target"
      backup_source="$backup_target"
    else
      echo -e "${YELLOW}WARN${NC}: Failed to back up $bitcoin_dir to $backup_target (permissions?)"
      echo "Attempting to remove $bitcoin_dir to continue..."
      if rm -rf "$bitcoin_dir" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}: Removed $bitcoin_dir"
      else
        echo -e "${RED}FAIL${NC}: Could not back up or remove existing $bitcoin_dir; aborting."
          return $EXIT_RUNTIME_ERROR
      fi
    fi
  fi

  # Offer to copy blockchain data from backup into the target datadir to avoid full re-download
  if [ -n "$backup_source" ] && [ -d "$backup_source" ] && [ ! -L "$backup_source" ]; then
    echo
    echo "A backup of the previous .bitcoin directory is located at $backup_source."
    if [ -n "$(ls -A "$default_data" 2>/dev/null)" ]; then
      echo -e "${YELLOW}WARN${NC}: $default_data already contains files; copying may overwrite existing data."
    fi
    if confirm_prompt "Copy the backup contents into $default_data to avoid re-downloading the chain? (y/n): " "y"; then
      echo "Copying blockchain data; this may take several minutes..."
      if cp -a "$backup_source/." "$default_data/" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}: Copied blockchain data into $default_data"
      else
        echo -e "${RED}FAIL${NC}: Failed to copy blockchain data from $backup_source to $default_data"
        echo "You may need to copy the files manually."
      fi
    else
      echo "Skipping blockchain data copy; $default_data will remain unchanged."
    fi
  fi

  # Ensure bitcoin.default_conf path points into the configured data directory
  local conf_target resolved_conf resolved_target conf_backup conf_ts
  conf_target="$default_data/bitcoin.conf"
  if [ "$default_conf" = "$conf_target" ]; then
    echo -e "${GREEN}PASS${NC}: bitcoin.default_conf already resides within the datadir ($conf_target)"
  else
    if [ ! -e "$conf_target" ]; then
      echo -e "${YELLOW}WARN${NC}: $conf_target not found; copying current config from $default_conf"
      if cp -a "$default_conf" "$conf_target" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}: Copied bitcoin.conf into $conf_target"
      else
        echo -e "${RED}FAIL${NC}: Unable to copy $default_conf into $conf_target; aborting."
        return $EXIT_RUNTIME_ERROR
      fi
    fi

    resolved_conf=$(readlink -f "$default_conf" 2>/dev/null || true)
    resolved_target=$(readlink -f "$conf_target" 2>/dev/null || true)

    if [ -L "$default_conf" ] && [ -n "$resolved_conf" ] && [ "$resolved_conf" = "$resolved_target" ] && [ -n "$resolved_target" ]; then
      echo -e "${GREEN}PASS${NC}: $default_conf already links to $conf_target"
    else
      conf_ts=$(date -u +%Y%m%d_%H%M%S)
      conf_backup="${default_conf}.backup_${conf_ts}"
      if [ -e "$default_conf" ] || [ -L "$default_conf" ]; then
        if cp -a "$default_conf" "$conf_backup" 2>/dev/null; then
          echo -e "${GREEN}PASS${NC}: Backed up existing bitcoin.conf to $conf_backup"
        else
          echo -e "${YELLOW}WARN${NC}: Failed to back up $default_conf to $conf_backup (permissions?)"
        fi
      fi

      if ln -sfn "$conf_target" "$default_conf" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}: Linked $default_conf -> $conf_target"
      else
        echo -e "${RED}FAIL${NC}: Failed to create symlink $default_conf -> $conf_target"
        return $EXIT_RUNTIME_ERROR
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
    return $EXIT_SUCCESS
  else
    echo -e "${RED}FAIL${NC}: Failed to create symlink $bitcoin_dir -> $default_data (permissions?)"
    return $EXIT_RUNTIME_ERROR
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
  local cfg_path username
  cfg_path=$(resolve_datum_config_path 2>/dev/null || true)
  if [ -z "$cfg_path" ]; then
    # Fallback interactive prompt for legacy behaviour
    username=$(resolve_username)
    if [ -z "$username" ]; then
      echo -e "${YELLOW}WARN${NC}: user.username not set in settings; prompting."
      read -p "Enter the username that owns the datum installation: " username
      username=${username:-bitcoin}
      local user_home
      user_home=$(get_user_home "$username" 2>/dev/null || true)
      if [ -z "$user_home" ]; then
        echo -e "${RED}FAIL${NC}: Could not determine home directory for $username"
        return $EXIT_RESOLVE_FAILED
      fi
      cfg_path="$user_home/$DATUM_CONFIG_REL"
    else
      # Attempt direct construction even if not yet present
      local user_home
      user_home=$(get_user_home "$username" 2>/dev/null || true)
      cfg_path="$user_home/$DATUM_CONFIG_REL"
    fi
  fi
  cfg_path=$(printf '%s' "$cfg_path" | tr -d '\r')
  ensure_file_present_readable "$cfg_path" "datum config" || return $EXIT_RESOLVE_FAILED

  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}FAIL${NC}: jq is required to modify $cfg_path. Please install jq and retry."
    return $EXIT_CONFIG_OR_DEP_MISSING
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
    return $EXIT_SUCCESS
  fi

  # Prompt for new value with current as default
  local new
  read -p "Enter desired numeric log level (0-5) [current: ${cur:-none}]: " new
  new=${new:-$cur}

  # Validate
  if ! [[ "$new" =~ ^[0-5]$ ]]; then
    echo -e "${RED}FAIL${NC}: Invalid log level: $new. Must be 0-5."
    return $EXIT_VALUE_INVALID
  fi

  if [ "$new" = "$cur" ]; then
    echo -e "${YELLOW}WARN${NC}: New level is the same as the current level ($cur). No changes made."
    return $EXIT_SUCCESS
  fi

  # Confirm change with the user showing explicit before/after
  echo "About to change datum log level:"
  echo "  was: ${cur:-unset}"
  echo "  will be: $new"
  if ! confirm_prompt "Proceed with this change? (y/n): " "n"; then
    echo "Aborted. No changes made."
    return $EXIT_ABORTED
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
      return $EXIT_RUNTIME_ERROR
    fi
  else
    echo -e "${RED}FAIL${NC}: Failed to update $cfg_path (jq error)"
    [ -f "$tmpfile" ] && rm -f "$tmpfile"
    return $EXIT_RUNTIME_ERROR
  fi

  # Notify about restart
  echo
  echo "To apply the change you must restart the datum service. This may force connected miners to reconnect (potentially large volume)."
  if confirm_prompt "Restart datum.service now? (y/n): " "n"; then
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl restart datum.service 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}: datum.service restarted successfully."
      else
        echo -e "${RED}FAIL${NC}: Failed to restart datum.service (permissions or service name?). Run: systemctl restart datum.service"
      fi
    else
      echo -e "${YELLOW}WARN${NC}: systemctl not available; restart manually: systemctl restart datum.service"
    fi
  else
    echo "To restart the service later and apply changes run:"
    echo "  systemctl restart datum.service"
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

    sleep "$SYNC_MONITOR_INTERVAL"
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
  echo "11) Bitcoin Chain Sync Status Monitor"
  echo "12) Exit"
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
  11) sync_status_monitor ;;
  12) break ;;
  99) self_test_helpers ;;
    *) echo "Invalid option." ;;
  esac
done
