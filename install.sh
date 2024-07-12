#!/bin/bash
set -e

# Update package lists
sudo apt-get update

# Install dependencies (assuming Ubuntu/Debian-based system)
sudo apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    git \
    libvulkan-dev \
    vulkan-tools \
    libcjson-dev \
    libx265-dev \
    libavcodec-dev \
    libavutil-dev \
    libswscale-dev \
    libavfilter-dev \
    libbsd-dev \
    libavahi-client-dev \
    libeigen3-dev \
    glslang-tools \
    libudev-dev \
    libwayland-dev \
    libx11-xcb-dev \
    libxrandr-dev \
    libxcb-randr0-dev \
    libgl-dev \
    libglx-dev \
    mesa-common-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    libsystemd-dev \
    libva-dev \
    nlohmann-json3-dev \
    libpulse-dev \
    libpipewire-0.3-dev \
    libcli11-dev \
    libboost-all-dev

# Upgrade all packages
sudo apt-get upgrade -y

# Clone WiVRn repository
git clone https://github.com/Meumeu/WiVRn.git
cd WiVRn

# Build WiVRn server
cmake -B build-server . -GNinja \
    -DWIVRN_BUILD_CLIENT=OFF \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DWIVRN_USE_VAAPI=ON \
    -DWIVRN_USE_X265=ON \
    -DWIVRN_USE_NVENC=ON \
    -DWIVRN_USE_PIPEWIRE=ON \
    -DWIVRN_USE_PULSEAUDIO=ON \
    -DWIVRN_USE_SYSTEMD=ON

cmake --build build-server

# Enable and start Avahi daemon
sudo systemctl enable --now avahi-daemon

# Open necessary ports (assuming UFW firewall)
sudo ufw allow 5353/udp
sudo ufw allow 9757/tcp
sudo ufw allow 9757/udp

# Start WiVRn server
./build-server/server/wivrn-server
