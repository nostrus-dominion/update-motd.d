#!/bin/bash

## Version 0.4.0
## Choose this machine's modules and monitoring targets.

set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
prefix="" modules_arg="" providers_arg="" services_arg=""
docker_arg="" podman_arg="" lxc_arg="" lxd_arg=""
replace_legacy=false noninteractive=false selection_given=false

usage() {
    cat <<'HELP'
Usage: sudo ./install.sh [options]
       ./install.sh --destdir /absolute/staging/path [options]

Without --non-interactive, ask which providers, modules, and targets to use.
  --modules LIST        Module filenames separated by spaces or commas.
  --providers LIST      systemd, openrc, sysv, docker, podman, lxc, lxd, or none.
                        Choose at most one host service manager.
  --services LIST       Exact service names for the selected host manager.
  --docker-containers LIST   Exact Docker names; empty means all visible.
  --podman-containers LIST   Exact Podman names; empty means all visible.
  --lxc-containers LIST      Classic LXC names; empty means all visible.
  --lxd-instances LIST       LXD names; empty means all visible.
  --non-interactive     Use supplied choices, or preserve an existing configuration.
  --replace-legacy      Back up and retire this repo's old numbered scripts.
  --destdir DIR         Stage the complete installation under DIR.
  -h, --help            Show help.

Examples:
  sudo ./install.sh --replace-legacy
  sudo ./install.sh --non-interactive --providers 'systemd,docker' \
    --modules '10-hostname,11-time-sync,20-system-info,40-services,45-docker' \
    --services 'ssh.service nginx.service' --docker-containers 'plex jellyfin'
HELP
}
error() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
while (( $# )); do
    case $1 in
        --replace-legacy) replace_legacy=true; shift ;;
        --non-interactive) noninteractive=true; shift ;;
        --destdir|--modules|--providers|--services|--docker-containers|--podman-containers|--lxc-containers|--lxd-instances)
            (( $# >= 2 )) || error "$1 requires a value."
            case $1 in
                --destdir) prefix=${2%/}; [[ -n $prefix && $prefix == /* ]] || error 'Invalid staging path.' ;;
                --modules) modules_arg=$2; selection_given=true ;;
                --providers) providers_arg=$2; selection_given=true ;;
                --services) services_arg=$2; selection_given=true ;;
                --docker-containers) docker_arg=$2; selection_given=true ;;
                --podman-containers) podman_arg=$2; selection_given=true ;;
                --lxc-containers) lxc_arg=$2; selection_given=true ;;
                --lxd-instances) lxd_arg=$2; selection_given=true ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1" ;;
    esac
done
[[ -n $prefix || $EUID == 0 ]] || error 'Use sudo for system installation.'
umask 022
motd_dir="$prefix/etc/update-motd.d"
config_dir="$motd_dir/config"
config_file="$config_dir/motd.conf"
# The old expanded versions kept their machine config outside this tree.
old_config="$prefix/etc/nostrus-motd/motd.conf"
source "$repo_dir/lib/framework.sh"
existing=""
if [[ -f $config_file ]]; then
    existing=$(cat "$config_file")
elif [[ -f $old_config ]]; then
    existing=$(cat "$old_config")
    existing=${existing//82-time-sync/11-time-sync}
    if [[ $existing != *MOTD_SERVICE_PROVIDER=* && $existing == *40-services* ]]; then
        existing+=$'\nMOTD_SERVICE_PROVIDER=systemd'
    fi
fi
available=()
for file in "$repo_dir"/modules/[0-9][0-9]-*; do
    [[ -f $file ]] || continue
    bash -n "$file"
    available+=("${file##*/}")
done
bash -n "$repo_dir/bin/motd"
bash -n "$repo_dir/lib/framework.sh"
legacy_names=("${available[@]}" 82-time-sync)
legacy_present=()
for name in "${legacy_names[@]}"; do
    [[ ! -e $motd_dir/$name && ! -L $motd_dir/$name ]] || legacy_present+=("$name")
done
if (( ${#legacy_present[@]} )) && [[ $replace_legacy != true ]]; then
    error 'Original modules exist; use --replace-legacy to back them up and prevent duplicate output.'
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
# Read trusted machine configuration in a separate process, including array additions.
load_modules() {
    local result
    result=$(MOTD_CONFIG_FILE="$work/config" MOTD_CONFIG_EXPLICIT=true
        motd_load_config || exit 2
        printf '%s\n' "${MOTD_MODULES[@]}") || error 'Invalid machine configuration.'
    modules=()
    [[ -z $result ]] || mapfile -t modules <<< "$result"
}
if [[ $noninteractive == true && $selection_given == false && -n $existing ]]; then
    printf '%s\n' "$existing" > "$work/config"
    bash -n "$work/config"
    load_modules
else
    if [[ $noninteractive != true ]]; then
        [[ -t 0 ]] || error 'Interactive installation needs a terminal; use --non-interactive with choices.'
        printf 'Providers: systemd openrc sysv docker podman lxc lxd none\n'
        if [[ -z $providers_arg ]]; then
            detected=none
            [[ ! -d /run/systemd/system ]] || detected=systemd
            read -r -p "Providers [$detected]: " providers_arg
            providers_arg=${providers_arg:-$detected}
        fi
    fi
    read -r -a providers <<< "${providers_arg//,/ }"
    [[ ${#providers[@]} != 0 ]] || providers=(none)
    service_provider=none
    provider_modules=()
    for provider in "${providers[@]}"; do
        case $provider in
            systemd|openrc|sysv)
                [[ $service_provider == none ]] || error 'Choose only one host service manager.'
                service_provider=$provider; provider_modules+=(40-services)
                [[ $provider != systemd ]] || provider_modules+=(41-failed-units) ;;
            docker) provider_modules+=(45-docker) ;;
            podman) provider_modules+=(47-podman) ;;
            lxc) provider_modules+=(46-lxc) ;;
            lxd) provider_modules+=(48-lxd) ;;
            none) (( ${#providers[@]} == 1 )) || error 'none cannot be combined with other providers.' ;;
            *) error "Unknown provider: $provider" ;;
        esac
    done
    defaults=(10-hostname 11-time-sync 20-system-info 21-cpu-load 22-memory
        26-network 32-disk-space "${provider_modules[@]}" 80-update 81-reboot-required 91-other-users)
    if [[ $noninteractive != true && -z $modules_arg ]]; then
        printf '\nAvailable modules:\n'
        for i in "${!available[@]}"; do
            description=$(sed -n 's/^# Description: //p' "$repo_dir/modules/${available[$i]}")
            printf '%2s) %-22s %s\n' "$((i+1))" "${available[$i]}" "$description"
        done
        printf '\nDefault: %s\n' "${defaults[*]}"
        read -r -p 'Modules (numbers or filenames; Enter = default; all = all): ' modules_arg
    fi
    if [[ $modules_arg == all ]]; then
        modules=("${available[@]}")
    elif [[ -z $modules_arg ]]; then
        modules=("${defaults[@]}")
    else
        read -r -a choices <<< "${modules_arg//,/ }"
        modules=()
        for choice in "${choices[@]}"; do
            if [[ $choice =~ ^[1-9][0-9]?$ ]]; then
                (( choice <= ${#available[@]} )) || error "Invalid module number: $choice"
                choice=${available[$((choice-1))]}
            fi
            modules+=("$choice")
        done
    fi
    if [[ $noninteractive != true ]]; then
        if motd_contains 40-services "${modules[@]}" && [[ $service_provider != none ]]; then
            read -r -p "Exact $service_provider service names [$services_arg]: " answer
            services_arg=${answer:-$services_arg}
        fi
        for provider in docker podman lxc lxd; do
            case $provider in
                docker) mod=45-docker; variable=docker_arg ;;
                podman) mod=47-podman; variable=podman_arg ;;
                lxc) mod=46-lxc; variable=lxc_arg ;;
                lxd) mod=48-lxd; variable=lxd_arg ;;
            esac
            if motd_contains "$mod" "${modules[@]}"; then
                read -r -p "$provider names [${!variable:-all visible}]: " answer
                [[ -z $answer ]] || printf -v "$variable" '%s' "$answer"
            fi
        done
    fi
    # Validate target names before writing any persistent files.
    for list in "$services_arg" "$docker_arg" "$podman_arg" "$lxc_arg" "$lxd_arg"; do
        read -r -a names <<< "${list//,/ }"
        for name in "${names[@]}"; do
            [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:@/-]*$ ]] || error "Invalid target name: $name"
        done
    done
    modules_text=$(printf '%s\n' "${modules[@]}" | LC_ALL=C sort -u | paste -sd ' ')
    read -r -a modules <<< "$modules_text"
    {
        printf '# BEGIN MOTD INSTALLER CHOICES\nMOTD_MODULES=(%s)\n' "$modules_text"
        printf 'MOTD_SERVICE_PROVIDER=%q\ndeclare -gA MOTD_SERVICES=(' "$service_provider"
        read -r -a names <<< "${services_arg//,/ }"
        for name in "${names[@]}"; do printf '[%q]=%q ' "$name" "$name"; done
        printf ')\n'
        for provider in docker podman lxc lxd; do
            case $provider in
                docker) list=$docker_arg; array=MOTD_DOCKER_CONTAINERS ;;
                podman) list=$podman_arg; array=MOTD_PODMAN_CONTAINERS ;;
                lxc) list=$lxc_arg; array=MOTD_LXC_CONTAINERS ;;
                lxd) list=$lxd_arg; array=MOTD_LXD_INSTANCES ;;
            esac
            read -r -a names <<< "${list//,/ }"
            printf 'declare -ga %s=(' "$array"
            if (( ${#names[@]} )); then printf '%q ' "${names[@]}"; fi
            printf ')\n'
        done
        printf '# END MOTD INSTALLER CHOICES\n'
        # Preserve manually configured settings; replace only selection variables.
        if [[ -n $existing ]]; then
            printf '%s\n' "$existing" | awk '
                /^# (BEGIN|END) (MOTD INSTALLER CHOICES|NOSTRUS MOTD)$/ {next}
                /^[[:space:]]*(declare -g[aA] )?MOTD_(MODULES|SERVICE_PROVIDER|SERVICES|DOCKER_CONTAINERS|PODMAN_CONTAINERS|LXC_CONTAINERS|LXD_INSTANCES)=/ {
                    if ($0 ~ /=\(/ && $0 !~ /\)/) skip=1
                    next
                }
                skip {if ($0 ~ /\)/) skip=0; next}
                {print}'
        else
            printf '\n# Machine settings: storage, role, endpoints, thresholds, colors.\nMOTD_ROLE=""\n'
        fi
    } > "$work/config"
fi
(( ${#modules[@]} )) || error 'Choose at least one module.'
for module in "${modules[@]}"; do
    motd_contains "$module" "${available[@]}" || error "Unknown module: $module"
done
bash -n "$work/config"
load_modules
# Validate the effective module list after manual overrides before installing anything.
for module in "${modules[@]}"; do
    motd_contains "$module" "${available[@]}" || error "Unknown module: $module"
done
mkdir -p "$work/tree/modules" "$work/tree/lib" "$work/tree/bin" "$work/tree/config"
for name in install.sh 10-main README.md FRAMEWORK.md; do
    cp "$repo_dir/$name" "$work/tree/$name"
done
cp "$repo_dir/config/motd.conf" "$work/tree/config/motd.conf.example"
if [[ -f $config_dir/colors.conf ]]; then
    cp "$config_dir/colors.conf" "$work/tree/config/colors.conf"
elif [[ -f $prefix/etc/nostrus-motd/colors.conf ]]; then
    cp "$prefix/etc/nostrus-motd/colors.conf" "$work/tree/config/colors.conf"
else
    cp "$repo_dir/config/colors.conf" "$work/tree/config/colors.conf"
fi
install -m 0644 "$repo_dir/lib/framework.sh" "$work/tree/lib/framework.sh"
install -m 0755 "$repo_dir/bin/motd" "$work/tree/bin/motd"
for module in "${modules[@]}"; do
    install -m 0755 "$repo_dir/modules/$module" "$work/tree/modules/$module"
done

mkdir -p "$motd_dir/backups" "$config_dir"
chmod 0700 "$motd_dir/backups"
backup=$(mktemp -d "$motd_dir/backups/$(date '+%Y%m%d-%H%M%S').XXXXXXXX")
# Retire the previous login-entry name so upgrades cannot print twice.
if [[ -f $motd_dir/10-nostrus ]] && [[ $(< "$motd_dir/10-nostrus") == *bin/motd* ]]; then
    mv "$motd_dir/10-nostrus" "$backup/10-nostrus"
fi
for name in modules lib bin; do
    [[ ! -e $motd_dir/$name && ! -L $motd_dir/$name ]] || mv "$motd_dir/$name" "$backup/$name"
    cp -a "$work/tree/$name" "$motd_dir/$name"
done
for name in config install.sh 10-main README.md FRAMEWORK.md; do
    [[ ! -e $motd_dir/$name && ! -L $motd_dir/$name ]] || cp -a "$motd_dir/$name" "$backup/$name"
done
install -m 0644 "$work/config" "$config_file"
install -m 0644 "$work/tree/config/colors.conf" "$config_dir/colors.conf"
install -m 0644 "$work/tree/config/motd.conf.example" "$config_dir/motd.conf.example"
for name in install.sh 10-main; do
    install -m 0755 "$work/tree/$name" "$motd_dir/$name"
done
for name in README.md FRAMEWORK.md; do
    install -m 0644 "$work/tree/$name" "$motd_dir/$name"
done
mkdir -p "$motd_dir/cache"
chmod 0700 "$motd_dir/cache"
if [[ -z $prefix ]]; then
    chown -R root:root "$motd_dir/modules" "$motd_dir/lib" "$motd_dir/bin" \
        "$config_dir" "$motd_dir/cache" "$motd_dir/backups"
    chown root:root "$motd_dir/install.sh" "$motd_dir/10-main" \
        "$motd_dir/README.md" "$motd_dir/FRAMEWORK.md"
fi
if (( ${#legacy_present[@]} )); then
    mkdir "$backup/legacy"
    for name in "${legacy_present[@]}"; do mv "$motd_dir/$name" "$backup/legacy/$name"; done
fi
# Retire only recognized files from our previous split-layout installations.
old_lib="$prefix/usr/local/lib/nostrus-motd"
old_bin="$prefix/usr/local/bin/motd"
old_settings="$prefix/etc/nostrus-motd"
if [[ -f $old_lib/framework.sh ]] && \
    [[ $(< "$old_lib/framework.sh") == *'Nostrus MOTD requires Bash'* ]]; then
    mkdir "$backup/previous-layout"
    mv "$old_lib" "$backup/previous-layout/library"
    if [[ -f $old_bin ]] && [[ $(< "$old_bin") == *'Nostrus Dominion MOTD'* ]]; then
        mv "$old_bin" "$backup/previous-layout/motd"
    fi
    [[ ! -d $old_settings ]] || mv "$old_settings" "$backup/previous-layout/config"
fi
printf 'Installed %s selected modules in %s.\nConfiguration: %s\nBackup: %s\n' \
    "${#modules[@]}" "$motd_dir" "$config_file" "$backup"
printf 'Preview: %s/bin/motd --list\n' "$motd_dir"
