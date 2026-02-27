# OpenCloud Tenant Installer (Tailscale-Only)

A streamlined, interactive bash script to deploy an OpenCloud tenant using Docker, specifically designed to be accessed securely over a Tailscale network.

## Features

- **Interactive Setup**: Prompts for necessary configuration like Tailscale IP, ports, and storage paths.
- **Tailscale Integration**: Automatically detects your Tailscale IPv4 address and binds the OpenCloud instance to it, ensuring it's only accessible within your tailnet.
- **Dockerized Deployment**: Generates a `docker-compose.yml` and manages the container lifecycle automatically.
- **Automated Health Checks**: Waits for the OpenCloud container to become healthy before proceeding.
- **First-Time Initialization**: Automatically runs the initial OpenCloud setup to generate admin credentials.
- **Safe Re-deployment**: Detects existing installations and prompts before tearing them down.

## Prerequisites

Before running the installer, ensure the following are installed and running on your system:

- **Linux OS** (Tested on standard distributions like Ubuntu/Debian)
- **Root Privileges** (The script must be run as `root` or via `sudo`)
- **Docker**: The Docker daemon must be installed and running. *(Note: Docker installed via Snap is not supported due to strict path confinement. Please use the official Docker installation script).*
- **Docker Compose**: Required to orchestrate the container (the `docker compose` plugin).
- **Tailscale**: Must be installed, authenticated, and connected to your tailnet.

## Installation

You can install and run the script directly using `curl`:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/wyntrson/OpenCloud-installer-script/main/installer.sh)"
```

## Configuration Prompts

During installation, the script will ask for the following details. Press `Enter` to accept the default values shown in brackets.

1. **Tailscale IP**: The IPv4 address of your machine on the Tailscale network. The script will attempt to auto-detect this.
2. **OpenCloud Port**: The port to bind OpenCloud to (Default: `8080`).
3. **Storage Path**: The absolute path on your host machine where OpenCloud data will be stored (Default: `/mnt/clouddata`).
4. **Tailscale MagicDNS Domain**: Your machine's Tailscale domain name (e.g., `machine.alias.ts.net`).

## Post-Installation

Once the script completes successfully, it will output the admin credentials. **Save the admin password immediately**, as it cannot be recovered later.

### Exposing via Tailscale Serve / Funnel

The script binds OpenCloud to your Tailscale IP on the specified port (e.g., `http://100.x.y.z:8080`). To access it securely via HTTPS using your MagicDNS domain, you can use Tailscale Serve:

```bash
sudo tailscale serve --bg --https=443 http://<YOUR_TAILSCALE_IP>:<YOUR_PORT>
```
*(Note: Adjust `<YOUR_TAILSCALE_IP>:<YOUR_PORT>` to your actual bind IP and port).*

## File Locations

- **Docker Compose File**: `/opt/opencloud/docker-compose.yml`
- **OpenCloud Config**: `/opt/opencloud/config`
- **Data Storage**: User-defined (Default: `/mnt/clouddata`)

## Troubleshooting

- **Script fails with "Docker installed via snap is not supported"**: Snap packages have strict path confinement and cannot access `/opt` or `/mnt`. Remove the snap version and install via the official script:
  ```bash
  sudo snap remove docker
  curl -fsSL https://get.docker.com | sh
  ```
- **Script fails with "Docker daemon is not running"**: Ensure Docker is installed and the service is active (`sudo systemctl status docker`).
- **Tailscale IP not detected**: Ensure Tailscale is running and connected (`sudo tailscale status`).
- **Container unhealthy**: Check the container logs for errors:
  ```bash
  docker compose -f /opt/opencloud/docker-compose.yml logs
  ```

## License

This project is licensed under the [GNU General Public License v3.0 (GPL-3.0)](LICENSE).


