# hc-monitor

[![tests](https://github.com/Pa1amar/hc-monitor/actions/workflows/tests.yml/badge.svg)](https://github.com/Pa1amar/hc-monitor/actions/workflows/tests.yml)

A single bash script that monitors an Ubuntu server through [healthchecks.io](https://healthchecks.io/).

Every 5 minutes a systemd timer runs the script. It checks disk space and inodes, memory and OOM kills, CPU load and usage, and the systemd services (including their automatic restarts), local ports and TLS certificates you choose, then reports to your healthchecks.io check:

- **all good** — a regular ping with a short summary;
- **something is wrong** — a ping to `<ping-url>/fail` with the list of problems, so the check goes down and healthchecks.io alerts you right away;
- **the server is down or offline** — pings stop, and healthchecks.io alerts you when the grace time runs out.

Each report is stored in the check's event log (open the check → Events → click an event).

A service can also get a file of its own with its units, ports and HTTP health endpoint, reported to a separate check — see [Services](#services).

## Requirements

- Ubuntu (or another Linux) with systemd, bash 4.4+ and GNU coreutils
- `curl` — the installer offers to install it with apt if it's missing
- `openssl` for certificate checks — preinstalled on Ubuntu
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
   - the systemd services to watch, space-separated (for example `nginx postgresql`) — names that don't exist are rejected;
   - the local ports to watch, space-separated (for example `22 443 53/udp`; a bare number means TCP);
   - the TLS certificates to watch, space-separated (for example `gw.example.com gw.example.com:9001`; a bare host name means port 443);
   - whether to change the thresholds (defaults: disk 90%, RAM 90%, load 2 per CPU core, CPU busy 90%, certificates 14 days, confirm a problem after 2 runs).

   For the lists, Enter keeps the current list (none on a fresh install) and `-` clears it.

   Then it shows the report, sends the first ping through the systemd unit and enables the timer. If the first ping fails, it prints `systemctl status hc-monitor.service` and leaves the timer off, so you can fix the cause and run `install` again.

3. In healthchecks.io set the check's schedule to **Period: 5 minutes, Grace Time: 10 minutes**. One missed ping won't raise a false alarm, and a silent server is reported within 15 minutes.

Keep the ping URL private: anyone who knows it can send "all good" pings to your check.

If you edit the script on Windows, keep LF line endings — with CRLF, bash fails with `$'\r': command not found`.

## What is checked

| Check | Reported as a problem when | Notes |
|---|---|---|
| Disk space and inodes | usage ≥ `DISK_MAX_PCT` on any local filesystem | `tmpfs`, `devtmpfs`, `squashfs` (snaps), `overlay` (Docker) and `iso9660` are skipped |
| Memory | used ≥ `MEM_MAX_PCT` | based on `MemAvailable`, so page cache doesn't count as used |
| OOM kills | the kernel's OOM killer killed a process since the previous run | counted by `oom_kill` in `/proc/vmstat`; process names come from the kernel log |
| CPU load | 15-minute load average ≥ CPU cores × `LOAD_MAX_PER_CPU` | the long window ignores short spikes |
| CPU usage | busy ≥ `CPU_MAX_PCT`, averaged since the previous run | busy = 100% − idle − iowait; steal (time taken by the hypervisor) counts as busy and is shown separately |
| Services | a listed unit is not `active` or `reloading` | a unit that doesn't exist is reported separately, so a typo doesn't look like a crash |
| Restarts | a listed unit was restarted automatically since the previous run | systemd's `NRestarts` counter: catches a service that crashes and comes back between checks; a manual restart resets it and raises no alarm |
| Ports | a listed local TCP or UDP port has no listening socket | read from `/proc/net`; `443` means TCP, `53/udp` means UDP; any local address counts (see below) |
| TLS certificates | a listed certificate expires in fewer than `CERT_MIN_DAYS` days, has expired, doesn't match the host name or isn't trusted | checked with `openssl s_client` the way clients see it (system CA store); `gw.example.com` means port 443 |

A check that can't run — for example `df` hanging for more than 10 seconds — is reported as a problem too, never skipped silently.

A problem is reported only once it has lasted `CONFIRM_RUNS` runs in a row (2 by default, about five minutes), so a one-off hiccup doesn't raise an alarm. Until then the report lists it under `Pending` and the check stays up:

```
All good

Pending:
- CPU: 95% busy (threshold 90%) (seen 1 of 2 runs)
```

A problem stays the same across runs while the text before its first colon does (for example `Disk /var`), even when the figures change; once it's gone, its count starts over. Set `CONFIRM_RUNS="1"` to report problems at once.

Restarts and OOM kills are events, not states, and are reported at once: the check goes down for one run and comes back up on the next one if nothing else happened, so you get an alert and, five minutes later, a recovery notice. The first run after installing or rebooting only records the counters.

Port checks look for a listening socket on any local address, loopback included, so:

- on stock Ubuntu systemd-resolved listens on 127.0.0.53:53, and `53/udp` looks fine even when your own DNS server is down;
- a socket-activated service (for example `ssh.socket` on Ubuntu 22.10+) keeps its port listening while systemd holds the socket, even if the service can't start — add the service to `SERVICES` too;
- ports that Docker publishes only through iptables (`"userland-proxy": false`) have no socket on the host and are reported as not listening.

Example report sent to `/fail`:

```
PROBLEMS (1):
- Disk /var: 93% used (threshold 90%)

Host: web-1
Disk /: 45% (inodes 12%)
Disk /var: 93% (inodes 30%)
RAM: 52% used of 7983 MiB
Load (1/5/15 min): 0.52 0.58 0.59, CPUs: 4
CPU: 38% busy over 5 min (steal 1%, iowait 2%)
Services: nginx=active, postgresql=active
Ports: 22/tcp=listening, 443/tcp=listening
TLS web-1.example.com:443: valid until 2027-03-01 (164 days)
```

A clean report starts with `All good`.

## Services

A service can get a file of its own with its systemd units, local ports and HTTP health endpoint, and report them to a separate healthchecks.io check. healthchecks.io only alerts when a check changes state: while the server check is already down (say, because of high load), a service that crashes on the same check raises no new alert — on a check of its own it does.

```bash
sudo hc-monitor.sh add nym-gateway      # asks for the settings; run it again to change them
sudo hc-monitor.sh remove nym-gateway
```

The settings are stored in `/root/.healthchecks/<name>/.env`, and you can write the file by hand too:

```bash
HC_PING_URL="https://hc-ping.com/<uuid>"        # the service's own check; empty: report with the server
SERVICES="nym-node"
PORTS="1789 8080 9000"
CERTS="gw.example.com:9001"
HTTP_URL="http://localhost:8080/api/v1/health"
HTTP_EXPECT='"status" *: *"up"'                 # the response must match this regular expression
```

- Set at least one of `SERVICES`, `PORTS`, `CERTS` and `HTTP_URL`; they are checked like the server settings.
- `HTTP_URL` must answer with a 2xx status within 10 seconds (redirects are followed). `HTTP_EXPECT` is an optional extended regular expression; without it any 2xx response is fine.
- With `HC_PING_URL`, the service sends its own report (to `/fail` when it lists problems), so give that check the same schedule: Period 5 minutes, Grace Time 10 minutes. It must be a different check from the server's. Without `HC_PING_URL`, the service's lines go into the server report, prefixed with `[<name>]`.
- The file is a shell script that runs as root on every check, so the file and its directories must belong to root and not be writable by group or others. A file that breaks this rule, fails to load or has invalid settings is skipped and reported as a problem in the server report.
- The next run picks up new and changed files, and `sudo hc-monitor.sh --dry-run` shows every report. `uninstall` keeps these files.

Example report of a service with its own check:

```
PROBLEMS (1):
- Port 9000/tcp: not listening

Host: node-1
Service: nym-gateway
Services: nym-node=active
Ports: 1789/tcp=listening, 8080/tcp=listening, 9000/tcp=not-listening
HTTP http://localhost:8080/api/v1/health: 200, expected text found
```

## Everyday commands

| Command | What it does |
|---|---|
| `sudo hc-monitor.sh --dry-run` | run the checks and print the reports without sending them |
| `journalctl -u hc-monitor` | logs: one line per report on every run |
| `systemctl list-timers hc-monitor.timer` | when the next run is |
| `sudo hc-monitor.sh add <name>` | add a service or change its settings |
| `sudo hc-monitor.sh remove <name>` | remove a service, after a confirmation |
| `sudo hc-monitor.sh install` | change the URL, services, ports or thresholds; current values are offered as defaults |
| `sudo hc-monitor.sh uninstall` | remove everything except service files, after a confirmation |

After uninstalling, pause or delete the check in healthchecks.io, and the checks of your services — otherwise they alert when the pings stop.

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
| `/var/lib/hc-monitor/cpu.stat` | 644 | CPU counters from the previous run, for the average |
| `/var/lib/hc-monitor/restarts.state` | 644 | restart counts of the watched units from the previous run |
| `/var/lib/hc-monitor/oom.state` | 644 | the OOM kill count from the previous run |
| `/var/lib/hc-monitor/confirm.state` | 644 | how many runs in a row each current problem has been seen |
| `/root/.healthchecks/<name>/.env` | 600 | settings of a service, written by `add` (kept by `uninstall`) |

`/etc/hc-monitor.conf` is a plain shell file, and the next run picks up any manual edits:

```bash
HC_PING_URL="https://hc-ping.com/<uuid>"
SERVICES="nginx postgresql"
PORTS="22 443 53/udp"
CERTS="web-1.example.com"
DISK_MAX_PCT="90"
MEM_MAX_PCT="90"
LOAD_MAX_PER_CPU="2"
CPU_MAX_PCT="90"
CERT_MIN_DAYS="14"
CONFIRM_RUNS="2"
```

To automate the setup, write this file first and then answer every installer question with Enter: `yes '' | head -n 20 | sudo bash hc-monitor.sh install`. Each question keeps the value from the file, so the order of the questions doesn't matter; an invalid value makes the installer stop with "input aborted".

## Exit codes

| Code | Meaning |
|---|---|
| 0 | every report delivered (even if they list problems), dry run done, install, uninstall, add or remove done or cancelled |
| 1 | a report not delivered, installation failed, input aborted, no such service |
| 2 | bad arguments or service name, no ping URL, unreadable or invalid config, not run with bash |

## Tests

The tests need Linux or WSL with bash and python3 (for a fake healthchecks.io endpoint). They never contact the real healthchecks.io: every HTTPS request is routed to a closed local port. GitHub Actions runs them, together with shellcheck, on Ubuntu 22.04 and 24.04 for every push.

```bash
bash tests/run-tests.sh           # all tests
bash tests/run-tests.sh install   # only tests whose name contains "install"
```
