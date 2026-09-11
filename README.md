# hc-monitor

A single bash script that monitors an Ubuntu server through [healthchecks.io](https://healthchecks.io/).

Every 5 minutes a systemd timer runs the script. It checks disk space and inodes, memory, CPU load and the systemd services you choose, then reports to your healthchecks.io check:

- **all good** — a regular ping with a short summary;
- **something is wrong** — a ping to `<ping-url>/fail` with the list of problems, so the check goes down and healthchecks.io alerts you right away;
- **the server is down or offline** — pings stop, and healthchecks.io alerts you when the grace time runs out.

Each report is stored in the check's event log (open the check → Events → click an event).

## Requirements

- Ubuntu (or another Linux) with systemd, bash 4.4+, GNU coreutils and `ss` from iproute2 — all preinstalled on Ubuntu
- `curl` — the installer offers to install it with apt if it's missing
- root access (`sudo`)
- a check on healthchecks.io — **one check per server**: if two servers ping the same check, a live server hides a dead one

## Quick start

1. In healthchecks.io create a check and copy its ping URL (`https://hc-ping.com/<uuid>`).

2. On the server, clone the repository and run the installer. The repository is public, so no GitHub login is needed:

   ```bash
   git clone https://github.com/Pa1amar/hc-monitor.git
   cd hc-monitor
   sudo bash hc-monitor.sh install
   ```

   No git on the server? The installer is a single file, so download just that:

   ```bash
   curl -fsSLO https://raw.githubusercontent.com/Pa1amar/hc-monitor/main/hc-monitor.sh
   sudo bash hc-monitor.sh install
   ```

   If the server can't reach GitHub, or you're installing your own modified copy, copy the file over SSH instead: `scp hc-monitor.sh user@your-server:~`.

   The installer asks for:
   - the ping URL;
   - the systemd services to watch, space-separated (for example `nginx postgresql`), or Enter for none — names that don't exist are rejected;
   - the local ports to watch, space-separated (for example `22 443 53/udp`; a bare number means TCP), or Enter for none;
   - whether to change the thresholds (defaults: disk 90%, RAM 90%, load 2 per CPU core).

   Then it shows the report, sends the first ping through the systemd unit and enables the timer. If the first ping fails, it prints `systemctl status hc-monitor.service` and leaves the timer off, so you can fix the cause and run `install` again.

3. In healthchecks.io set the check's schedule to **Period: 5 minutes, Grace Time: 10 minutes**. One missed ping won't raise a false alarm, and a silent server is reported within 15 minutes.

Keep the ping URL private: anyone who knows it can send "all good" pings to your check.

If you edit the script on Windows, keep LF line endings — with CRLF, bash fails with `$'\r': command not found`.

## What is checked

| Check | Reported as a problem when | Notes |
|---|---|---|
| Disk space and inodes | usage ≥ `DISK_MAX_PCT` on any local filesystem | `tmpfs`, `devtmpfs`, `squashfs` (snaps), `overlay` (Docker) and `iso9660` are skipped |
| Memory | used ≥ `MEM_MAX_PCT` | based on `MemAvailable`, so page cache doesn't count as used |
| CPU load | 15-minute load average ≥ CPU cores × `LOAD_MAX_PER_CPU` | the long window ignores short spikes |
| Services | a listed unit is not `active` or `reloading` | a unit that doesn't exist is reported separately, so a typo doesn't look like a crash |
| Ports | a listed local TCP or UDP port has no listening socket | checked with `ss` on any local address; `443` means TCP, `53/udp` means UDP |

A check that can't run — for example `df` hanging for more than 10 seconds — is reported as a problem too, never skipped silently.

Example report sent to `/fail`:

```
PROBLEMS (1):
- Disk /var: 93% used (threshold 90%)

Host: web-1
Disk /: 45% (inodes 12%)
Disk /var: 93% (inodes 30%)
RAM: 52% used of 7983 MiB
Load (1/5/15 min): 0.52 0.58 0.59, CPUs: 4
Services: nginx=active, postgresql=active
Ports: 22/tcp=listening, 443/tcp=listening
```

A clean report starts with `All good`.

## Everyday commands

| Command | What it does |
|---|---|
| `sudo hc-monitor.sh --dry-run` | run the checks and print the report without sending it |
| `journalctl -u hc-monitor` | logs: one line per run |
| `systemctl list-timers hc-monitor.timer` | when the next run is |
| `sudo hc-monitor.sh install` | change the URL, services, ports or thresholds; current values are offered as defaults |
| `sudo hc-monitor.sh uninstall` | remove everything, after a confirmation |

After uninstalling, pause or delete the check in healthchecks.io — otherwise it alerts when the pings stop.

## Updating

```bash
cd hc-monitor
git pull
sudo bash hc-monitor.sh install
```

`install` replaces the installed copy and offers your current settings as defaults — press Enter to keep them. It then sends a fresh report and keeps the timer on. If you downloaded the single file with `curl`, download it again the same way and re-run `install`.

## Installed files

| Path | Mode | Contents |
|---|---|---|
| `/usr/local/bin/hc-monitor.sh` | 700 | the script |
| `/etc/hc-monitor.conf` | 600 | settings |
| `/etc/systemd/system/hc-monitor.service` | 644 | oneshot unit that runs the script |
| `/etc/systemd/system/hc-monitor.timer` | 644 | runs the unit every 5 minutes (`OnCalendar=*:0/5`) |

`/etc/hc-monitor.conf` is a plain shell file, and the next run picks up any manual edits:

```bash
HC_PING_URL="https://hc-ping.com/<uuid>"
SERVICES="nginx postgresql"
PORTS="22 443 53/udp"
DISK_MAX_PCT="90"
MEM_MAX_PCT="90"
LOAD_MAX_PER_CPU="2"
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | report delivered (even if it lists problems), dry run done, install or uninstall done |
| 1 | report not delivered, installation failed, input aborted |
| 2 | bad arguments, no ping URL, unreadable or invalid config, not run with bash |

## Tests

The tests need Linux or WSL with bash and python3 (for a fake healthchecks.io endpoint). They never contact the real healthchecks.io: every HTTPS request is routed to a closed local port.

```bash
bash tests/run-tests.sh           # all tests
bash tests/run-tests.sh install   # only tests whose name contains "install"
```
