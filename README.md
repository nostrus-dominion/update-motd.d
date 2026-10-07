# Nostrus Dominion MOTD

A Bash MOTD with 36 available modules. Choose the modules, service providers,
and monitoring targets for each machine during installation. The complete
installation lives under `/etc/update-motd.d/`.

## Install

Extract the archive, enter `update-motd.d`, and run:

```bash
chmod +x install.sh
sudo ./install.sh --replace-legacy
```

The interactive installer asks for:

1. Providers: systemd, OpenRC, SysV, Docker, Podman, classic LXC, or LXD.
   Choose one host service manager at most; container providers can coexist.
2. Modules: choose displayed numbers or filenames, separated by spaces or
   commas. Enter accepts the default; `all` chooses every available module.
3. Exact host service names and container/instance names to monitor.

Empty host service lists monitor no services. Empty container lists show all
visible containers. The installer accepts exact names; it does not enumerate
all installed services or containers. Systemd names include the suffix, for
example `ssh.service` and `nginx.service`; OpenRC/SysV use init-script names.
Only selected module scripts are installed. The installer does not install
optional dependencies or start/restart services.

For an unattended install:

```bash
sudo ./install.sh --non-interactive --replace-legacy \
  --providers systemd,docker \
  --modules '10-hostname,11-time-sync,20-system-info,32-disk-space,40-services,45-docker' \
  --services 'ssh.service nginx.service' \
  --docker-containers 'plex jellyfin'
```

Other target flags are `--podman-containers`, `--lxc-containers`, and
`--lxd-instances`. Provider choices determine the default monitoring modules;
an explicit `--modules` list replaces that default. Include each monitoring
module you intend to use.

On unattended reinstalls without selection flags, existing machine settings
and the effective module list are preserved. With new selections, the installer
replaces service/provider/module selection assignments and retains other
machine settings. The effective settings are validated before installed files
are changed. A new module requires rerunning the installer from the full
extracted repo; the installed installer can refresh only its installed subset.

## Installed layout

All paths below are relative to `/etc/update-motd.d/`:

| Path | Purpose |
| --- | --- |
| `10-main` | Single executable entry for the system login runner |
| `modules/` | Selected numbered module scripts, including `11-time-sync` |
| `config/motd.conf` | Machine configuration; edit this file directly |
| `config/colors.conf` | Shared palette; preserved on reinstall |
| `config/motd.conf.example` | Complete settings reference |
| `lib/framework.sh` | Shared configuration, checks, and formatting helpers |
| `bin/motd` | Renderer and preview command |
| `install.sh` | Installer for the available installed subset |
| `README.md`, `FRAMEWORK.md` | Usage and framework walkthrough |
| `cache/` | Root-owned cached module output |
| `backups/` | Previous settings, scripts, and retired installations |

The system MOTD runner does not recurse into subdirectories. It runs
`10-main`, which calls `bin/motd` and renders the selected numbered scripts
in `modules/`. This avoids executing each module a second time. `install.sh`
is excluded from the normal `run-parts` name rules because its name has a dot.
Other distribution MOTD scripts remain in place and can print their own output.

No configuration is read from `.bash_local`. User and root previews read the
same machine settings. There is no copy/sync operation and no generated file
under `/usr/local`. The installer does not add shell aliases or edit PAM/SSH.
It targets GNU/Linux systems using an existing update-motd/PAM hook; other
distributions can invoke `/etc/update-motd.d/10-main` from their MOTD hook.

## Configure and preview

```bash
sudo vim /etc/update-motd.d/config/motd.conf
sudo vim /etc/update-motd.d/config/colors.conf

/etc/update-motd.d/bin/motd --list
/etc/update-motd.d/bin/motd --plain --no-cache
/etc/update-motd.d/bin/motd --module 11-time-sync --debug --no-cache
```

Changes are read on the next render; no restart or sync step is needed.
Cache fingerprints include the configuration and palette, so edits invalidate
previous results. Use `--no-cache` to collect fresh data immediately.

For example, this machine might use:

```bash
MOTD_MODULES=(10-hostname 11-time-sync 32-disk-space 40-services 45-docker)
MOTD_SERVICE_PROVIDER=systemd
declare -gA MOTD_SERVICES=([ssh.service]="SSH" [nginx.service]="Nginx")
MOTD_DOCKER_CONTAINERS=(plex jellyfin)

MOTD_ROLE="Media / storage"
MOTD_DISK_PATHS=(/ /mnt/storage)
MOTD_REQUIRED_MOUNTS=(/mnt/storage)
MOTD_USAGE_WARN=75
MOTD_USAGE_CRIT=90
```

The installer writes module names in numeric order, placing `11-time-sync`
immediately after `10-hostname`. Runtime display order follows `MOTD_MODULES`.
An empty array produces no output. `--module NAME` previews a disabled but
installed module; `--all` previews every installed module. Use the full repo's
`./bin/motd` to preview modules before installing them.

`config/motd.conf` is trusted Bash and should remain root-owned. Keep it to
settings, with `declare -gA` for associative arrays. Storage, endpoints,
process patterns, thresholds, and display options are documented in
`config/motd.conf.example`. Configure palette mappings in `colors.conf`, which
loads after the machine config. For an isolated test, use
`bin/motd --config /path/to/test.conf --plain`.

