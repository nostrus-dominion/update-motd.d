#!/bin/bash

# Regression checks use temporary configurations and fixture commands.
# Nothing is installed into the real /etc, and no application is contacted.

set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
case_dir=$(mktemp -d)
trap 'rm -rf -- "$case_dir"' EXIT
mkdir -p -- "$case_dir/commands" "$case_dir/proc" "$case_dir/sys"
checks=0

pass() { checks=$((checks + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() { [[ $1 == *"$2"* ]] || fail "Expected output containing: $2"; }
not_contains() { [[ $1 != *"$2"* ]] || fail "Unexpected output containing: $2"; }
run_motd() { "$repo_dir/bin/motd" --config "$case_dir/motd.conf" --plain "$@"; }
reset_config() {
    cat > "$case_dir/motd.conf" <<'EOF'
MOTD_MODULES=()
MOTD_CACHE_TTL=()
MOTD_BANNER=false
MOTD_COLORS_FILE=""
EOF
    printf 'MOTD_CACHE_DIR=%q\nMOTD_PROC_ROOT=%q\nMOTD_SYS_ROOT=%q\n' \
        "$case_dir/cache" "$case_dir/proc" "$case_dir/sys" >> "$case_dir/motd.conf"
}

for command in bash awk timeout sha256sum jq openssl; do
    command -v "$command" >/dev/null || fail "Test dependency missing: $command"
done
for file in "$repo_dir"/modules/[0-9][0-9]-* "$repo_dir/bin/motd" "$repo_dir/install.sh" \
    "$repo_dir/lib/framework.sh" "$repo_dir"/config/*.conf \
    "$repo_dir/10-main" "${BASH_SOURCE[0]}"; do
    bash -n "$file"
done
pass "Bash syntax for every module, command, and configuration"

cat > "$case_dir/commands/apt" <<'EOF'
#!/bin/bash
printf 'call\n' >> "$MOTD_TEST_APT_CALLS"
printf 'Listing...\nfirst/stable 1.0 amd64 [upgradable from: 0.9]\nsecond/stable 2.0 amd64 [upgradable from: 1.9]\n'
EOF
cat > "$case_dir/commands/lxc" <<'EOF'
#!/bin/bash
printf 'alpha,RUNNING\nbeta,STOPPED\n'
EOF
cat > "$case_dir/commands/docker" <<'EOF'
#!/bin/bash
[[ ${MOTD_TEST_DOCKER_FAIL:-false} != true ]] || exit 1
printf 'web\trunning\tUp 5 minutes (healthy)\nsick\trunning\tUp 1 minute (unhealthy)\nold\texited\tExited (0)\n'
EOF
cat > "$case_dir/commands/smartctl" <<'EOF'
#!/bin/bash
case ${@: -1} in
    */failed) printf '{"smart_status":{"passed":false},"temperature":{"current":40}}\n'; exit 8 ;;
    */nvme) printf '{"smart_status":{"passed":true},"nvme_smart_health_information_log":{"temperature":68}}\n' ;;
    *) printf '{"smart_status":{}}\n'; exit 2 ;;
esac
EOF
cat > "$case_dir/commands/sensors" <<'EOF'
#!/bin/bash
[[ ${MOTD_TEST_SLOW_SENSOR:-false} != true ]] || sleep 2
printf 'fixture-pci-0000\nAdapter: PCI adapter\nTctl: +88.0°C\n'
EOF
cat > "$case_dir/commands/curl" <<'EOF'
#!/bin/bash
case ${@: -1} in
    *good) printf 200 ;;
    *bad) printf 503 ;;
    *) printf 000; exit 28 ;;
