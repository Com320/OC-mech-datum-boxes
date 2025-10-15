# DATUM Box Setup Scripts

These scripts automate the setup and configuration of DATUM boxes - dedicated hardware nodes that run Bitcoin Knots and DATUM Gateway.

## Overview

This project provides a collection of shell scripts that automate the process of:
- Setting up a dedicated user for running the Bitcoin and DATUM services
- Installing necessary dependencies
- Building Bitcoin Knots from source
- Building DATUM Gateway from source
- Generating appropriate configurations for both services
- Setting up system services for automatic startup
- Providing an interactive maintenance toolkit for post-install checks and log collection

## Scripts

- `main.sh` - The primary script that orchestrates the entire setup process
- `user-setup.sh` - Creates and configures the user account
- `dependencies.sh` - Installs all required system dependencies
- `build-btcknots.sh` - Builds Bitcoin Knots from source
- `build-datum.sh` - Builds DATUM Gateway from source
- `generate-rpcauth.sh` - Generates RPC authentication credentials
- `bitcoin-conf-generator.sh` - Generates the Bitcoin configuration file
- `datum-config-generator.sh` - Generates the DATUM Gateway configuration
- `generate-bitcoin-service.sh` - Creates a systemd service for Bitcoin
- `generate-datum-service.sh` - Creates a systemd service for DATUM Gateway
- `utils.sh` - Common utility functions used across all scripts
- `verify-git-tag.sh` - Verifies GPG signatures on Git tags (used by the Bitcoin build)
- `welcomemsg.sh` - Displays the informational welcome message used by `main.sh`
- `tools.sh` - Interactive maintenance toolkit for log collection, configuration checks, and service fixes
- `troubleshoot-bitcoin-conf.sh` - Helpers to inspect and debug `bitcoin.conf`

## Architecture

The scripts follow a modular architecture with the following key features:

- **Centralized Utilities**: Common functions are defined in `utils.sh` and shared across all scripts
- **JSON Configuration**: All settings are managed through a single `settings.json` file
- **Standardized Logging**: Consistent logging format with timestamps across all components
- **Error Handling**: Scripts include robust error checking and reporting
- **Maintenance Utilities**: `tools.sh` consolidates routine troubleshooting tasks into one menu-driven helper

This architecture makes the codebase easier to maintain and extend.

## Usage


### Quick Start

**Important:** The repository must be cloned to the path specified by `scripts_path` in `settings.json` (default: `/root/OC-mech-datum-boxes`). If you change this value in `settings.json`, you must also clone the repository to the same path, or update both to match. If the paths do not match, some scripts and configuration steps will fail.

1. **Clone this repository (anywhere you like):**

   You may clone the repository into any path. If you do not use the default path, update `scripts_path` in `settings.json` to match your clone location.

   ```bash
   # Example (default path):
   git clone https://github.com/Com320/OC-mech-datum-boxes.git /root/OC-mech-datum-boxes

   # Or clone into your home directory and update settings.json accordingly:
   git clone https://github.com/Com320/OC-mech-datum-boxes.git ~/OC-mech-datum-boxes
   ```

2. **Change into the repository directory:**

   ```bash
   cd /root/OC-mech-datum-boxes
   ```

3. **Review and modify `settings.json` as needed.**

4. **Set all scripts in the root directory as executable:**

   ```bash
   chmod +x *.sh
   ```

5. **Run the `main.sh` script from an interactive root shell (NOT via `sudo <script>`):**

   The `main.sh` script intentionally rejects being invoked with `sudo <script>` and must be run from a root login or interactive root shell. This avoids permission and ownership problems when creating the unprivileged user and copying files.

   Example:

   ```bash
   sudo -i
   cd /path/to/OC-mech-datum-boxes
   ./main.sh
   ```

6. **Run post-install maintenance tasks (optional):**

   Use `tools.sh` for troubleshooting, log collection, or service validation once the base install completes (details below).

## Requirements

- A Debian-based Linux distribution (Ubuntu, Debian, etc.)
- Root privileges (not sudo)
- Internet connection for downloading dependencies and source code
- Sufficient disk space for the Bitcoin blockchain

Note: `jq` and `gnupg` are required by the scripts: `jq` is used by `main.sh` and `utils.sh` for JSON parsing, and `gnupg` (gpg) is required if `build_options.verify_signatures` is enabled.

## Configuration