Hardware, certificates, Fail2Ban, VPN, and container checks may require root
or extra permissions. Root's container context can differ from the user's,
especially for rootless Docker/Podman. Time sync uses systemd/timedatectl and
skips on other init systems. User previews skip caching when the configured
cache directory is not writable and owned by that user; they do not create a
cache in the user's home. Temporary rendering work uses the normal system
temporary directory.

## Upgrade and stage

`--replace-legacy` backs up and retires recognized numbered scripts from this
repo that are already at the top of `/etc/update-motd.d`. Without the flag,
the installer stops before changing those files. It preserves unrelated
scripts and backs up the previous managed installation under `backups/`.

If upgrading either earlier expanded layout, the installer imports its system
settings from `/etc/nostrus-motd/motd.conf` when a new config does not yet exist.
It preserves the palette, maps `82-time-sync` to `11-time-sync`, and moves
recognized old `/usr/local` renderer/library files and their configuration into
`backups/`. It never reads or edits home shell files. Old host-profile selection
is no longer used; select the desired modules/providers during installation.
Settings that exist only in an old `.bash_local` block must be transferred
manually into the new machine config.

To inspect an isolated installation:

```bash
./install.sh --destdir /tmp/motd-stage --non-interactive \
  --providers systemd --modules '10-hostname,11-time-sync,40-services' \
  --services 'ssh.service'
/tmp/motd-stage/etc/update-motd.d/bin/motd --list
```

The staged login entry resolves its renderer relative to itself, so it also
works in the staging directory. Nothing is installed into the real system.

## Modules

| Module | Information |
| --- | --- |
| `10-hostname` | Hostname banner and role |
| `11-time-sync` | NTP synchronization and timezone |
| `20-system-info` | Date, distribution, kernel, uptime |
| `21-cpu-load` | CPU model, logical CPUs, normalized load |
| `22-memory` | RAM and swap usage |
| `23-temperatures` | Sensor temperatures |
| `24-gpu` | GPU names, NVIDIA metrics, AMD utilization and VRAM |
| `25-top-processes` | Top CPU / memory consumers, without command arguments |
| `26-network` | IPv4 and optional IPv6 addresses |
| `27-listening-ports` | Listening TCP / UDP sockets |
| `28-raspberry-pi` | Temperature, current / historical throttling flags |
| `30-disk-health` | SMART status and SATA / NVMe temperatures |
| `31-mounts` | Required mountpoints |
| `32-disk-space` | Filesystem capacity and bars |
| `33-raid` | Linux md health, degradation, synchronization |
| `34-zpool-status` | ZFS health and error details |
| `35-zpool` | ZFS capacity and bars |
| `40-services` | Selected systemd, OpenRC, or SysV service states |
| `41-failed-units` | Failed systemd units |
| `42-systemd-timers` | Upcoming timers |
| `43-http-checks` | Application HTTP endpoints |
| `44-processes` | Selected process checks |
| `45-docker` | Docker container state and health |
| `46-lxc` | Classic LXC container states |
| `47-podman` | Podman container state and health |
| `48-lxd` | LXD container / VM states |
| `50-ssl-cert` | Certificate expiry |
| `60-pia-vpn` | PIA region, addresses, forwarded port |
| `70-fail2ban` | Retained ban / restore / unban log totals |
| `71-fail2ban-status` | Current jail counters |
| `80-update` | Cached APT, pacman, or DNF updates |
| `81-reboot-required` | Distribution reboot-required flag |
| `90-last-logins` | Recent login records |
| `91-other-users` | Current sessions |
| `95-lolcat` | Optional fortune / cowsay / rainbow |
| `98-notes` | Administrator notes |

Update checks do not refresh repositories, install updates, or query the AUR.
An absent reboot flag is reported as an absent flag, not proof that no reboot
is needed. Fail2Ban log history describes retained logs; use `71-fail2ban-status`
for current jail counters.

## Dependencies and verification

The base renderer requires Bash 4.4+, GNU coreutils (including `timeout`,
`numfmt`, and `sha256sum`), awk, sed, and normal GNU/Linux utilities. Optional
modules need their corresponding commands: sensors, smartctl/jq, zpool,
systemctl/timedatectl, rc-service, service, curl, openssl, pgrep, container
clients, piactl, fail2ban-client, or fortune/cowsay/lolcat.

From the complete extracted repo, run:

```bash
bash tests/smoke.sh
```

The suite uses jq, OpenSSL, and `run-parts`. It covers rendering, timeouts,
configuration/cache behavior, service providers, container filtering, selected
installation, immediate edits, single login execution, reinstalling in place,
and migration from the old layout. Hardware and daemon inputs are fixtures;
installation uses temporary directories. Verify actual permissions and
hardware data on each target machine.

Read [FRAMEWORK.md](FRAMEWORK.md) for the configuration flow, shared helpers,
and the division of work between the framework, modules, and renderer.

## Credits

Originally based on [yboetz/motd](https://github.com/yboetz/motd), with formatting
inspired by [bcyran/fancy-motd](https://github.com/bcyran/fancy-motd).