esac
EOF
cat > "$case_dir/commands/vcgencmd" <<'EOF'
#!/bin/bash
if [[ $1 == measure_temp ]]; then printf "temp=55.0'C\n"
else printf 'throttled=0x10000\n'
fi
EOF
chmod +x "$case_dir/commands"/*
export PATH="$case_dir/commands:$PATH"
export MOTD_TEST_APT_CALLS="$case_dir/apt-calls"

reset_config
output=$(run_motd --list)
contains "$output" "24-gpu"
contains "$output" "11-time-sync"
[[ $(awk 'END { print NR }' <<< "$output") == 36 ]] || fail "Expected 36 available modules."
[[ -z $(run_motd --no-cache) ]] || fail "An empty module selection must produce no output."
pass "Registry lists all 36 modules and respects disabled modules"

printf 'MOTD_BAR_WIDTH=0\n' >> "$case_dir/motd.conf"
if run_motd --list > /dev/null 2>&1; then fail "Invalid width was accepted."; fi
reset_config
printf 'MOTD_MODULES=(99-not-a-module)\n' >> "$case_dir/motd.conf"
if run_motd > /dev/null 2>&1; then fail "Unknown module was accepted."; fi
if "$repo_dir/bin/motd" --config "$case_dir/missing" > /dev/null 2>&1; then
    fail "An unreadable explicit configuration was accepted."
fi
pass "Invalid settings, unknown modules, and missing configs are rejected"

reset_config
printf 'MOTD_MODULES=(80-update)\nMOTD_CACHE_TTL=([80-update]=300)\n' >> "$case_dir/motd.conf"
output=$(run_motd)
contains "$output" "2 available"
run_motd >/dev/null
[[ $(wc -l < "$MOTD_TEST_APT_CALLS") == 1 ]] || fail "Cache did not prevent a second package query."
printf 'MOTD_UPDATE_WARN=5\n' >> "$case_dir/motd.conf"
run_motd >/dev/null
[[ $(wc -l < "$MOTD_TEST_APT_CALLS") == 2 ]] || fail "Configuration changes did not invalidate the cache."
pass "Cached results are reused and invalidated by configuration changes"

reset_config
output=$(run_motd --module 48-lxd --no-cache)
contains "$output" "alpha: running"
contains "$output" "beta: stopped"
pass "Disabled module previews work and LXD CSV states parse correctly"

output=$(run_motd --module 45-docker --no-cache)
contains "$output" "web: running"
contains "$output" "sick: unhealthy"
not_contains "$output" $'\033'
output=$(MOTD_TEST_DOCKER_FAIL=true run_motd --module 45-docker --no-cache)
contains "$output" "Daemon unavailable"
not_contains "$output" "No matching containers"
pass "Unhealthy containers and unavailable daemons are reported correctly"

output=$(run_motd --module 23-temperatures --no-cache)
contains "$output" "Tctl: 88.0°C"
not_contains "$output" $'\033'
mkdir -p "$case_dir/sys/class/drm/card0/device"
printf '88\n' > "$case_dir/sys/class/drm/card0/device/gpu_busy_percent"
printf '1073741824\n' > "$case_dir/sys/class/drm/card0/device/mem_info_vram_used"
printf '17179869184\n' > "$case_dir/sys/class/drm/card0/device/mem_info_vram_total"
output=$(run_motd --module 24-gpu --no-cache)
contains "$output" "card0: 88% GPU load"
contains "$output" "VRAM: 1.0GiB / 16GiB"
pass "Temperature parsing, AMD GPU metrics, and plain output"

printf 'MOTD_SMART_DEVICES=(/dev/failed /dev/nvme /dev/unsupported)\n' >> "$case_dir/motd.conf"
output=$(run_motd --module 30-disk-health --no-cache)
contains "$output" "failed: failed"
contains "$output" "nvme: passed (68°C)"
contains "$output" "unsupported: unavailable (temperature unavailable)"
not_contains "$output" "00°C"
pass "SMART bitmask failures, NVMe temperatures, and unsupported devices"

cat > "$case_dir/proc/mdstat" <<'EOF'
Personalities : [raid1]
md0 : active raid1 a[0] b[1]
      100 blocks [2/2] [UU]
md1 : active raid1 c[0] d[1]
      100 blocks [2/1] [U_]
      [=>...................] recovery = 10.0% finish=1min
md2 : inactive raid1 e[0]
      100 blocks
md3 : active raid0 f[0]
      100 blocks
md4 : active (auto-read-only) raid1 g[0] h[1]
      100 blocks [2/2] [UU]
unused devices: <none>
EOF
output=$(run_motd --module 33-raid --no-cache)
contains "$output" "md0 (raid1): healthy"
contains "$output" "md1 (raid1): degraded"
contains "$output" "recovery = 10.0%"
contains "$output" "md2 (raid1): inactive"
contains "$output" "md3 (raid0): unknown"
contains "$output" "md4 (raid1): healthy"
pass "Multiple RAID arrays retain degradation, inactivity, and synchronization"

printf 'MOTD_REQUIRED_MOUNTS=(%q)\n' "$case_dir/unmounted-storage" >> "$case_dir/motd.conf"
output=$(run_motd --module 31-mounts --no-cache)
contains "$output" "unmounted-storage: missing"
pass "Missing required storage mounts are visible"

printf 'MOTD_ENDPOINTS=([good]=http://test/good [bad]=http://test/bad [offline]=http://test/offline)\n' >> "$case_dir/motd.conf"
output=$(run_motd --module 43-http-checks --no-cache)
contains "$output" "good: healthy (HTTP 200)"
contains "$output" "bad: failed (HTTP 503)"
contains "$output" "offline: unavailable (HTTP 000)"
pass "HTTP errors and unreachable applications differ from healthy endpoints"

output=$(run_motd --module 28-raspberry-pi --no-cache)
contains "$output" "Historical throttling"
not_contains "$output" "Current throttling"
pass "Historical Raspberry Pi throttling is distinguished from current flags"

mkdir -p "$case_dir/certs/example.test"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj /CN=example.test -keyout "$case_dir/key.pem" \
    -out "$case_dir/certs/example.test/fullchain.pem" >/dev/null 2>&1
printf 'MOTD_CERT_DIR=%q\nMOTD_CERT_DOMAINS=(example.test missing.test)\n' \
    "$case_dir/certs" >> "$case_dir/motd.conf"
output=$(run_motd --module 50-ssl-cert --no-cache)
contains "$output" "example.test:"
contains "$output" "missing.test: certificate unavailable"
pass "Certificates are read and missing configured certificates stay visible"

printf 'MOTD_MODULE_TIMEOUT=1\n' >> "$case_dir/motd.conf"
output=$(MOTD_TEST_SLOW_SENSOR=true run_motd --module 23-temperatures --no-cache)
contains "$output" "Unavailable (exit 124)"
pass "A slow module is bounded by its timeout"

stage="$case_dir/install root"
mkdir -p "$stage/etc/update-motd.d"
printf 'legacy\n' > "$stage/etc/update-motd.d/40-services"
printf 'unrelated\n' > "$stage/etc/update-motd.d/00-distribution"
cp "$repo_dir/10-main" "$stage/etc/update-motd.d/10-nostrus"
if "$repo_dir/install.sh" --destdir "$stage" --non-interactive >/dev/null 2>&1; then
    fail "A legacy installation was silently duplicated."
fi
[[ ! -e $stage/etc/update-motd.d/bin/motd ]] || fail "Refused installation wrote managed files."
"$repo_dir/install.sh" --destdir "$stage" --non-interactive --replace-legacy --modules all --providers systemd >/dev/null
[[ ! -e $stage/etc/update-motd.d/40-services ]] || fail "Legacy module remains active."
[[ ! -e $stage/etc/update-motd.d/10-nostrus ]] || fail "Previous login entry remains active."
[[ $(< "$stage/etc/update-motd.d/00-distribution") == unrelated ]] || fail "Unrelated script was changed."
output=$("$stage/etc/update-motd.d/bin/motd" --list)
contains "$output" "47-podman"
[[ -x $stage/etc/update-motd.d/modules/40-services ]] || fail "Module lost executable permissions."
pass "Staged installation retires legacy files and preserves distribution scripts"

cat > "$stage/etc/update-motd.d/config/motd.conf" <<'EOF'
# BEGIN MOTD INSTALLER CHOICES
MOTD_MODULES=(98-notes)
MOTD_SERVICE_PROVIDER=none
# END MOTD INSTALLER CHOICES
MOTD_NOTES="Keep this machine setting"
EOF
"$repo_dir/install.sh" --destdir "$stage" --non-interactive >/dev/null
output=$("$stage/etc/update-motd.d/bin/motd" --plain --no-cache)
contains "$output" "Keep this machine setting"
[[ $(find "$stage/etc/update-motd.d/modules" -type f | wc -l) == 1 ]] || fail "Unselected modules installed."
[[ ! -e $stage/usr && ! -e $stage/home && ! -e $stage/etc/nostrus-motd ]] || fail "Installer wrote outside the requested tree."
pass "Reinstallation preserves machine settings and installs only selected modules in one tree"

sed -i 's/Keep this machine setting/Changed live setting/' "$stage/etc/update-motd.d/config/motd.conf"
output=$("$stage/etc/update-motd.d/bin/motd" --plain --no-cache)
contains "$output" "Changed live setting"
output=$("$stage/etc/update-motd.d/10-main" --plain --no-cache)
contains "$output" "Changed live setting"
pass "Direct config edits apply immediately through the renderer and login entry"

"$repo_dir/install.sh" --destdir "$stage" --non-interactive \
    --modules '45-docker 40-services 11-time-sync' --providers systemd,docker \
    --services 'ssh.service nginx.service' --docker-containers 'web missing' >/dev/null
output=$("$stage/etc/update-motd.d/bin/motd" --plain --no-cache)
contains "$output" "web: running"
contains "$output" "missing: missing"
not_contains "$output" "sick: unhealthy"
output=$("$stage/etc/update-motd.d/bin/motd" --list)
[[ $(head -n 1 <<< "$output") == 11-time-sync* ]] || fail "Installer did not sort priorities."
contains "$(< "$stage/etc/update-motd.d/config/motd.conf")" "Changed live setting"
pass "Provider selections retain manual settings and numeric priority"

# The system runner must see just one framework entry and no nested modules.
chmod +x "$stage/etc/update-motd.d/00-distribution"
output=$(run-parts --test "$stage/etc/update-motd.d")
contains "$output" '10-main'
not_contains "$output" '11-time-sync'
not_contains "$output" 'install.sh'
not_contains "$output" 'bin/motd'
[[ $(wc -l <<< "$output") == 2 ]] || fail "Unexpected extra login entries."
pass "run-parts runs one framework entry alongside unrelated distribution scripts"

# The installed installer can refresh its currently available subset in place.
"$stage/etc/update-motd.d/install.sh" --destdir "$stage" --non-interactive >/dev/null
output=$("$stage/etc/update-motd.d/bin/motd" --list)
contains "$output" '45-docker'
[[ -d $stage/etc/update-motd.d/backups && -d $stage/etc/update-motd.d/cache ]] || fail "State directories missing."
pass "Installer can run from the installed tree and keeps backups/cache there"

# Migrate a recognized split-layout installation without touching home files.
migration="$case_dir/migration"
mkdir -p "$migration/usr/local/bin" "$migration/usr/local/lib/nostrus-motd" "$migration/etc/nostrus-motd" "$migration/home/test"
cp "$repo_dir/lib/framework.sh" "$migration/usr/local/lib/nostrus-motd/framework.sh"
cp "$repo_dir/bin/motd" "$migration/usr/local/bin/motd"
cat > "$migration/etc/nostrus-motd/motd.conf" <<'EOF'
MOTD_MODULES=(98-notes)
MOTD_NOTES="Migrated settings"
EOF
printf "MOTD_ACCENT='\\033[0;35m'\n" > "$migration/etc/nostrus-motd/colors.conf"
printf '# old shell settings\n' > "$migration/home/test/.bash_local"
"$repo_dir/install.sh" --destdir "$migration" --non-interactive >/dev/null
output=$("$migration/etc/update-motd.d/bin/motd" --plain --no-cache)
contains "$output" 'Migrated settings'
[[ ! -e $migration/usr/local/bin/motd && ! -e $migration/usr/local/lib/nostrus-motd && ! -e $migration/etc/nostrus-motd ]] || fail "Old managed paths remain active."
[[ $(< "$migration/home/test/.bash_local") == '# old shell settings' ]] || fail "Home configuration was touched."
contains "$(< "$migration/etc/update-motd.d/config/colors.conf")" '35m'
pass "Migration brings previous machine settings and colors into the tree and retires recognized old files"

# Fixtures for host service managers and classic LXC.
cat > "$case_dir/commands/systemctl" <<'EOF'
#!/bin/bash
case $1 in
    is-system-running) printf 'running\n' ;;
    is-active) case $2 in ssh.service) printf 'active\n';; *) printf 'inactive\n'; exit 3;; esac ;;
esac
EOF
cat > "$case_dir/commands/rc-service" <<'EOF'
#!/bin/bash
[[ $1 == ssh ]]
EOF
cp "$case_dir/commands/rc-service" "$case_dir/commands/service"
cat > "$case_dir/commands/lxc-ls" <<'EOF'
#!/bin/bash
printf 'alpha\nbeta\n'
EOF
cat > "$case_dir/commands/lxc-info" <<'EOF'
#!/bin/bash
case $2 in alpha) printf 'RUNNING\n';; beta) printf 'STOPPED\n';; *) exit 1;; esac
EOF
chmod +x "$case_dir/commands"/*
reset_config
printf 'MOTD_SERVICE_PROVIDER=systemd\nMOTD_SERVICES=([ssh.service]=SSH [nginx.service]=Nginx)\n' >> "$case_dir/motd.conf"
output=$(run_motd --module 40-services --no-cache)
contains "$output" "SSH: active"
contains "$output" "Nginx: inactive"
for provider in openrc sysv; do
    reset_config
    printf 'MOTD_SERVICE_PROVIDER=%s\nMOTD_SERVICES=([ssh]=SSH [bad]=Bad)\n' "$provider" >> "$case_dir/motd.conf"
    output=$(run_motd --module 40-services --no-cache)
    contains "$output" "SSH: running"
    contains "$output" "Bad: stopped"
done
output=$(run_motd --module 46-lxc --no-cache)
contains "$output" "alpha: running"
contains "$output" "beta: stopped"
pass "Systemd, OpenRC, SysV, and classic LXC use the correct commands"

reset_config
printf 'MOTD_DOCKER_CONTAINERS=(old)\nMOTD_SHOW_STOPPED_CONTAINERS=true\n' >> "$case_dir/motd.conf"
output=$(run_motd --module 45-docker --no-cache)
contains "$output" "old: exited"
not_contains "$output" "web: running"
printf 'MOTD_LXD_INSTANCES=(beta missing)\n' >> "$case_dir/motd.conf"
output=$(run_motd --module 48-lxd --no-cache)
contains "$output" "beta: stopped"
contains "$output" "missing: missing"
not_contains "$output" "alpha: running"
pass "Stopped Docker targets and selected LXD instances are filtered correctly"

cp "$case_dir/commands/docker" "$case_dir/commands/podman"
reset_config
printf 'MOTD_PODMAN_CONTAINERS=(web missing)\nMOTD_LXC_CONTAINERS=(beta missing)\n' >> "$case_dir/motd.conf"
output=$(run_motd --module 47-podman --no-cache)
contains "$output" "web: running"
contains "$output" "missing: missing"
not_contains "$output" "sick: unhealthy"
output=$(run_motd --module 46-lxc --no-cache)
contains "$output" "beta: stopped"
contains "$output" "missing: unknown"
not_contains "$output" "alpha: running"
pass "Selected Podman and classic LXC targets use independent provider lists"

cat > "$case_dir/commands/timedatectl" <<'EOF'
#!/bin/bash
printf 'Timezone=America/New_York\nNTPSynchronized=yes\n'
EOF
chmod +x "$case_dir/commands/timedatectl"
output=$(run_motd --module 11-time-sync --no-cache)
contains "$output" "Timezone: America/New_York"
contains "$output" "NTP synchronized (yes): healthy"
pass "Renamed 11-time-sync retains synchronization and timezone output"

# A user shell file must never influence the system configuration.
mkdir "$case_dir/home"
printf 'MOTD_NOTES="Unwanted home override"\nexit 1\n' > "$case_dir/home/.bash_local"
output=$(HOME="$case_dir/home" "$stage/etc/update-motd.d/bin/motd" --list)
contains "$output" '45-docker'
not_contains "$output" 'Unwanted home override'
pass "Home shell files are ignored by the unified system configuration"

printf '\n%s regression checks passed.\n' "$checks"
