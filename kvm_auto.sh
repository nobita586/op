#!/bin/bash

# Default resources
DEFAULT_RAM=14000
DEFAULT_CPU=2
DEFAULT_DISK=50
VM_PATH="/vms"
ISO_PATH="/isos"

mkdir -p "$VM_PATH"

# Ask for VM name and OS type
read -p "Enter VM name: " VM_NAME
echo "Select OS type:"
echo "1) Ubuntu 22.04"
echo "2) Debian 12"
read -p "Choice [1-2]: " OS_CHOICE

case $OS_CHOICE in
    1)
        ISO_FILE="$ISO_PATH/ubuntu-22.04.iso"
        OS_VARIANT="ubuntu22.04"
        ;;
    2)
        ISO_FILE="$ISO_PATH/debian-12.iso"
        OS_VARIANT="debian12"
        ;;
    *)
        echo "Invalid choice!"
        exit 1
        ;;
esac

# Check if VM exists
if virsh list --all --name | grep -w "$VM_NAME" > /dev/null; then
    echo "VM '$VM_NAME' already exists. Starting it..."
    virsh start "$VM_NAME"
    virsh console "$VM_NAME"
    exit 0
fi

# Auto-create disk
DISK_PATH="$VM_PATH/${VM_NAME}.qcow2"
qemu-img create -f qcow2 "$DISK_PATH" "${DEFAULT_DISK}G"

# Auto-install VM with default resources
virt-install \
  --name "$VM_NAME" \
  --ram "$DEFAULT_RAM" \
  --vcpus "$DEFAULT_CPU" \
  --disk path="$DISK_PATH",format=qcow2 \
  --os-variant "$OS_VARIANT" \
  --cdrom "$ISO_FILE" \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole

# Connect to console
virsh console "$VM_NAME"
