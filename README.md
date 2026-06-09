# DATUM Box Setup Scripts

## Project status

This repository is no longer maintained.

The solutions previously provided here have been superseded by packages now available through the official Debian Backports repositories. These packages are also expected to be included in future Debian releases, including Debian 14 "forky".

### Using Debian Backports

On an existing Debian installation, enable Backports by adding a backports source for your Debian release:

```bash
. /etc/os-release

sudo tee /etc/apt/sources.list.d/debian-backports.sources >/dev/null <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${VERSION_CODENAME}-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

sudo apt update
```

Then install the needed package from Backports:

```bash
sudo apt install -t "${VERSION_CODENAME}-backports" <package-name>
```

For example, Debian 13 uses `trixie-backports`, while Debian 12 uses `bookworm-backports`.



