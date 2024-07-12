#!/bin/bash
set -euo pipefail

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install packages
install_packages() {
    sudo apt-get install -y "$@"
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo "Please run this script as a non-root user with sudo privileges."
    exit 1
fi

# Add LunarG signing key and repository
if [ ! -f /etc/apt/trusted.gpg.d/lunarg.asc ]; then
    wget -qO- https://packages.lunarg.com/lunarg-signing-key-pub.asc | sudo tee /etc/apt/trusted.gpg.d/lunarg.asc
    sudo wget -qO /etc/apt/sources.list.d/lunarg-vulkan-jammy.list http://packages.lunarg.com/vulkan/lunarg-vulkan-jammy.list
fi

# Update package lists
sudo apt-get update

# Install Vulkan SDK and other dependencies
PACKAGES=(
    vulkan-sdk build-essential cmake ninja-build git libcjson-dev libx265-dev
    libavcodec-dev libavutil-dev libswscale-dev libavfilter-dev libbsd-dev
    libavahi-client-dev libeigen3-dev glslang-tools libudev-dev libwayland-dev
    libx11-xcb-dev libxrandr-dev libxcb-randr0-dev libgl-dev libglx-dev
    mesa-common-dev libgl1-mesa-dev libglu1-mesa-dev libsystemd-dev libva-dev
    nlohmann-json3-dev libpulse-dev libpipewire-0.3-dev libcli11-dev libboost-all-dev
    doxygen libuvc-dev libusb-1.0-0-dev
)

install_packages "${PACKAGES[@]}"

# Upgrade all packages
sudo apt-get upgrade -y

# Build WiVRn server
cmake -B build-server . -GNinja \
    -DWIVRN_BUILD_CLIENT=OFF \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DWIVRN_USE_NVENC=OFF \
    -DWIVRN_USE_VAAPI=OFF \
    -DWIVRN_USE_X265=ON \
    -DWIVRN_USE_PIPEWIRE=ON \
    -DWIVRN_USE_PULSEAUDIO=ON \
    -DWIVRN_USE_SYSTEMD=ON

cmake --build build-server

# Enable and start Avahi daemon
sudo systemctl enable --now avahi-daemon

# Open necessary ports (assuming UFW firewall)
if command_exists ufw; then
    sudo ufw allow 5353/udp
    sudo ufw allow 9757/tcp
    sudo ufw allow 9757/udp
else
    echo "UFW not found. Please manually configure your firewall to allow ports 5353/udp, 9757/tcp, and 9757/udp."
fi

# Start WiVRn server
if [ -f ./build-server/server/wivrn-server ]; then
    ./build-server/server/wivrn-server
else
    echo "WiVRn server executable not found. Please check the build process."
    exit 1
fi
