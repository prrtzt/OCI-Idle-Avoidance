## OCI-Idle-Avoidance
A set of scripts designed to maintain a minimum level of CPU usage on Oracle Cloud VMs, preventing them from being reclaimed due to idling. Ideal for environments with fluctuating resource demands.

### Overview
This repository contains scripts to help maintain a minimum level of CPU usage on a virtual machine (VM) to prevent Oracle Cloud Infrastructure (OCI) from shutting it down due to idling. This is in response to a policy change in OCI where VMs can be reclaimed if they idle for a certain period.

The scripts work by monitoring the CPU usage and spinning up "load generator" Python scripts to consume CPU cycles when usage drops below a certain level. If a user's VM is running services that require a lot of resources at times and idles at other times, this script will ensure that the CPU usage stays above the OCI threshold, ensuring the VM remains active even during idle times.

### Structure
This repository contains two scripts and a systemd service file:

1. A Bash script (`load_controller.sh`): This script continuously monitors CPU usage and starts/stops "load generator" Python processes based on thresholds. It starts 5 generators below 19%, starts 1 generator between 19% and 22%, stops 1 generator above 27%, and stops all generators above 80%. It also enforces a maximum generator count to prevent runaway process growth. All activity is logged with timestamps.

2. A Python script (`load_generator.py`): This script runs a loop that consumes CPU cycles. The number of cycles consumed per second can be configured by adjusting the argument passed to the script.

3. A systemd service file (`oci-idle-avoidance.service`): Allows the controller to run as a system service with automatic startup on boot and restart on failure.

## Requirements

This script requires:

1. **Python 3.x** - For running the load generator script
2. **sysstat package** - For CPU monitoring via `mpstat` command
3. **systemd** - For running as a service (optional, but recommended)
4. **bc** - For floating-point arithmetic in bash

To install these on Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install python3 sysstat bc
```

**Note:** `screen` is no longer required when using the systemd service method, but can be used as an alternative for manual execution.

### Installation and Setup

#### Step 1: Clone the Repository

Clone this repository to your OCI VM:

```bash
cd /opt
sudo git clone https://github.com/pierre/OCI-Idle-Avoidance.git
cd OCI-Idle-Avoidance
```

#### Step 2: Make Scripts Executable

```bash
sudo chmod +x scripts/load_controller.sh
```

#### Step 3: Install as a Systemd Service (Recommended)

Installing as a systemd service ensures the script runs automatically on boot and restarts if it crashes.

1. Edit the service file to update the installation path if needed:

```bash
sudo nano oci-idle-avoidance.service
```

Update the `WorkingDirectory` and `ExecStart` paths if you cloned the repository to a different location.
The service is configured to run as `nobody`; ensure your install path is readable by that user.

2. Copy the service file to systemd:

```bash
sudo cp oci-idle-avoidance.service /etc/systemd/system/
```

3. Reload systemd and enable the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable oci-idle-avoidance
sudo systemctl start oci-idle-avoidance
```

4. Check the service status:

```bash
sudo systemctl status oci-idle-avoidance
```

#### Managing the Service

```bash
# View live logs
sudo journalctl -u oci-idle-avoidance -f

# View controller log file (configured by the service unit)
sudo tail -f /var/log/oci-idle-avoidance/load_controller.log

# Stop the service
sudo systemctl stop oci-idle-avoidance

# Restart the service
sudo systemctl restart oci-idle-avoidance

# Disable automatic startup
sudo systemctl disable oci-idle-avoidance
```

### Alternative: Running Manually with Screen

If you prefer not to use systemd, you can run the script manually using `screen`:

```bash
cd /opt/OCI-Idle-Avoidance/scripts
screen -S oci-idle
./load_controller.sh
```

Detach from screen with `Ctrl + A`, then `D`. Reattach later with `screen -r oci-idle`.

Remember, a busy VM is a happy VM! Happy computing!
