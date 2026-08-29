#!/usr/bin/env bash

# Personal NixOS installer
# SSD: /dev/nvme0n1
# HDD: /dev/sda
#
# SSD:
#   p1 = EFI
#   p2 = swap
#   p3 = root
#
# HDD:
#   p1 = /home/<username>/storage

set -e

# ============================================================
# Colors
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

info() {
  echo -e "\n${GREEN}$1${NC}"
}

warn() {
  echo -e "${YELLOW}$1${NC}"
}

error() {
  echo -e "${RED}Error: $1${NC}" >&2
}

# ============================================================
# Environment checks
# ============================================================

if [ ! -d "/iso" ] && [ "$(findmnt -o FSTYPE -n /)" != "tmpfs" ]; then
  error "This script must be run from the NixOS live ISO."
  exit 1
fi

if [ "$(id -u)" != "0" ]; then
  error "This script must be run as root."
  echo "Run: sudo $0"
  exit 1
fi

export NIX_CONFIG="experimental-features = nix-command flakes"

info "Welcome to the personal NixOS installer!"

# ============================================================
# Cleanup
# ============================================================

cleanup() {
  info "Cleaning up..."

  # Unmount HDD storage first
  if [ -n "$username" ] &&
    mountpoint -q "/mnt/home/$username/storage" 2>/dev/null; then
    umount "/mnt/home/$username/storage" 2>/dev/null || true
  fi

  # Disable swap
  if [ -n "$part_swap" ]; then
    swapoff "/dev/$part_swap" 2>/dev/null || true
  fi

  # Unmount everything under /mnt
  umount -R /mnt 2>/dev/null || true

  echo "Cleanup complete."
}

trap cleanup EXIT

# ============================================================
# Host management
# ============================================================

