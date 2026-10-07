# How framework.sh works

`lib/framework.sh` is a shared Bash library. Each numbered module sources it
with `source`, so its functions and variables become available in that module's
shell. It does not run the complete MOTD by itself.

There are three separate jobs:

| File | Job |
| --- | --- |
| `install.sh` | Ask what this machine needs, write the settings, and install the selected scripts |
| `bin/motd` | Choose and run modules, reuse cached output, and enforce module timeouts |
| `lib/framework.sh` | Load settings, check dependencies, format output, and provide common monitoring helpers |

## 1. Locate the configuration

The file checks for Bash 4.4 or newer, then uses `BASH_SOURCE[0]` to find its own
location. The parent of `lib/` is the MOTD root. Configuration always lives in
that root's `config/` subdirectory, so repository previews, installed scripts,
and staged installations all resolve their own configuration correctly.

In production that root is `/etc/update-motd.d/`. The framework does not read
home shell files or look up a separate profile directory.

## 2. Build the settings

`motd_defaults` supplies normal values: enabled modules, colors, thresholds,
paths, display widths, timeouts, and cache durations. Lists use indexed arrays;
named mappings use associative arrays.

```bash
MOTD_MODULES=(10-hostname 11-time-sync 32-disk-space)
declare -gA MOTD_SERVICES=([nginx.service]="Nginx")
```

`MOTD_SERVICES[nginx.service]` returns the label `Nginx`. The `-g` declarations
make these arrays global even when settings are loaded inside a function.

`motd_load_config` applies these layers:

1. Built-in defaults.
2. `/etc/update-motd.d/config/motd.conf`, or an explicit `--config FILE`.
3. The chosen palette, normally `/etc/update-motd.d/config/colors.conf`.
4. CLI color and cache overrides.

There is one machine configuration for both root and ordinary user previews.
It is trusted Bash, so keep it root-owned and limit it to settings. Edits take
effect on the next render without a sync step. `MOTD_MODULES` chooses the
scripts; `MOTD_SERVICE_PROVIDER` selects the host service manager; separate
container arrays choose Docker, Podman, classic LXC, and LXD targets.

`motd_validate` rejects invalid widths, nonnumeric durations, inconsistent
thresholds, invalid boolean values, and unsupported host service providers.
Finally, `printf -v` converts color escapes into actual ANSI sequences and
assigns the short variables used by modules:

| Variable | Meaning |
| --- | --- |
| `CA` | Accent color for labels |
| `CO` | Healthy / OK color |
| `CW` | Warning color |
| `CE` | Error color |
| `CD` | Dim color |
| `CN` | Reset color |

With `--plain`, all six become empty strings.

## 3. Decide whether a module should run

Every module starts with this pattern:

```bash
source "${MOTD_FRAMEWORK:-$(dirname -- "${BASH_SOURCE[0]}")/../lib/framework.sh}"
motd_init "${0##*/}" || {
    status=$?
    (( status == 1 )) && exit 0
    exit "$status"
}
```

The renderer exports `MOTD_FRAMEWORK` so installed scripts find the shared
library. The fallback path supports running a module from the repository.
`${0##*/}` removes the directory from the script path, leaving its module name.

`motd_init` loads settings and checks that name against `MOTD_MODULES`:

- Success: run the module.
- Return `1`: module disabled; quietly exit successfully.
- Return `2`: configuration failed; report a failing module.

`motd --module NAME` and `motd --all` set `MOTD_FORCE_MODULE=true`, which bypasses
the enabled check for previews. They can preview only files that are available;
an uninstalled module must be added through the installer first.

Each module is a separate process and loads its settings again. Bash arrays
are not exported like ordinary environment variables, which is why the module
must load the configuration itself.

## 4. Gather information with bounded commands

