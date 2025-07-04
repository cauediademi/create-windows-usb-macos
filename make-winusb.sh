#!/bin/bash

set -e

### === CONFIGURATION === ###
ISO_PATH=""  # Leave empty to prompt
MOUNT_DIR="/Volumes"
### ====================== ###

# Require sudo
if [[ $EUID -ne 0 ]]; then
  echo "⚠️  Please run this script with sudo:"
  echo "    sudo $0"
  exit 1
fi

# Prompt for ISO if not set
if [ -z "$ISO_PATH" ]; then
  read -p "📂 Enter path to Windows ISO: " ISO_PATH
  if [ ! -f "$ISO_PATH" ]; then
    echo "❌ File not found: $ISO_PATH"
    exit 1
  fi
else
  echo "📁 ISO_PATH is set to: $ISO_PATH"
  read -p "❓ Continue with this ISO? Type YES to confirm: " iso_confirm
  if [ "$iso_confirm" != "YES" ]; then
    echo "Aborted by user."
    exit 1
  fi
fi

echo "🔍 Scanning for USB drives..."

CANDIDATES=($(diskutil list external | grep '^/dev/' | awk '{print $1}'))


if [ ${#CANDIDATES[@]} -eq 0 ]; then
  echo "🔌 No USB drive detected. Please insert one and press Enter..."
  read
  sleep 3
  diskutil list external | grep '^/dev/' | awk '{print $1}' > /tmp/usb-candidates.txt
  CANDIDATES=($(cat /tmp/usb-candidates.txt))
fi

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  echo "⚠️  Still no USB drive found. Falling back to /dev/disk2"
  USB_DISK="/dev/disk2"
elif [ ${#CANDIDATES[@]} -eq 1 ]; then
  USB_DISK="${CANDIDATES[0]}"
  DISK_SIZE=$(diskutil info "$USB_DISK" | awk -F ': ' '/Disk Size/ && !/Total/ { print $2 }' | xargs)
  echo "✅ Detected USB drive: $USB_DISK ($DISK_SIZE)"
else
  echo "⚠️  Multiple USB drives found. Please select one:"
  for i in "${!CANDIDATES[@]}"; do
    size=$(diskutil info "${CANDIDATES[$i]}" | awk -F ': ' '/Disk Size/ && !/Total/ { print $2 }')
    echo "$((i+1)). ${CANDIDATES[$i]} ($size)"
  done
  read -p "Enter the number of the disk to use: " choice
  USB_DISK="${CANDIDATES[$((choice-1))]}"
fi

echo "🚨 WARNING: This will ERASE EVERYTHING on $USB_DISK"
read -p "Type YES to continue: " confirm
confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
  echo "Aborted."
  exit 1
fi


### 1. Erase USB as FAT32 with MBR
echo "🧼 Erasing USB drive..."
diskutil eraseDisk MS-DOS "WINUSB" MBR "$USB_DISK"

### 2. Detect mounted volume path more reliably
echo "🔍 Detecting mounted USB volume..."
sleep 3
USB_PATH=$(mount | grep "$USB_DISK" | awk '{print $3}')

if [ -z "$USB_PATH" ] || [ ! -d "$USB_PATH" ]; then
  USB_PATH=$(ls -td /Volumes/* | head -n1)
fi

if [ ! -d "$USB_PATH" ]; then
  echo "❌ Could not locate mounted USB volume."
  exit 1
fi

echo "📦 USB mounted at: $USB_PATH"

### 3. Mount the ISO
echo "💿 Mounting ISO image..."
hdiutil mount "$ISO_PATH" | grep "/Volumes/" || { echo "❌ Failed to mount ISO."; exit 1; }

ISO_MOUNT=$(ls "$MOUNT_DIR" | grep -iE 'CCCOMA|Win|ESD' | head -n 1)
ISO_PATH_MOUNTED="$MOUNT_DIR/$ISO_MOUNT"

if [ ! -d "$ISO_PATH_MOUNTED" ]; then
  echo "❌ Could not find mounted ISO volume."
  exit 1
fi
echo "📁 ISO mounted at: $ISO_PATH_MOUNTED"

### 4. Copy all ISO files except install.wim
echo "📤 Copying ISO files (excluding install.wim)..."
if ! rsync -avh --progress \
  --no-perms --no-owner --no-group --inplace \
  --exclude=sources/install.wim \
  "$ISO_PATH_MOUNTED"/ "$USB_PATH"/; then
  echo "❌ File copy failed. Aborting."
  exit 1
fi


### 5. Ensure wimlib is installed
if ! command -v wimlib-imagex &> /dev/null; then
  echo "🔧 Installing wimlib (requires Homebrew)..."
  brew install wimlib
fi

### 6. Split install.wim to fit FAT32
echo "🪓 Splitting install.wim to .swm format for FAT32..."
wimlib-imagex split "$ISO_PATH_MOUNTED/sources/install.wim" "$USB_PATH/sources/install.swm" 4000

### 7. Clean up any leftover install.wim
if [ -f "$USB_PATH/sources/install.wim" ]; then
  echo "🧹 Removing install.wim..."
  rm "$USB_PATH/sources/install.wim"
fi

### 8. Eject USB
echo "📤 Ejecting USB drive..."
diskutil eject "$USB_DISK"

echo "🔽 Unmounting ISO image..."
hdiutil unmount "$ISO_PATH_MOUNTED" || echo "⚠️  Failed to unmount ISO."

echo "🎉 DONE: Bootable Windows USB created successfully!"
