# Performance diagnostics

Enoshima records enough local history to explain a sudden slowdown after it
has ended. Collection is delegated to upstream Arch packages; the repository
does not add a custom sampler, database, watcher, or upload service.

## Retained data

| Source | Interval | Retention | Location | Purpose |
| --- | ---: | ---: | --- | --- |
| atop | 60 seconds | 14 retention generations plus the current log | `/var/log/atop/` | Sampled process CPU, memory, and disk plus host network and pressure history |
| sysstat | 30 seconds | 28 days | `/var/log/sa/` | Host CPU, run queue, memory, paging, per-device IO, power, thermal, and network trends |
| systemd journal | event driven | 30 days, at most 1 GiB | `/var/log/journal/` | Kernel, driver, thermal, OOM, service, and application events |

Atop history is root-only and its service uses `UMask=0077`. Process accounting
is explicitly disabled with an empty `ATOPACCT` environment value, and the
package-provided `atopacct.service` remains disabled. This prevents both the
accounting daemon and atop's crash-unsafe `/var/cache/atop.d/atop.acct`
fallback. Atop therefore records processes that are alive at a 60-second
sample boundary but cannot reconstruct a process that starts and exits wholly
between samples. This is an intentional privacy, storage, and overhead bound.
Per-process network attribution is also unavailable because Enoshima does not
install the optional netatop collector.
Sysstat explicitly collects the optional `DISK` and `POWER` activity groups so
device latency, CPU frequency, available thermal sensors, and battery trends
remain available after an incident. POWER also records local USB vendor,
product, and power metadata. Sysstat history and its directory are root-only
(`UMASK=0077`), so reading either binary history requires `sudo`. Journald
remains readable according to the standard `systemd-journal` group policy.
Nothing is uploaded or synchronized.
Applying the 1 GiB journal ceiling can vacuum older archived journal files on a
machine whose current history exceeds that limit; active
files can also make actual use temporarily exceed the ceiling.

When the managed `DISK` and `POWER` activity groups are first enabled on an
existing installation, sysstat cannot extend the schema of an already-created
daily `saDD` file. Convergence pauses collection, preserves that file under a
root-only `/var/log/sa/.enoshima-migrated-<epoch>/` directory, creates a new
same-day record with the managed schema, and resumes the timer. The preserved
record remains available for incident reconstruction for up to 28 days; later
convergence removes migration archives older than that retention boundary.

Optional atop network accounting (`netatop`) and the GPU collector stay
disabled. GPU investigation is on demand through `nvtop`; deeper CPU scheduling
and call-stack capture is on demand through Sysprof. Systemd IO accounting is
the default except for units that explicitly opt out; the deprecated
CPU-accounting default is not configured.

## When a slowdown is happening

Open Vicinae with `Super+Shift+Space` and run one of the managed Performance
script commands, or start the tools directly:

```bash
resources
sudo iotop --only --processes --accumulated
nvtop
sysprof
s-tui
sudo turbostat
sudo powertop
```

Resources is the default low-friction view. Use iotop-c when storage latency is
suspected, nvtop for GPU engine/process load, and Sysprof only when a bounded
trace is needed. Use `s-tui` for an interactive CPU and thermal dashboard,
`sudo turbostat` for detailed frequency and residency counters, and
`sudo powertop` for measurement only; the repository does not apply its
automatic tuning persistently.

## After the slowdown

First record the approximate start and end time. Then correlate the three
independent histories without modifying system policy:

```bash
sudo atop -r /var/log/atop/atop_YYYYMMDD
sudo sar -A -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
sudo sar -d -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
sudo sar -m CPU,FREQ,TEMP -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
sudo journalctl --since 'YYYY-MM-DD HH:MM:SS' --until 'YYYY-MM-DD HH:MM:SS'
```

In atop, use `t`/`T` to move through samples and sort by CPU, memory, disk, or
network. In sysstat, compare run queue, paging, IO wait, device latency, and
network errors. In the journal, look for OOM kills, GPU resets, NVMe errors,
thermal throttling, service restart loops, and suspend/resume transitions.

Useful focused queries include:

```bash
sudo journalctl -k --since today | rg -i 'oom|out of memory|gpu|drm|nvme|thermal|thrott|reset|stall'
systemd-cgtop --depth=3
systemctl status atop.service sysstat-collect.timer
```

Do not tune TLP, kernel parameters, schedulers, or application limits until the
same timestamped evidence identifies a repeatable bottleneck.

## Physical retention and overhead gate

On `tpx1c13`, wait at least 65 seconds after convergence and confirm that atop
and sysstat both add a sample. Reboot once, then confirm the previous boot and
the pre-reboot samples remain readable:

```bash
sudo find /var/log/atop -maxdepth 1 -type f -name 'atop_*' -size +0c
sudo find /var/log/sa -maxdepth 1 -type f -name 'sa[0-9][0-9]' -size +0c
sudo journalctl -b -1 --no-pager -n 20
```

Record ten idle minutes with the collectors enabled and compare CPU wakeups,
resident memory, history-file growth, battery discharge, and temperatures with
the existing physical baseline. Confirm that the root-only sysstat record's
USB metadata is acceptable for the local device inventory and remains local.
The three collectors plus systemd cgroup IO accounting must not open an
external network connection. Run a short, non-destructive CPU/IO load across at
least one complete 60-second atop sample boundary. The load should appear in
atop, `sar -d`, and journal-adjacent timestamps; `sar -m CPU,FREQ,TEMP` must also
read the retained POWER activity before this gate is accepted.
