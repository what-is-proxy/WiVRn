# Use Ubuntu 22.04 as the base image
FROM ubuntu:22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies and runtime libraries
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    git \
    libvulkan-dev \
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
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /wivrn

# Copy the source code
COPY . .

# Build WiVRn server
RUN cmake -B build -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DWIVRN_BUILD_SERVER=ON \
    -DWIVRN_BUILD_CLIENT=OFF \
    -DWIVRN_BUILD_DISSECTOR=OFF \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DWIVRN_USE_VAAPI=ON \
    -DWIVRN_USE_X265=ON \
    -DWIVRN_USE_NVENC=ON \
    -DWIVRN_USE_SYSTEM_BOOST=OFF \
    -DWIVRN_USE_PULSEAUDIO=ON \
    -DWIVRN_USE_PIPEWIRE=ON \
    && cmake --build build

# Set the entry point
ENTRYPOINT ["/wivrn/build/server/wivrn-server"]
