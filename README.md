# Project status

This repository is no longer maintained.

The solutions previously provided here have been superseded by packages now available through the official Debian Trixie Backports repository. These packages are also expected to be included by default in future Debian releases, including Debian 14 "forky".

## Using Debian Trixie Backports

On an existing Debian Trixie installation, enable Backports by adding the Trixie Backports source:

```bash
sudo tee /etc/apt/sources.list.d/debian-backports.sources >/dev/null <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

sudo apt update
```

Then install the needed package from Trixie Backports:

```bash
sudo apt install -t trixie-backports <package-name>
```