| Helper | What it does |
| --- | --- |
| `motd_need COMMAND ...` | Check whether required programs exist; print missing dependencies with `--debug` |
| `motd_run COMMAND ...` | Run a command through GNU `timeout`, using `MOTD_COMMAND_TIMEOUT` |
| `motd_systemd` | Check whether systemd is operating, rather than assuming an installed `systemctl` means it is usable |
| `motd_containers docker` | Collect Docker state/health, apply selected names and exclusions, and format output |
| `motd_containers podman` | Do the same for Podman |
| `motd_excluded NAME` | Match a container name against configured exclusion globs |
| `motd_contains NAME ...` | Check an exact value against a list |

Service-manager selection lives in `40-services`. Classic LXC uses `lxc-ls`
and `lxc-info` in `46-lxc`; LXD uses its `lxc` client in `48-lxd`.
These scripts inspect state; they do not start, stop, or repair services.

Missing optional commands usually skip their module. An inaccessible Docker or
LXD daemon is shown as unavailable. An explicitly selected Docker, Podman, or
LXD target absent from a successful listing is reported as missing. Classic
LXC reports unknown when `lxc-info` cannot read a selected instance.

## 5. Format the results consistently

| Helper | Example / purpose |
| --- | --- |
| `append_line text "message"` | Add an actual newline and a message to `text` |
| `print_columns "Services" "$text"` | Pad the left label; align subsequent lines beneath the first result |
| `print_status "Nginx" "active"` | Print the label and color a known healthy, failed, or other state |
| `print_color "88°C" 88 70 85` | Use green below 70, yellow below 85, red from 85 upward |
| `print_bar 75` | Draw a fixed-width utilization bar with configured warning/critical colors |
| `human_bytes 1073741824` | Convert a byte count into a readable IEC size such as `1.0GiB` |

`append_line` uses a Bash nameref (`local -n`) to modify the variable whose name
you pass. It adds `$'\n'`, which is an actual newline, rather than literal
backslash-and-n characters.

`print_columns` uses `printf` field widths. This is why all modules can align
without piping everything through `column`. `print_status` recognizes common
state words; unrecognized states use the warning color.

## 6. Where caching and ordering happen

Caching belongs to `bin/motd`, not `framework.sh`. The renderer obtains the
module list, then processes it in array order. The installer writes that list
in numeric filename order, so `11-time-sync` follows `10-hostname`.

For each module, the renderer:

1. Builds a hash from the framework, module, configuration, palette, and display mode.
2. Reuses a matching cache file while its configured lifetime remains valid.
3. Otherwise runs the script with a module timeout, separately capturing stdout
   and stderr.
4. Prints successful output and caches nonempty results. A failing or timed-out
   module is shown as unavailable and processing continues with the next one.

`MOTD_COMMAND_TIMEOUT` bounds each helper command. `MOTD_MODULE_TIMEOUT` bounds
the whole module; `MOTD_TIMEOUTS[module-name]` overrides it for a particular
script. Module caching is enabled only when its `MOTD_CACHE_TTL[module-name]`
is greater than zero.

The default cache is `/etc/update-motd.d/cache/`, within the same installation.
The installer makes it root-owned with mode `0700`. The renderer uses a cache
only when the current user owns and can write the configured directory;
ordinary user previews still run, with caching disabled. Temporary rendering
files are created under the normal system temporary directory and removed when
the command exits.

`--no-cache` forces fresh checks; `--debug` exposes captured stderr and nonzero
exit codes. Backup files created by the installer live in
`/etc/update-motd.d/backups/` and do not participate in rendering.

## 7. Why there is one top-level login entry

The system runner executes `/etc/update-motd.d/10-main`. That script locates
its own directory and executes the adjacent `bin/motd` renderer. The renderer
loads the framework, reads configuration, and invokes scripts from `modules/`.

`run-parts` scans the top directory without descending into `modules/`, `bin/`,
`lib/`, `config/`, `cache/`, or `backups/`. This prevents duplicate module output
while keeping the complete installation under one directory. The numbered
module filenames still define the installer's default order; the configuration
array defines the renderer's actual order.
