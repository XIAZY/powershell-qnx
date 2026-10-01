# Copyright (c) Xia Zhongyang.
# Licensed under the MIT License.
#
# Build environment for the runtime and the QNX cross-compiled parts.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git build-essential cmake ninja-build python3 python3-clang-18 \
      clang lld llvm libclang-18-dev libicu-dev liblttng-ust-dev libssl-dev libkrb5-dev zlib1g-dev \
      libbrotli-dev locales file cpio \
    && rm -rf /var/lib/apt/lists/*
