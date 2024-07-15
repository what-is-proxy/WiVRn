#!/bin/bash
set -euo pipefail

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/wivrn_install.log"
ANDROID_SDK_URL="https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip"
ANDROID_SDK_ZIP="commandlinetools-linux-9477386_latest.zip"
DEFAULT_KEYSTORE_PASSWORD="wivrn_dev_password"
WIVRN_VERSION="1.0.0"  # Update this with the actual version
ANDROID_HOME="${HOME}/Android"
export ANDROID_HOME
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install packages
install_packages() {
    sudo apt-get install -y "$@"
}

# Function for pretty logging
log_section() {
    local message="$1"
    echo -e "\n\033[1;34m==== $message ====\033[0m"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# Function to log messages
log_message() {
    local message="$1"
    echo "$message"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# Function to show progress
show_progress() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Cleanup function
cleanup() {
    log_message "Cleaning up..."

    # Remove Android SDK if it was newly created
    if [ ! -d "${ANDROID_HOME}" ] && [ -f "$ANDROID_SDK_ZIP" ]; then
        log_message "Removing Android SDK..."
        rm -rf "${ANDROID_HOME}"
        rm -f "$ANDROID_SDK_ZIP"
    fi

    # Remove WiVRn client build directory if it exists
    if [ -d build-client ]; then
        log_message "Removing WiVRn client build directory..."
        rm -rf build-client
    fi

    # Remove WiVRn server build directory if it exists
    if [ -d build-server ]; then
        log_message "Removing WiVRn server build directory..."
        rm -rf build-server
    fi

    # Remove android-udev-rules directory if it exists
    if [ -d android-udev-rules ]; then
        log_message "Removing android-udev-rules directory..."
        rm -rf android-udev-rules
    fi

    if [ -f adb ]; then
        adb kill-server
    fi

    log_message "Cleanup complete. Check $LOG_FILE for details."
}

# Trap to call cleanup function on script exit
trap cleanup EXIT

# Version check function
check_version() {
    local required_version="$1"
    local current_version="$2"
    if [ "$(printf '%s\n' "$required_version" "$current_version" | sort -V | head -n1)" != "$required_version" ]; then
        return 1
    fi
    return 0
}

log_section "Checking user privileges"
# Check if running as root
if [ "$EUID" -eq 0 ]; then
    log_message "Please run this script as a non-root user with sudo privileges."
    exit 1
fi

log_section "Installing dependencies"
# Add LunarG signing key and repository
if [ ! -f /etc/apt/trusted.gpg.d/lunarg.asc ]; then
    wget -qO- https://packages.lunarg.com/lunarg-signing-key-pub.asc | sudo tee /etc/apt/trusted.gpg.d/lunarg.asc
    sudo wget -qO /etc/apt/sources.list.d/lunarg-vulkan-jammy.list http://packages.lunarg.com/vulkan/lunarg-vulkan-jammy.list
fi

# Update package lists
log_message "Updating package lists..."
sudo apt-get update &
show_progress $!

# Install Vulkan SDK and other dependencies
PACKAGES=(
    vulkan-sdk build-essential cmake ninja-build git libcjson-dev libx265-dev
    libavcodec-dev libavutil-dev libswscale-dev libavfilter-dev libbsd-dev
    libavahi-client-dev libeigen3-dev glslang-tools libudev-dev libwayland-dev
    libx11-xcb-dev libxrandr-dev libxcb-randr0-dev libgl-dev libglx-dev
    mesa-common-dev libgl1-mesa-dev libglu1-mesa-dev libsystemd-dev libva-dev
    nlohmann-json3-dev libpulse-dev libpipewire-0.3-dev libcli11-dev libboost-all-dev
    doxygen libuvc-dev libusb-1.0-0-dev openjdk-17-jre-headless librsvg2-dev
)

log_message "Installing packages..."
install_packages "${PACKAGES[@]}" &
show_progress $!

# Upgrade all packages
log_message "Upgrading packages..."
sudo apt-get upgrade -y &
show_progress $!

log_section "Building WiVRn server"
# Build WiVRn server
log_message "Configuring WiVRn server..."
cmake -B build-server . -GNinja \
    -DWIVRN_BUILD_CLIENT=OFF \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DWIVRN_USE_NVENC=ON \
    -DWIVRN_USE_VAAPI=ON \
    -DWIVRN_USE_X265=ON \
    -DWIVRN_USE_PIPEWIRE=ON \
    -DWIVRN_USE_PULSEAUDIO=ON \
    -DWIVRN_USE_SYSTEMD=ON

log_message "Building WiVRn server..."
cmake --build build-server &
show_progress $!

# Enable and start Avahi daemon
log_message "Enabling and starting Avahi daemon..."
sudo systemctl enable --now avahi-daemon

# Open necessary ports (assuming UFW firewall)
if command_exists ufw; then
    log_message "Configuring firewall..."
    sudo ufw allow 5353/udp
    sudo ufw allow 9757/tcp
    sudo ufw allow 9757/udp
else
    log_message "UFW not found. Please manually configure your firewall to allow ports 5353/udp, 9757/tcp, and 9757/udp."
fi

# Download and set up Android SDK
if [ ! -d "${ANDROID_HOME}" ]; then
    log_message "Setting up Android SDK..."
    mkdir -p "${ANDROID_HOME}"
    wget "$ANDROID_SDK_URL" -O "$ANDROID_SDK_ZIP"
    unzip "$ANDROID_SDK_ZIP" -d "${ANDROID_HOME}"
    rm "$ANDROID_SDK_ZIP"
    yes | "${ANDROID_HOME}/cmdline-tools/bin/sdkmanager" --sdk_root="${ANDROID_HOME}" --licenses
fi

# Create APK signing keys for development
if [ ! -f ks.keystore ]; then
    log_section "Creating APK signing keys"
    log_message "Creating keystore..."
    keytool -genkey -v -keystore ks.keystore -alias default_key -keyalg RSA -keysize 2048 -validity 10000 -storepass "$DEFAULT_KEYSTORE_PASSWORD" -keypass "$DEFAULT_KEYSTORE_PASSWORD" -dname "CN=WiVRn Dev, OU=Development, O=WiVRn, L=City, S=State, C=US"
    echo "signingKeyPassword=\"$DEFAULT_KEYSTORE_PASSWORD\"" > gradle.properties
    log_message "Development keystore created with default password. This is for development purposes only."
fi

log_section "Installing Android udev rules"
if [ ! -d "android-udev-rules" ]; then
    git clone https://github.com/M0Rf30/android-udev-rules.git
    cd android-udev-rules
    sudo ./install.sh
    cd ..
else
    log_message "Android udev rules already installed. Skipping."
fi

# log_section "Building WiVRn client"
# # Build WiVRn client
# log_message "Building WiVRn client..."
# ./gradlew assembleStandardRelease
# show_progress $!

log_section "Installing WiVRn client"

log_message "Starting ADB server..."
adb start-server

log_message "Starting Port Forwarding"
adb forward tcp:9757 tcp:9757

# Install WiVRn client using adb
log_message "Installing WiVRn client..."
adb install ./WiVRn-standard-release.apk

log_section "Starting WiVRn client"
adb shell am start -a android.intent.action.VIEW -d "wivrn://localhost" org.meumeu.wivrn

# Create the WiVRn configuration file
WIVRN_CONFIG_FILE="$(pwd)/config.json"
cat > "$WIVRN_CONFIG_FILE" <<EOF
{
    "tcp_only": true
}
EOF
log_message "Created WiVRn configuration in $WIVRN_CONFIG_FILE"

# Display configuration details
log_message "WiVRn configuration file: $WIVRN_CONFIG_FILE"

log_section "Starting WiVRn server"
# Start WiVRn server
if [ -f ./build-server/server/wivrn-server ]; then
    log_message "Starting WiVRn server..."
    ./build-server/server/wivrn-server -f $WIVRN_CONFIG_FILE
else
    log_message "WiVRn server executable not found. Please check the build process."
    exit 1
fi

log_section "Starting WiVRn client"
log_message "Please start the WiVRn client app on your device and connect to the server."

log_message "Installation complete. Check $LOG_FILE for details."
