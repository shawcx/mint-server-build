# Build environment for the Mint Server (unofficial) ISO.
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      debootstrap ca-certificates gnupg squashfs-tools xorriso mtools dosfstools \
      grub-common grub-pc-bin grub-efi-amd64-bin \
 && rm -rf /var/lib/apt/lists/*
