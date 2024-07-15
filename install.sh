#!/bin/bash
set -euo pipefail

# Global variables
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/wivrn_install.log"
readonly ANDROID_SDK_URL="https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip"
readonly ANDROID_SDK_ZIP="commandlinetools-linux-9477386_latest.zip"
readonly DEFAULT_KEYSTORE_PASSWORD="wivrn_dev_password"
readonly WIVRN_VERSION="1.0.0"  # Update this with the actual version
readonly ANDROID_HOME="${HOME}/Android"
readonly JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
readonly WIVRN_PORT=9757

export ANDROID_HOME
export JAVA_HOME

# Function to check if a command exists
CommandExists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to install packages
InstallPackages() {
  sudo apt-get install -y "$@"
}

# Function for pretty logging
LogSection() {
  local message="$1"
  echo -e "\n\033[1;34m==== ${message} ====\033[0m"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" >> "${LOG_FILE}"
}

# Function to log messages
LogMessage() {
  local message="$1"
  echo "${message}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" >> "${LOG_FILE}"
}

# Function to show progress
ShowProgress() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\'
  while [ "$(ps a | awk '{print $1}' | grep ${pid})" ]; do
    local temp=${spinstr#?}
    printf " [%c]  " "${spinstr}"
    local spinstr=${temp}${spinstr%"${temp}"}
    sleep ${delay}
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
}

# Cleanup function
Cleanup() {
  LogMessage "Cleaning up..."

  # Remove Android SDK if it was newly created
  if [ ! -d "${ANDROID_HOME}" ] && [ -f "${ANDROID_SDK_ZIP}" ]; then
    LogMessage "Removing Android SDK..."
    rm -rf "${ANDROID_HOME}"
    rm -f "${ANDROID_SDK_ZIP}"
  fi

  # Remove WiVRn client build directory if it exists
  if [ -d build-client ]; then
    LogMessage "Removing WiVRn client build directory..."
    rm -rf build-client
  fi

  # Remove android-udev-rules directory if it exists
  if [ -d android-udev-rules ]; then
    LogMessage "Removing android-udev-rules directory..."
    rm -rf android-udev-rules
  fi

  if [ -f adb ]; then
    adb kill-server
  fi

  LogMessage "Cleanup complete. Check ${LOG_FILE} for details."
}

# Trap to call cleanup function on script exit
trap Cleanup EXIT

# Version check function
CheckVersion() {
  local required_version="$1"
  local current_version="$2"
  if [ "$(printf '%s\n' "${required_version}" "${current_version}" | sort -V | head -n1)" != "${required_version}" ]; then
    return 1
  fi
  return 0
}

# Function to kill process on a specific port
KillProcessOnPort() {
  local port=$1
  local pid=$(lsof -t -i:${port})
  if [ -n "${pid}" ]; then
    LogMessage "Killing process ${pid} on port ${port}"
    kill -9 ${pid}
  fi
}

