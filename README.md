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

## Usage

1. Clone this repository
2. Review and modify the `settings.json` file to match your requirements
3. Run the `main.sh` script as root **NOT SUDO**:

```bash
./main.sh
```

## Requirements

- A Debian-based Linux distribution (Ubuntu, Debian, etc.)
- Root privileges (not sudo)
- Internet connection for downloading dependencies and source code
- Sufficient disk space for the Bitcoin blockchain

## Configuration

The `settings.json` file contains key configuration parameters:
- User account settings (username and creation options)
- Log directory path
- Build options:
  - `cpu_cores`: Number of CPU cores to use during compilation (speeds up build on multi-core systems)
  - `bitcoin_knots_tag`: GitHub tag to checkout for Bitcoin Knots (default: v28.1.knots20250305)
  - `verify_signatures`: Whether to verify Git tag signatures for Bitcoin Knots (default: true)
  - `key_fingerprint`: PGP key fingerprint used to verify signatures (default: 1A3E761F19D2CC7785C5502EA291A2C45D0C504A)
- DATUM options:
  - `coinbase_tag_primary`: Primary coinbase tag (default: DATUM)
  - `coinbase_tag_secondary`: Secondary coinbase tag (default: empty)
- Required system packages for building and running the services

Please review and customize this file before running the scripts.

## Security Features

The build process includes security measures to ensure the integrity of the Bitcoin Knots source code:

- **Signature Verification**: The script verifies PGP signatures on Git tags to ensure the Bitcoin Knots source hasn't been tampered with
- **Isolated GPG Environment**: Signature verification takes place in an isolated GPG environment to avoid conflicts with existing keys

These features are enabled by default but can be disabled in the settings.json file if needed.

## Important Note

Please pay attention to the values generated and refrain from blindly using the settings found here. Always review the generated configurations to ensure they meet your specific requirements and security needs.

## Credits

These scripts are based on the work of [Bitcoin Mechanic](https://github.com/bitcoinmechanic). This version adds an automation layer ontop of the entire workflow process to create a streamlined, repeatable setup experience. Many thanks to Bitcoin Mechanic for his contributions to the Bitcoin community.

---

For questions or support, please open an issue.
