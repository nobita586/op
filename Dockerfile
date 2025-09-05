# Base image
FROM ubuntu:22.04

# Install KVM/QEMU/Libvirt tools
RUN apt-get update && apt-get install -y \
    qemu-kvm libvirt-daemon-system libvirt-clients virt-manager wget sudo

# Create folders
RUN mkdir -p /isos /vms /scripts

WORKDIR /scripts

# Download ISOs automatically
RUN wget -O /isos/ubuntu-22.04.5.iso https://releases.ubuntu.com/jammy/ubuntu-22.04.5-live-server-amd64.iso \
    && wget -O /isos/debian-12.7.0.iso https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.7.0-amd64-netinst.iso

# Copy auto-run script into container
COPY kvm_auto.sh /scripts/kvm_auto.sh
RUN chmod +x /scripts/kvm_auto.sh

# Set entrypoint to auto-run script
ENTRYPOINT ["/scripts/kvm_auto.sh"]
