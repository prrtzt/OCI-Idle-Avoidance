## OCI-Idle-Avoidance

A set of scripts designed to maintain a minimum level of CPU usage on Oracle Cloud VMs, preventing them from being reclaimed due to idling. Ideal for environments with fluctuating resource demands.

### Overview

This repository contains scripts to help maintain a minimum level of CPU usage on a virtual machine (VM) to prevent Oracle Cloud Infrastructure (OCI) from shutting it down due to idling. This is in response to a policy change in OCI where VMs can be reclaimed if they idle for a certain period.

The scripts work by monitoring the CPU usage and spinning up "load generator" Python scripts to consume CPU cycles when usage drops below a certain level. If a user's VM is running services that require a lot of resources at times and idles at other times, this script will ensure that the CPU usage stays above the OCI threshold, ensuring the VM remains active even during idle times.

### Structure

This repository contains two scripts and configuration files:

1. **Bash script (`load_controller.sh`)**: Continuously monitors CPU usage and starts/stops "load generator" Python processes based on thresholds. Includes graceful signal handling, input validation, and secure logging.

2. **Python script (`load_generator.py`)**: Runs a loop that consumes CPU cycles. Handles signals gracefully for clean shutdown.

3. **Systemd service file (`oci-idle-avoidance.service`)**: Allows the controller to run as a system service with automatic startup on boot, restart limits, and security hardening.

4. **Logrotate config (`oci-idle-avoidance.logrotate`)**: Prevents log files from growing indefinitely.

### Configuration

The controller uses the following thresholds (configurable in `load_controller.sh`):

| Threshold | Default | Action |
|-----------|---------|--------|
| `LOW_BURST_THRESHOLD` | 19% | Below this: start 5 generators |
| `LOW_SINGLE_THRESHOLD` | 22% | Below this: start 1 generator |
| `HIGH_THRESHOLD` | 27% | Above this: stop 1 generator |
| `CRITICAL_THRESHOLD` | 80% | Above this: stop ALL generators |

**Hysteresis Zone (22-27%)**: No action is taken in this range to prevent oscillation.

Additional settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `MAX_GENERATORS` | 80 | Maximum concurrent generator processes |
| `GENERATOR_USAGE` | 0.02 | CPU fraction per generator (0.0-1.0) |
| `MPSTAT_INTERVAL` | 5 | CPU sampling interval in seconds |
| `CONTROLLER_LOCK_FILE` | `<log-dir>/load_controller.lock` | Lock file path used to prevent multiple controller instances |

The `GENERATOR_USAGE` and `CONTROLLER_LOCK_FILE` can also be set via environment variables.

## Requirements

This script requires:

1. **Python 3.x** - For running the load generator script
2. **sysstat package** - For CPU monitoring via `mpstat` command
3. **systemd** - For running as a service (optional, but recommended)
4. **bc** - For floating-point arithmetic in bash
5. **coreutils** - For `timeout` command
6. **procps** - For `ps` command used in process validation

To install these on Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install python3 sysstat bc coreutils procps
```

**Note:** `screen` is no longer required when using the systemd service method, but can be used as an alternative for manual execution.

### Installation and Setup

#### Step 1: Clone the Repository

Clone this repository to your OCI VM:

```bash
cd /opt
sudo git clone https://github.com/prrtzt/OCI-Idle-Avoidance.git
cd OCI-Idle-Avoidance
```

#### Step 2: Make Scripts Executable

```bash
sudo chmod +x scripts/load_controller.sh
```

#### Step 3: Install as a Systemd Service (Recommended)

Installing as a systemd service ensures the script runs automatically on boot and restarts if it crashes.

1. **If installing to a non-standard path**, edit the service file:

```bash
sudo nano oci-idle-avoidance.service
```

Update `WorkingDirectory` and `ExecStart` to match your installation path:

```ini
WorkingDirectory=/your/custom/path/OCI-Idle-Avoidance/scripts
ExecStart=/your/custom/path/OCI-Idle-Avoidance/scripts/load_controller.sh
```

The service runs as an unprivileged dynamic user (`DynamicUser=true`), so no manual user creation is required.

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

#### Customizing Generator Usage

To change how much CPU each generator consumes (default is 0.02), set the environment variable:

```bash
# In /etc/systemd/system/oci-idle-avoidance.service
Environment=GENERATOR_USAGE=0.03
```

Then reload: `sudo systemctl daemon-reload && sudo systemctl restart oci-idle-avoidance`

To set a custom lock file path (optional):

```bash
# In /etc/systemd/system/oci-idle-avoidance.service
Environment=CONTROLLER_LOCK_FILE=/var/log/oci-idle-avoidance/load_controller.lock
```

#### Setting Up Log Rotation (Recommended)

To prevent log files from growing indefinitely, install the logrotate configuration:

```bash
sudo cp oci-idle-avoidance.logrotate /etc/logrotate.d/oci-idle-avoidance
```

This rotates logs weekly, keeping 4 compressed copies.

### Running Smoke Tests

Run the lightweight test suite locally:

```bash
./tests/run_smoke_tests.sh
```

### Alternative: Running Manually with Screen

If you prefer not to use systemd, you can run the script manually using `screen`:

```bash
cd /opt/OCI-Idle-Avoidance/scripts
screen -S oci-idle
./load_controller.sh
```

Detach from screen with `Ctrl + A`, then `D`. Reattach later with `screen -r oci-idle`.

### Troubleshooting

**Service fails to start:**
- Check paths in service file match installation location
- Ensure the installation path and scripts are readable/executable by unprivileged users:
  `sudo chmod a+rx /opt /opt/OCI-Idle-Avoidance /opt/OCI-Idle-Avoidance/scripts /opt/OCI-Idle-Avoidance/scripts/load_controller.sh /opt/OCI-Idle-Avoidance/scripts/load_generator.py`

**No log output:**
- Check log directory permissions: `ls -la /var/log/oci-idle-avoidance/`
- View journal logs: `journalctl -u oci-idle-avoidance -n 50`

**High CPU usage:**
- The controller will automatically stop generators if CPU exceeds 80%
- Reduce `GENERATOR_USAGE` value for finer control

Remember, a busy VM is a happy VM! Happy computing!
