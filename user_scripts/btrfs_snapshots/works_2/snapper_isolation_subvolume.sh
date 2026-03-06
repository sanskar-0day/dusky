#!/usr/bin/env bash
# Arch Linux (Btrfs root) | Root Snapper isolated @snapshots setup
# Bash 5.3+

set -Eeuo pipefail
export LC_ALL=C
trap 'printf "\n\033[1;31m[FATAL]\033[0m Script failed at line %d. Command: %s\n" "$LINENO" "$BASH_COMMAND" >&2; trap - ERR' ERR

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

declare -A BACKED_UP=()

SUDO_PID=""

fatal() {
    printf '\033[1;31m[FATAL]\033[0m %s\n' "$1" >&2
    exit 1
}

info() {
    printf '\033[1;32m[INFO]\033[0m %s\n' "$1"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$1" >&2
}

cleanup() {
    kill "${SUDO_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

execute() {
    local desc="$1"
    shift

    if [[ "$AUTO_MODE" == true ]]; then
        "$@"
        return 0
    fi

    printf '\n\033[1;34m[ACTION]\033[0m %s\n' "$desc"
    read -r -p "Execute this step? [Y/n] " response || fatal "Input closed; aborting."
    if [[ "${response,,}" =~ ^(n|no)$ ]]; then
        info "Skipped."
        return 0
    fi

    "$@"
}

backup_file() {
    local file="$1"

    [[ -e "$file" ]] || return 0
    [[ -n "${BACKED_UP["$file"]+x}" ]] && return 0

    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"

    sudo cp -a -- "$file" "${file}.bak.${stamp}"
    BACKED_UP["$file"]=1
    info "Backup created: ${file}.bak.${stamp}"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

extract_subvol() {
    local opts="$1"
    local opt value
    local -a parts=()

    IFS=',' read -r -a parts <<< "$opts"
    for opt in "${parts[@]}"; do
        case "$opt" in
            subvol=*)
                value="${opt#subvol=}"
                value="${value#/}"
                printf '%s\n' "$value"
                return 0
                ;;
        esac
    done
    return 1
}

strip_subvol_opts() {
    local opts="$1"
    local opt
    local -a parts=()
    local -a kept=()

    IFS=',' read -r -a parts <<< "$opts"
    for opt in "${parts[@]}"; do
        case "$opt" in
            subvol=*|subvolid=*)
                ;;
            *)
                kept+=("$opt")
                ;;
        esac
    done

    local joined=""
    if ((${#kept[@]} > 0)); then
        joined="${kept[0]}"
        local i
        for ((i = 1; i < ${#kept[@]}; i++)); do
            joined+=",${kept[i]}"
        done
    fi

    printf '%s\n' "$joined"
}

get_root_source() {
    findmnt -no SOURCE / | sed 's/\[.*\]//'
}

get_root_uuid() {
    local source uuid

    uuid="$(findmnt -no UUID / 2>/dev/null || true)"
    if [[ -n "$uuid" ]]; then
        printf '%s\n' "$uuid"
        return 0
    fi

    source="$(get_root_source)"
    [[ -n "$source" ]] || return 1

    blkid -s UUID -o value "$source" 2>/dev/null || true
}

get_root_mount_opts() {
    findmnt -no OPTIONS /
}

dir_has_entries() {
    local dir="$1"
    sudo find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

path_is_btrfs_subvolume() {
    local path="$1"
    sudo btrfs subvolume show "$path" >/dev/null 2>&1
}

verify_snapshots_mount() {
    local root_uuid snap_uuid mounted_opts mounted_subvol

    root_uuid="$(get_root_uuid)"
    [[ -n "$root_uuid" ]] || fatal "Could not determine the Btrfs UUID for /"

    findmnt -M /.snapshots >/dev/null 2>&1 || fatal "/.snapshots is not mounted."

    snap_uuid="$(findmnt -M /.snapshots -no UUID 2>/dev/null || true)"
    [[ -n "$snap_uuid" ]] || fatal "Could not determine the filesystem UUID for /.snapshots"
    [[ "$snap_uuid" == "$root_uuid" ]] || fatal "/.snapshots is mounted from a different filesystem."

    mounted_opts="$(findmnt -M /.snapshots -no OPTIONS 2>/dev/null || true)"
    mounted_subvol="$(extract_subvol "$mounted_opts" || true)"
    mounted_subvol="${mounted_subvol#/}"

    [[ "$mounted_subvol" == "@snapshots" ]] || fatal "/.snapshots is mounted, but not from subvol=/@snapshots"

    sudo chmod 750 /.snapshots
    info "/.snapshots is mounted from @snapshots"
}

install_packages() {
    sudo pacman -S --needed --noconfirm snapper btrfs-progs
}

post_install_checks() {
    require_cmd btrfs
    require_cmd snapper
    require_cmd systemctl
}

ensure_root_snapper_config() {
    if sudo snapper -c root get-config >/dev/null 2>&1; then
        info "Snapper root config already exists."
        return 0
    fi

    if mountpoint -q /.snapshots; then
        fatal "Snapper root config is missing, but /.snapshots is already a mountpoint. Refusing automatic recovery."
    fi

    sudo snapper -c root create-config /
    sudo snapper -c root get-config >/dev/null 2>&1 || fatal "Snapper root config was not created correctly."
    info "Created Snapper root config."
}

ensure_top_level_snapshots_subvolume() {
    local root_source tmp_mnt mounted=false

    root_source="$(get_root_source)"
    [[ -n "$root_source" ]] || fatal "Could not determine the root source device."

    tmp_mnt="$(mktemp -d)"
    cleanup_top_level_mount() {
        if [[ "$mounted" == true ]]; then
            sudo umount "$tmp_mnt" 2>/dev/null || true
        fi
        rmdir "$tmp_mnt" 2>/dev/null || true
    }
    trap cleanup_top_level_mount RETURN

    sudo mount -o subvolid=5 "$root_source" "$tmp_mnt"
    mounted=true

    if [[ -e "${tmp_mnt}/@snapshots" ]]; then
        if sudo btrfs subvolume show "${tmp_mnt}/@snapshots" >/dev/null 2>&1; then
            info "Top-level subvolume @snapshots already exists."
        else
            fatal "Top-level path @snapshots exists, but it is not a Btrfs subvolume."
        fi
    else
        sudo btrfs subvolume create "${tmp_mnt}/@snapshots"
        info "Created top-level subvolume @snapshots."
    fi

    trap - RETURN
    cleanup_top_level_mount
}

prepare_snapshots_mountpoint() {
    sudo mkdir -p /.snapshots

    if mountpoint -q /.snapshots; then
        verify_snapshots_mount
        return 0
    fi

    if [[ ! -d /.snapshots ]]; then
        fatal "/.snapshots exists, but it is not a directory."
    fi

    if path_is_btrfs_subvolume /.snapshots; then
        if dir_has_entries /.snapshots; then
            fatal "Nested /.snapshots is a populated Btrfs subvolume. Refusing destructive migration."
        fi

        sudo btrfs subvolume delete /.snapshots
        sudo mkdir -p /.snapshots
        info "Removed empty nested /.snapshots subvolume."
        return 0
    fi

    if dir_has_entries /.snapshots; then
        fatal "/.snapshots is a non-empty directory. Refusing to mount over existing contents."
    fi
}

ensure_fstab_entry_for_root_snapshots() {
    local fs_uuid root_opts cleaned_opts mount_opts newline tmp

    fs_uuid="$(get_root_uuid)"
    [[ -n "$fs_uuid" ]] || fatal "Could not determine the Btrfs UUID for /"

    root_opts="$(get_root_mount_opts)"
    cleaned_opts="$(strip_subvol_opts "$root_opts")"

    mount_opts="$cleaned_opts"
    [[ -n "$mount_opts" ]] && mount_opts+=","
    mount_opts+="subvol=/@snapshots"

    newline="UUID=${fs_uuid} /.snapshots btrfs ${mount_opts} 0 0"

    backup_file /etc/fstab
    tmp="$(mktemp)"

    awk -v mp='/.snapshots' -v newline="$newline" '
        BEGIN { done = 0 }
        /^[[:space:]]*#/ { print; next }
        NF >= 2 && $2 == mp {
            if (!done) {
                print newline
                done = 1
            }
            next
        }
        { print }
        END {
            if (!done) {
                print newline
            }
        }
    ' /etc/fstab > "$tmp"

    sudo install -m 0644 "$tmp" /etc/fstab
    rm -f "$tmp"

    sudo systemctl daemon-reload
    info "Ensured /.snapshots entry in /etc/fstab"
}

mount_root_snapshots() {
    sudo mkdir -p /.snapshots

    if mountpoint -q /.snapshots; then
        verify_snapshots_mount
        return 0
    fi

    sudo mount /.snapshots
    verify_snapshots_mount
}

verify_snapper_works() {
    sudo snapper -c root get-config >/dev/null 2>&1 || fatal "Snapper root config is not usable."
    sudo snapper -c root list >/dev/null 2>&1 || fatal "Snapper cannot access the root snapshot set."
    info "Snapper root config is working."
}

tune_snapper() {
    sudo snapper -c root set-config \
        TIMELINE_CREATE="no" \
        NUMBER_CLEANUP="yes" \
        NUMBER_LIMIT="10" \
        NUMBER_LIMIT_IMPORTANT="5" \
        SPACE_LIMIT="0.0" \
        FREE_LIMIT="0.0"

    sudo btrfs quota disable / 2>/dev/null || true
    info "Applied Snapper retention settings for root."
}

preflight_checks() {
    (( EUID != 0 )) || fatal "Run this script as a regular user with sudo privileges, not as root."

    require_cmd sudo
    require_cmd pacman
    require_cmd findmnt
    require_cmd mountpoint
    require_cmd awk
    require_cmd sed
    require_cmd grep
    require_cmd stat
    require_cmd mktemp
    require_cmd date

    [[ "$(stat -f -c %T /)" == "btrfs" ]] || fatal "Root filesystem is not Btrfs."

    sudo -v || fatal "Cannot obtain sudo privileges."
    (
        while true; do
            sudo -n -v 2>/dev/null || exit
            sleep 240
        done
    ) &
    SUDO_PID=$!
}

preflight_checks

execute "Install Snapper packages" install_packages
post_install_checks
execute "Create Snapper root config" ensure_root_snapper_config
execute "Create top-level @snapshots subvolume" ensure_top_level_snapshots_subvolume
execute "Prepare /.snapshots mountpoint safely" prepare_snapshots_mountpoint
execute "Write /.snapshots mount to /etc/fstab" ensure_fstab_entry_for_root_snapshots
execute "Mount /.snapshots from @snapshots" mount_root_snapshots
execute "Verify Snapper can use the isolated snapshot layout" verify_snapper_works
execute "Apply Snapper cleanup settings" tune_snapper
