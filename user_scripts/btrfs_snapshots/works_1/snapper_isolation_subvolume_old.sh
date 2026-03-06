#!/usr/bin/env bash
# Bash 5.3+ | Snapper Subvolume Isolation and Limit Enforcement
set -Eeuo pipefail
export LC_ALL=C
trap 'echo -e "\n\033[1;31m[FATAL]\033[0m Script failed at line $LINENO. Command: $BASH_COMMAND" >&2' ERR

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

sudo -v || exit 1
( while true; do sudo -n -v 2>/dev/null; sleep 240; done ) &
SUDO_PID=$!
trap 'kill $SUDO_PID 2>/dev/null || true' EXIT

[[ "$(stat -f -c %T /)" == "btrfs" ]] || { echo "FATAL: Root filesystem is not BTRFS." >&2; exit 1; }

execute() {
    local desc="$1"
    shift
    if [[ "$AUTO_MODE" == true ]]; then
        "$@"
    else
        printf '\n\033[1;34m[ACTION]\033[0m %s\n' "$desc"
        read -rp "Execute this step? [Y/n] " response || { echo -e "\nInput closed; aborting." >&2; exit 1; }
        if [[ "${response,,}" =~ ^(n|no)$ ]]; then echo "Skipped."; return 0; fi
        "$@"
    fi
}

unmount_snapshots() {
    sudo umount /.snapshots 2>/dev/null || true
    sudo umount /home/.snapshots 2>/dev/null || true
    sudo rmdir /.snapshots /home/.snapshots 2>/dev/null || true
}
execute "Unmount existing snapshot directories" unmount_snapshots

create_configs() {
    sudo snapper -c root get-config &>/dev/null || sudo snapper -c root create-config /
    sudo snapper -c home get-config &>/dev/null || sudo snapper -c home create-config /home
}
execute "Generate default Snapper configs" create_configs