list_hosts() {
  local hosts=()

  for host_dir in ./hosts/*/; do
    if [ -d "$host_dir" ]; then
      hosts+=("$(basename "$host_dir")")
    fi
  done

  printf '%s\n' "${hosts[@]}"
}

create_new_host() {
  local new_name="$1"
  local template="$2"

  if [ -z "$new_name" ]; then
    error "Host name cannot be empty."
    return 1
  fi

  if [ -d "./hosts/$new_name" ]; then
    error "Host '$new_name' already exists."
    return 1
  fi

  if [ ! -d "./hosts/$template" ]; then
    error "Template host '$template' does not exist."
    return 1
  fi

  info "Creating host '$new_name' from '$template'..."

  cp -r "./hosts/$template" "./hosts/$new_name"

  # Remove old hardware configuration
  rm -f "./hosts/$new_name/hardware-configuration.nix"

  # Update hostname
  if [ -f "./hosts/$new_name/variables.nix" ]; then
    sed -i \
      -e "s/hostname = .*;/hostname = \"$new_name\";/" \
      "./hosts/$new_name/variables.nix"
  fi

  echo "Host '$new_name' created successfully."
}

add_host_to_flake() {
  local host_name="$1"

  info "Adding '$host_name' to flake.nix..."

  if grep -q "\"$host_name\"" flake.nix; then
    warn "Host '$host_name' already exists in flake.nix."
    return 0
  fi

  awk -v host="$host_name" '
    /nixosConfigurations = {/ {
      print
      getline
      print
      print "        " host " = mkHost \"" host "\";"
      next
    }
    { print }
  ' flake.nix > flake.nix.tmp

  mv flake.nix.tmp flake.nix

  info "Host '$host_name' added to flake.nix."
}

# ============================================================
# Host selection
# ============================================================

info "NixOS Configuration Host Selection"

mapfile -t available_hosts < <(list_hosts)

if [ ${#available_hosts[@]} -eq 0 ]; then
  error "No hosts found in hosts directory."
  exit 1
fi

echo
echo "Available hosts:"

for i in "${!available_hosts[@]}"; do
  echo "  $((i + 1))) ${available_hosts[$i]}"
done

echo "  n) Create new host"

while true; do
  read -r -p "Select host [default: 1]: " host_choice
  host_choice=${host_choice:-1}

  if [[ "$host_choice" =~ ^[nN]$ ]]; then

    read -r -p "Enter new host name: " new_host_name

    if [[ ! "$new_host_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      error "Invalid host name."
      continue
    fi

    echo
    echo "Select template host:"

    for i in "${!available_hosts[@]}"; do
      echo "  $((i + 1))) ${available_hosts[$i]}"
    done

    read -r -p "Template [default: 1]: " template_choice
    template_choice=${template_choice:-1}

    if [[ "$template_choice" =~ ^[0-9]+$ ]] &&
      [ "$template_choice" -ge 1 ] &&
      [ "$template_choice" -le "${#available_hosts[@]}" ]; then

      template_host="${available_hosts[$((template_choice - 1))]}"

      if create_new_host "$new_host_name" "$template_host"; then
        selected_host="$new_host_name"
        add_host_to_flake "$selected_host"
        break
      fi
    else
      error "Invalid template choice."
    fi

  elif [[ "$host_choice" =~ ^[0-9]+$ ]] &&
    [ "$host_choice" -ge 1 ] &&
    [ "$host_choice" -le "${#available_hosts[@]}" ]; then

    selected_host="${available_hosts[$((host_choice - 1))]}"
    break

  else
    error "Invalid choice."
  fi
done

info "Using host: $selected_host"

# ============================================================
# Username
# ============================================================

info "Set up user account"

while true; do
  read -r -p "Enter username: " username

  if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    break
  else
    error "Invalid username."
  fi
done

# ============================================================
# Password
# ============================================================

info "Set password for $username"

while true; do
  read -r -s -p "Enter password: " password
  echo

  read -r -s -p "Confirm password: " password_confirm
  echo

  if [ "$password" != "$password_confirm" ]; then
    error "Passwords do not match."
    continue
  fi

  if [ -z "$password" ]; then
    error "Password cannot be empty."
    continue
  fi

  break
done

# ============================================================
# GPU
# ============================================================

choose_drivers() {
  local host="$1"

  info "Choose GPU driver"

  echo "1) nvidia"
  echo "2) amdgpu"
  echo "3) intel"

  while true; do
    read -r -p "Choice [1-3]: " driver_choice

    case "$driver_choice" in
      1)
        sed -i \
          -e 's/videoDriver = .*;/videoDriver = "nvidia";/' \
          "./hosts/$host/variables.nix"
        break
        ;;

      2)
        sed -i \
          -e 's/videoDriver = .*;/videoDriver = "amdgpu";/' \
          "./hosts/$host/variables.nix"
        break
        ;;

      3)
        sed -i \
          -e 's/videoDriver = .*;/videoDriver = "intel";/' \
          "./hosts/$host/variables.nix"
        break
        ;;

      *)
        error "Invalid choice."
        ;;
    esac
  done
}

choose_drivers "$selected_host"

# ============================================================
# Update username
# ============================================================

sed -i \
  -e "s/username = .*;/username = \"$username\";/" \
  "./hosts/$selected_host/variables.nix"

# ============================================================
# Editor
# ============================================================

check_editors() {
  local editors=("vim" "nano" "vi")

  for editor in "${editors[@]}"; do
    if command -v "$editor" &>/dev/null; then
      echo "$editor"
      return
    fi
  done

  echo "none"
}

default_editor=$(check_editors)

if [ "$default_editor" = "none" ]; then
  warn "No editor found."
  editor="none"
else
  info "Choose an editor for variables.nix"

  echo "1) $default_editor"
  echo "2) vim"
  echo "3) nano"
  echo "4) vi"
  echo "5) Skip"

  while true; do
    read -r -p "Choice [default: 1]: " editor_choice
    editor_choice=${editor_choice:-1}

    case "$editor_choice" in
      1)
        editor="$default_editor"
        break
        ;;

      2)
        editor="vim"
        break
        ;;

      3)
        editor="nano"
        break
        ;;

      4)
        editor="vi"
        break
        ;;

      5)
        editor="none"
        break
        ;;

      *)
        error "Invalid choice."
        ;;
    esac
  done
fi

if [ "$editor" != "none" ]; then
  info "Opening variables.nix"

  "$editor" "./hosts/$selected_host/variables.nix"
fi

# ============================================================
# Automatic storage configuration
# ============================================================

clear

info "Automatic disk configuration"

echo
echo "This installer will use:"
echo
echo "  SSD: /dev/nvme0n1"
echo "  HDD: /dev/sda"
echo
echo "SSD:"
echo "  EFI      → /boot"
echo "  SWAP     → swap"
echo "  ROOT     → /"
echo
echo "HDD:"
echo "  STORAGE  → /home/$username/storage"
echo

# ============================================================
# EFI size
# ============================================================

while true; do
  read -r -p "EFI size in MiB [default: 1024]: " efi_size
  efi_size=${efi_size:-1024}

  if [[ "$efi_size" =~ ^[0-9]+$ ]] &&
    [ "$efi_size" -ge 512 ]; then
    break
  fi

  error "EFI must be at least 512 MiB."
done

# ============================================================
# Swap size
# ============================================================

while true; do
  read -r -p "Swap size in GiB [default: 8]: " swap_size
  swap_size=${swap_size:-8}

  if [[ "$swap_size" =~ ^[0-9]+$ ]] &&
    [ "$swap_size" -gt 0 ]; then
    break
  fi

  error "Swap size must be greater than 0."
done

swap_size_mib=$((swap_size * 1024))

# ============================================================
# Final confirmation
# ============================================================

echo
warn "=================================================="
warn "WARNING: THIS WILL ERASE BOTH DISKS"
warn "=================================================="
echo
echo "SSD: /dev/nvme0n1"
echo "  EFI:  ${efi_size} MiB"
echo "  Swap: ${swap_size} GiB"
echo "  Root: remaining space"
echo
echo "HDD: /dev/sda"
echo "  Storage: entire disk"
echo
echo "Storage will be mounted at:"
echo "  /home/$username/storage"
echo

read -r -p "Type ERASE to continue: " confirm

if [ "$confirm" != "ERASE" ]; then
  error "Installation aborted."
  exit 1
fi

# ============================================================
# Check disks
# ============================================================

info "Checking disks"

if mount | grep -qE '/dev/(nvme0n1|sda)'; then
  error "Installation disks are currently mounted."
  lsblk
  exit 1
fi

# ============================================================
# Wipe disks
# ============================================================

info "Wiping SSD"

wipefs -af /dev/nvme0n1

info "Wiping HDD"

wipefs -af /dev/sda

# ============================================================
# Partition SSD
# ============================================================

info "Partitioning SSD"

efi_end=$((efi_size + 1))
swap_start=$efi_end
swap_end=$((swap_start + swap_size_mib))

parted -s /dev/nvme0n1 \
  mklabel gpt \
  mkpart ESP fat32 1MiB "${efi_end}MiB" \
  set 1 esp on \
  mkpart primary linux-swap "${swap_start}MiB" "${swap_end}MiB" \
  mkpart primary ext4 "${swap_end}MiB" 100%

# ============================================================
# Partition HDD
# ============================================================

info "Partitioning HDD"

parted -s /dev/sda \
  mklabel gpt \
  mkpart primary ext4 1MiB 100%

partprobe /dev/nvme0n1
partprobe /dev/sda

sleep 2

# ============================================================
# Partition names
# ============================================================

part_boot="nvme0n1p1"
part_swap="nvme0n1p2"
part_root="nvme0n1p3"
part_storage="sda1"

# ============================================================
# Verify
# ============================================================

for part in \
  "$part_boot" \
  "$part_swap" \
  "$part_root" \
  "$part_storage"
do
  if [ ! -b "/dev/$part" ]; then
    error "/dev/$part does not exist."
    lsblk
    exit 1
  fi
done

info "Partitioning complete"

lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS \
  /dev/nvme0n1 /dev/sda

# ============================================================
# Format
# ============================================================

info "Formatting EFI"

mkfs.fat -F 32 "/dev/$part_boot"

info "Formatting root as ext4"

mkfs.ext4 -F "/dev/$part_root"

info "Formatting HDD storage as ext4"

mkfs.ext4 -F "/dev/$part_storage"

info "Creating swap"

mkswap "/dev/$part_swap"

# ============================================================
# Mount root
# ============================================================

info "Mounting root"

mount "/dev/$part_root" /mnt

# ============================================================
# Mount EFI
# ============================================================

info "Mounting EFI"

mkdir -p /mnt/boot

mount "/dev/$part_boot" /mnt/boot

# ============================================================
# Mount HDD storage
# ============================================================

info "Mounting HDD storage"

mkdir -p "/mnt/home/$username/storage"

mount \
  "/dev/$part_storage" \
  "/mnt/home/$username/storage"

# ============================================================
# Enable swap
# ============================================================

info "Enabling swap"

swapon "/dev/$part_swap"

# ============================================================
# Verify mounts
# ============================================================

info "Filesystem layout"

lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS \
  /dev/nvme0n1 /dev/sda

echo
echo "Final layout:"
echo
echo "  /dev/$part_boot    → /mnt/boot"
echo "  /dev/$part_swap    → swap"
echo "  /dev/$part_root    → /mnt"
echo "  /dev/$part_storage → /mnt/home/$username/storage"
echo

# ============================================================
# Generate hardware configuration
# ============================================================

info "Generating hardware configuration"

nixos-generate-config \
  --root /mnt \
  --show-hardware-config \
  > "./hosts/$selected_host/hardware-configuration.nix"

# ============================================================
# Copy flake
# ============================================================

info "Copying NixOS configuration"

mkdir -p /mnt/etc/nixos

cp -r ./ /mnt/etc/nixos/

# ============================================================
# Install
# ============================================================

info "Installing NixOS"

nixos-install \
  --flake "/mnt/etc/nixos#$selected_host" \
  --no-root-passwd

# ============================================================
# Set user password
# ============================================================

info "Setting password for $username"

nixos-enter \
  --root /mnt \
  -c "printf '%s\n' '$password' | chpasswd" || {
    warn "Failed to set password automatically."
    warn "Set it manually after booting."
  }

# ============================================================
# Create user directories
# ============================================================

info "Creating user directories"

mkdir -p \
  "/mnt/home/$username/Downloads" \
  "/mnt/home/$username/Documents" \
  "/mnt/home/$username/Pictures" \
  "/mnt/home/$username/Videos" \
  "/mnt/home/$username/.local/bin"

# ============================================================
# Copy flake to user's home
# ============================================================

info "Copying NixOS configuration to ~/NixOS"

mkdir -p "/mnt/home/$username/NixOS"

cp -r ./ "/mnt/home/$username/NixOS/"

# ============================================================
# Fix ownership
# ============================================================

info "Setting ownership"

uid=$(awk -F: -v user="$username" \
  '$1 == user {print $3}' /mnt/etc/passwd)

gid=$(awk -F: -v user="$username" \
  '$1 == user {print $4}' /mnt/etc/passwd)

if [ -z "$uid" ] || [ "$uid" = "0" ]; then
  error "Could not determine UID for $username."
  exit 1
fi

if [ -z "$gid" ] || [ "$gid" = "0" ]; then
  error "Could not determine GID for $username."
  exit 1
fi

chown -R "$uid:$gid" "/mnt/home/$username"

# ============================================================
# Done
# ============================================================

info "=================================================="
info "NixOS installation complete!"
info "=================================================="

echo
echo "Host:     $selected_host"
echo "Username: $username"
echo
echo "Storage:"
echo "  SSD → /"
echo "  HDD → /home/$username/storage"
echo
echo "Swap: ${swap_size} GiB"
echo "EFI:  ${efi_size} MiB"
echo
echo "You can now reboot."
echo