# Main function
Main() {
  LogSection "Checking user privileges"
  if [ "${EUID}" -eq 0 ]; then
    LogMessage "Error: Please run this script as a non-root user with sudo privileges."
    exit 1
  fi

  LogSection "Installing dependencies"
  if [ ! -f /etc/apt/trusted.gpg.d/lunarg.asc ]; then
    wget -qO- https://packages.lunarg.com/lunarg-signing-key-pub.asc | sudo tee /etc/apt/trusted.gpg.d/lunarg.asc
    sudo wget -qO /etc/apt/sources.list.d/lunarg-vulkan-jammy.list http://packages.lunarg.com/vulkan/lunarg-vulkan-jammy.list
  fi

  LogMessage "Updating package lists..."
  sudo apt-get update || { LogMessage "Error: Failed to update package lists"; exit 1; }

  local PACKAGES=(
    vulkan-sdk build-essential cmake ninja-build git libcjson-dev libx265-dev
    libavcodec-dev libavutil-dev libswscale-dev libavfilter-dev libbsd-dev
    libavahi-client-dev libeigen3-dev glslang-tools libudev-dev libwayland-dev
    libx11-xcb-dev libxrandr-dev libxcb-randr0-dev libgl-dev libglx-dev
    mesa-common-dev libgl1-mesa-dev libglu1-mesa-dev libsystemd-dev libva-dev
    nlohmann-json3-dev libpulse-dev libpipewire-0.3-dev libcli11-dev libboost-all-dev
    doxygen libuvc-dev libusb-1.0-0-dev openjdk-17-jre-headless librsvg2-dev libopenxr-dev
    libopenxr-loader1 xr-hardware libsdl2-dev
  )

  LogMessage "Installing packages..."
  InstallPackages "${PACKAGES[@]}" || { LogMessage "Error: Failed to install packages"; exit 1; }

  LogMessage "Upgrading packages..."
  sudo apt-get upgrade -y || { LogMessage "Error: Failed to upgrade packages"; exit 1; }

  LogSection "Building WiVRn server"
  cmake -B build-server . -GNinja \
    -DWIVRN_BUILD_CLIENT=OFF \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DWIVRN_USE_NVENC=ON \
    -DWIVRN_USE_VAAPI=ON \
    -DWIVRN_USE_X265=ON \
    -DWIVRN_USE_PIPEWIRE=ON \
    -DWIVRN_USE_PULSEAUDIO=ON \
    -DWIVRN_USE_SYSTEMD=ON || { LogMessage "Error: Failed to configure WiVRn server"; exit 1; }

  LogMessage "Building WiVRn server..."
  cmake --build build-server || { LogMessage "Error: Failed to build WiVRn server"; exit 1; }

  LogMessage "Enabling and starting Avahi daemon..."
  sudo systemctl enable --now avahi-daemon || { LogMessage "Error: Failed to enable/start Avahi daemon"; exit 1; }

  if CommandExists ufw; then
    LogMessage "Configuring firewall..."
    sudo ufw allow 5353/udp
    sudo ufw allow ${WIVRN_PORT}/tcp
    sudo ufw allow ${WIVRN_PORT}/udp
  else
    LogMessage "Warning: UFW not found. Please manually configure your firewall to allow ports 5353/udp, ${WIVRN_PORT}/tcp, and ${WIVRN_PORT}/udp."
  fi

  if [ ! -d "${ANDROID_HOME}" ]; then
    LogMessage "Setting up Android SDK..."
    mkdir -p "${ANDROID_HOME}"
    wget "${ANDROID_SDK_URL}" -O "${ANDROID_SDK_ZIP}" || { LogMessage "Error: Failed to download Android SDK"; exit 1; }
    unzip "${ANDROID_SDK_ZIP}" -d "${ANDROID_HOME}" || { LogMessage "Error: Failed to extract Android SDK"; exit 1; }
    rm "${ANDROID_SDK_ZIP}"
    yes | "${ANDROID_HOME}/cmdline-tools/bin/sdkmanager" --sdk_root="${ANDROID_HOME}" --licenses || { LogMessage "Error: Failed to accept Android SDK licenses"; exit 1; }
  fi

  if [ ! -f ks.keystore ]; then
    LogSection "Creating APK signing keys"
    keytool -genkey -v -keystore ks.keystore -alias default_key -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass "${DEFAULT_KEYSTORE_PASSWORD}" -keypass "${DEFAULT_KEYSTORE_PASSWORD}" \
      -dname "CN=WiVRn Dev, OU=Development, O=WiVRn, L=City, S=State, C=US" || { LogMessage "Error: Failed to create keystore"; exit 1; }
    echo "signingKeyPassword=\"${DEFAULT_KEYSTORE_PASSWORD}\"" > gradle.properties
    LogMessage "Development keystore created with default password. This is for development purposes only."
  fi

  LogSection "Installing Android udev rules"
  if [ ! -d "android-udev-rules" ]; then
    git clone https://github.com/M0Rf30/android-udev-rules.git || { LogMessage "Error: Failed to clone android-udev-rules"; exit 1; }
    (cd android-udev-rules && sudo ./install.sh) || { LogMessage "Error: Failed to install android-udev-rules"; exit 1; }
  else
    LogMessage "Android udev rules already installed. Skipping."
  fi

  LogSection "Installing WiVRn client"
  adb start-server || { LogMessage "Error: Failed to start ADB server"; exit 1; }
  adb reverse tcp:${WIVRN_PORT} tcp:${WIVRN_PORT} || { LogMessage "Error: Failed to set up port forwarding"; exit 1; }
  adb install ./WiVRn-standard-release.apk || { LogMessage "Error: Failed to install WiVRn client"; exit 1; }

  LogSection "Starting WiVRn client"
  adb shell am start -a android.intent.action.VIEW -d "wivrn://localhost" org.meumeu.wivrn || { LogMessage "Error: Failed to start WiVRn client"; exit 1; }

  local WIVRN_CONFIG_FILE="$(pwd)/config.json"
  cat > "${WIVRN_CONFIG_FILE}" <<EOF
{
    "tcp_only": true
}
EOF
  LogMessage "Created WiVRn configuration in ${WIVRN_CONFIG_FILE}"

  LogSection "Starting WiVRn server"
  if [ -f ./build-server/server/wivrn-server ]; then
    LogMessage "Starting WiVRn server..."
    KillProcessOnPort ${WIVRN_PORT}
    ./build-server/server/wivrn-server -f "${WIVRN_CONFIG_FILE}" || { LogMessage "Error: Failed to start WiVRn server"; exit 1; }
  else
    LogMessage "Error: WiVRn server executable not found. Please check the build process."
    exit 1
  fi

  LogMessage "Installation complete. Check ${LOG_FILE} for details."
}

# Run the main function
Main