isolate_subvolumes() {
    # 1. Validate and Guide fstab configuration
    if ! grep -qE '^\s*[^#].*\s+/.snapshots\s+' /etc/fstab; then
        if [[ "$AUTO_MODE" == true ]]; then
            echo "FATAL: Missing /.snapshots entry in /etc/fstab. Cannot resolve interactively in --auto mode." >&2
            return 1
        fi
        
        echo -e "\n\033[1;33m[ACTION REQUIRED]\033[0m Missing /.snapshots entry in /etc/fstab!"
        echo "To fix this without breaking your specific mount options, please do the following:"
        echo "  1. Open a new terminal and run: sudo nano /etc/fstab (or your preferred editor)"
        echo "  2. Copy the line used for your root (/) partition."
        echo "  3. Paste it twice at the bottom."
        echo "  4. Change the mount point of the first copied line to: /.snapshots"
        echo "  5. Change its subvol option to: subvol=/@snapshots"
        echo "  6. Change the mount point of the second copied line to: /home/.snapshots"
        echo "  7. Change its subvol option to: subvol=/@home_snapshots"
        echo "  8. Save and exit."
        read -rp "Press [Enter] once you have updated /etc/fstab to continue..." || true
        
        if ! grep -qE '^\s*[^#].*\s+/.snapshots\s+' /etc/fstab; then
            echo "FATAL: Still no fstab entry found for /.snapshots. Aborting." >&2
            return 1
        fi
        sudo systemctl daemon-reload
        echo "Systemd daemon reloaded successfully."
    fi

    # 2. Validate and Create BTRFS top-level subvolumes if missing
    local root_dev
    root_dev=$(findmnt -fno SOURCE / | sed 's/\[.*\]//')
    local missing_snapshots=false
    local missing_home_snapshots=false
    
    if ! sudo btrfs subvolume list / | grep -q ' path @snapshots$'; then missing_snapshots=true; fi
    if ! sudo btrfs subvolume list / | grep -q ' path @home_snapshots$'; then missing_home_snapshots=true; fi
    
    if [[ "$missing_snapshots" == true || "$missing_home_snapshots" == true ]]; then
        local do_create=true
        if [[ "$AUTO_MODE" == false ]]; then
            echo -e "\n\033[1;33m[NOTICE]\033[0m One or more required top-level BTRFS subvolumes (@snapshots, @home_snapshots) are missing."
            read -rp "Would you like to automatically create them now? [Y/n] " create_resp || true
            if [[ ! "${create_resp,,}" =~ ^(y|yes|)$ ]]; then
                do_create=false
            fi
        fi
        
        if [[ "$do_create" == true ]]; then
            local tmp_mnt
            tmp_mnt=$(mktemp -d)
            sudo mount -o subvolid=5 "$root_dev" "$tmp_mnt" || { echo "FATAL: Failed to mount BTRFS top-level." >&2; rmdir "$tmp_mnt"; return 1; }
            
            [[ "$missing_snapshots" == true ]] && sudo btrfs subvolume create "$tmp_mnt/@snapshots"
            [[ "$missing_home_snapshots" == true ]] && sudo btrfs subvolume create "$tmp_mnt/@home_snapshots"
            
            sudo umount "$tmp_mnt"
            rmdir "$tmp_mnt"
            echo "Top-level subvolumes verified/created successfully."
        else
            echo "FATAL: Cannot proceed without the required top-level subvolumes." >&2
            return 1
        fi
    fi

    # 3. Proceed with standard isolation operations
    for snap_dir in /.snapshots /home/.snapshots; do
        if mountpoint -q "$snap_dir" 2>/dev/null; then
            echo "INFO: $snap_dir is currently mounted. Skipping subvolume deletion to protect data."
            continue
        fi
        
        if sudo btrfs subvolume show "$snap_dir" &>/dev/null; then
            # Delete children via subvolid to bypass relative path VFS mangling
            sudo btrfs subvolume list -o "$snap_dir" | awk '{print $2}' | sort -rn | while IFS= read -r id; do
                [[ -n "$id" ]] && sudo btrfs subvolume delete --subvolid "$id" / 2>/dev/null || true
            done
            sudo btrfs subvolume delete "$snap_dir"
        fi
    done
    
    sudo mkdir -p /.snapshots /home/.snapshots
    
    sudo mount /.snapshots
    findmnt /home/.snapshots &>/dev/null || sudo mount /home/.snapshots 2>/dev/null || true
    
    if ! findmnt /.snapshots &>/dev/null; then
        echo "FATAL: /.snapshots mount failed." >&2
        return 1
    fi
    sudo chmod 750 /.snapshots
    findmnt /home/.snapshots &>/dev/null && sudo chmod 750 /home/.snapshots || true
}
execute "Destroy nested subvolumes and mount top-level @snapshots" isolate_subvolumes

tune_snapper() {
    for conf in root home; do
        if sudo snapper -c "$conf" get-config &>/dev/null; then
            # 0.0 floats explicitly required by newer snapper schemas
            sudo snapper -c "$conf" set-config TIMELINE_CREATE="no" NUMBER_LIMIT="10" NUMBER_LIMIT_IMPORTANT="5" SPACE_LIMIT="0.0" FREE_LIMIT="0.0"
        fi
    done
    sudo btrfs quota disable / 2>/dev/null || true
}
execute "Enforce count-based retention limits" tune_snapper

configure_snap_pac() {
    if [[ -f /etc/snap-pac.ini ]] && sed -n '/^\[home\]/,/^\[/p' /etc/snap-pac.ini | grep -q '.'; then
        if sed -n '/^\[home\]/,/^\[/p' /etc/snap-pac.ini | grep -q '^\s*snapshot\s*='; then
            sudo sed -i '/^\[home\]/,/^\[/{s/^\s*snapshot\s*=.*/snapshot = no/}' /etc/snap-pac.ini
        else
            sudo sed -i '/^\[home\]/a snapshot = no' /etc/snap-pac.ini
        fi
    else
        printf '\n[home]\nsnapshot = no\n' | sudo tee -a /etc/snap-pac.ini >/dev/null
    fi
}
execute "Configure snap-pac to ignore /home" configure_snap_pac

enable_timers() {
    sudo systemctl disable --now snapper-timeline.timer 2>/dev/null || true
    sudo systemctl enable --now snapper-cleanup.timer
}
execute "Enable Snapper cleanup timer" enable_timers
