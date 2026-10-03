# Copyright (c) Xia Zhongyang.
# Licensed under the MIT License.
#
# Builds libpsl-native for QNX Neutrino with the QNX toolchain of the runtime
# (eng/native/qnx/toolchain.cmake in dotnet-runtime-qnx), as PowerShell-Native
# builds its libpsl-native with CMake.
cmake_minimum_required(VERSION 3.20)
project(psl-native C)

add_library(psl-native SHARED psl-native.c)
set_target_properties(psl-native PROPERTIES C_STANDARD 11 C_EXTENSIONS ON C_VISIBILITY_PRESET hidden)
target_compile_options(psl-native PRIVATE -Wall -Wextra)
