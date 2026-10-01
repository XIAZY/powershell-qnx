# Copyright (c) Xia Zhongyang.
# Licensed under the MIT License.
#
# Target root filesystem for cross-building dotnet/runtime for linux-x86.
# Runs under qemu-i386 on non-x86 hosts; only its files are used (ROOTFS_DIR).
FROM --platform=linux/386 debian:bookworm
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libc6-dev libgcc-12-dev libstdc++-12-dev libicu-dev libssl-dev zlib1g-dev \
      libkrb5-dev liblttng-ust-dev libbrotli-dev libunwind-dev \
    && rm -rf /var/lib/apt/lists/*