The `settings.json` file contains key configuration parameters:
- User account settings (username and creation options)
- Log directory path
- **Scripts path (`scripts_path`)**: The directory where the scripts are installed and where the repository must be cloned. This must match the actual clone location (default: "/root/OC-mech-datum-boxes"). If you change this value, you must also clone the repository to the same path, or update both to match.
- Build options:
   - `cpu_cores`: Number of CPU cores to use during compilation (speeds up build on multi-core systems)
   - `bitcoin_knots_tag`: GitHub tag to checkout for Bitcoin Knots (default: v28.1.knots20250305)
   - `verify_signatures`: Whether to verify Git tag signatures for Bitcoin Knots (default: true)
   - `key_fingerprint`: PGP key fingerprint used to verify signatures (default: 1A3E761F19D2CC7785C5502EA291A2C45D0C504A)
   - `run_tests`: Whether to run `make check` / unit tests during the Bitcoin Knots build (default: true)
- DATUM options:
   - `coinbase_tag_primary`: Primary coinbase tag (default: DATUM)
   - `coinbase_tag_secondary`: Secondary coinbase tag (default: empty)
- Required system packages for building and running the services

Please review and customize this file before running the scripts.

## Maintenance Toolkit (`tools.sh`)

`tools.sh` is an interactive, menu-driven helper designed for day-two operations collecting diagnostics, validating configuration, and applying safe fixes without hunting for individual helper scripts.

- **Run context**: Launch from the repository root (`cd /path/to/OC-mech-datum-boxes && ./tools.sh`) in a root login shell. Like `main.sh`, it will exit if invoked as `sudo ./tools.sh` to avoid permission mismatches. The script requires `jq` and benefits from `journalctl`, `systemctl`, and `bitcoin-cli` when available. 
- **Core capabilities**: Collect redacted support bundles, rebuild `bitcoin.conf`, audit permissions, compare RPC credentials, retune the systemd service definition, repair `bitcoin-cli` symlinks, adjust DATUM log levels, and monitor chain sync progress in real time.
- **Safe defaults**: Archival routines redact sensitive fields (such as `rpcauth`, DATUM RPC credentials, and API passwords) and stage changes with timestamped backups before modifying configs or services.

- **Before running `tools.sh` (non-default installs):** If you cloned the repository to a non-default location or otherwise customized your environment, update `settings.json` so the toolkit can locate files and services correctly. At minimum verify:
   - `scripts_path` points to the clone location of this repository
   - `user.username` matches the unprivileged user that owns the bitcoin/datum installation
   - `bitcoin.default_conf` and `bitcoin.default_data` point to your bitcoind configuration and datadir
   - `logpath` points to a writable location for collecting logs

   Quick checks using `jq` (run from the repository root):

   ```bash
   jq '.scripts_path, .user.username, .bitcoin.default_conf, .bitcoin.default_data, .logpath' settings.json
   ```

   If you need to edit values, open `settings.json` in your editor and adjust the fields above before invoking `./tools.sh`. Running `tools.sh` with incorrect paths can lead to missing files in collected bundles or failed checks; the script will prompt and warn when it cannot resolve important files but pre-adjusting `settings.json` reduces friction.

When requesting support, running option `1` (log collection) produces a ready-to-share tarball in the current directory. Other numbered options can be revisited at any time; each action documents what it plans to do and prompts before applying changes that could disrupt services.

## Security Features

The build process includes security measures to ensure the integrity of the Bitcoin Knots source code:

- **Signature Verification**: The script verifies PGP signatures on Git tags to ensure the Bitcoin Knots source hasn't been tampered with
- **Isolated GPG Environment**: Signature verification takes place in an isolated GPG environment to avoid conflicts with existing keys

These features are enabled by default but can be disabled in the settings.json file if needed.

Implementation note: the verification helper `verify-git-tag.sh` is invoked as the unprivileged user during the build process. The build scripts copy the verification helper and a temporary settings file into the target user's home and run it as that user so GPG verification occurs in the user's context. If you want to skip verification, set `build_options.verify_signatures` to `false` in `settings.json` (not recommended for production systems).

## Important Note

Please pay attention to the values generated and refrain from blindly using the settings found here. Always review the generated configurations to ensure they meet your specific requirements and security needs.

## Credits

These scripts are based on the work of [Bitcoin Mechanic](https://github.com/bitcoinmechanic). This version adds an automation layer on top of the entire workflow process to create a streamlined, repeatable setup experience. Many thanks to Bitcoin Mechanic for his contributions to the Bitcoin community.

Logs: `logpath` in `settings.json` controls where logs are saved. When `logpath` is a relative path it is resolved relative to `scripts_path` when run as root (for example, the default resolves to `/root/OC-mech-datum-boxes/datum_instlogs`). At the end of `main.sh`, the script will also attempt to copy user-side logs from the unprivileged user's home directory into `$scripts_path/$logpath/from_<user>` for easier collection.

---

For questions or support, please open an issue.
