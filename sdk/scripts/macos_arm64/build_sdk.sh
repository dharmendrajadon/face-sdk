#!/bin/bash
set -e

echo "Building SDK for macOS arm64"

JAVA_HOME=${1:-""}
export PROJ_PATH=`pwd`
export CURRENT_ARCH="arm64" # Explicitly set for clarity
export SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)

if [[ -z ${JAVA_HOME} ]];
then
    WITH_JAVA="OFF"
else
    WITH_JAVA="ON"
fi

echo "Clean up previous 3rdparty build directories"
rm -rf 3rdparty/build && mkdir -p 3rdparty/build && cd 3rdparty/build

echo "Download and unpack ONNX Runtime for macOS arm64"
# Link from official GitHub releases: https://github.com/microsoft/onnxruntime/releases
# Version 1.22.0 for osx-arm64
ONNX_VERSION="1.22.0"
ONNX_FILENAME="onnxruntime-osx-arm64-${ONNX_VERSION}.tgz"
wget "https://github.com/microsoft/onnxruntime/releases/download/v${ONNX_VERSION}/${ONNX_FILENAME}"
tar -xvf "${ONNX_FILENAME}" && mv "onnxruntime-osx-arm64-${ONNX_VERSION}" onnxruntime
rm "${ONNX_FILENAME}"

echo "Download and unpack OpenCV for macOS arm64"
# Link from official OpenCV releases: https://opencv.org/releases/
# Version 4.11.0 sources
OPENCV_VERSION="4.11.0"
OPENCV_FILENAME="opencv-${OPENCV_VERSION}.zip"
OPENCV_CONTRIB_FILENAME="opencv_contrib-${OPENCV_VERSION}.zip"

wget "https://github.com/opencv/opencv/archive/refs/tags/${OPENCV_VERSION}.zip" -O "${OPENCV_FILENAME}"
wget "https://github.com/opencv/opencv_contrib/archive/refs/tags/${OPENCV_VERSION}.zip" -O "${OPENCV_CONTRIB_FILENAME}"

unzip -o "${OPENCV_FILENAME}" -d .
unzip -o "${OPENCV_CONTRIB_FILENAME}" -d .
mv "opencv-${OPENCV_VERSION}" opencv
mv "opencv_contrib-${OPENCV_VERSION}" opencv_contrib
rm "${OPENCV_FILENAME}" "${OPENCV_CONTRIB_FILENAME}"

echo "Build OpenCV from source"
cd "opencv"
mkdir -p build && cd build

# Configure OpenCV build for macOS arm64
# Adjust PYTHON3_EXECUTABLE, PYTHON3_INCLUDE_DIR, PYTHON3_NUMPY_INCLUDE_DIRS if building Python bindings and using a specific Python env
cmake \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=../../opencv_install \
    -DOPENCV_EXTRA_MODULES_PATH=../../opencv_contrib/modules \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_PERF_TESTS=OFF \
    -DBUILD_DOCS=OFF \
    -DWITH_OPENJPEG=OFF \
    -DWITH_IPP=OFF \
    -DBUILD_opencv_python2=OFF \
    -DBUILD_opencv_python3=OFF \
    -DOPENCV_ENABLE_NONFREE=ON \
    ..

make -j$(sysctl -n hw.ncpu)
make install
cd ../.. # Back to 3rdparty/build

cd ${PROJ_PATH}

echo "Download models"
if command -v gdown &> /dev/null
then
    gdown https://drive.google.com/u/0/uc?id=162OXlEh_18TLI0denqNysnBAGE3l8F-N -O models.zip
else
    wget https://download.3divi.com/facesdk/archives/artifacts/models/models.zip
fi

rm -rf data/models/* && unzip models.zip -d data/models
rm models.zip

echo "Configure and build the SDK"
rm -rf build && mkdir build && cd build

export BUILD_DIR=`pwd`
export CMAKE_INSTALL_PREFIX="$(pwd)/make-install"

# Adjust CMake flags for macOS arm64
# Removed -DWITH_SSE=ON (x86 specific)
# Added CMAKE_OSX_ARCHITECTURES=arm64
# Added CMAKE_POLICY_VERSION_MINIMUM=3.5 for CMake compatibility
echo "Running cmake configuration..."
cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED=ON \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_PREFIX_PATH=${PROJ_PATH}/3rdparty/build/opencv_install \
    -DCMAKE_INSTALL_PREFIX=${CMAKE_INSTALL_PREFIX} \
    -DTDV_OPENCV_DIR=${PROJ_PATH}/3rdparty/build/opencv \
    -DTDV_ONNXRUNTIME_DIR=${PROJ_PATH}/3rdparty/build/onnxruntime \
    -DOpenCV_DIR=${PROJ_PATH}/3rdparty/build/opencv_install/lib/cmake/opencv4 \
    -DOPENCV_INCLUDE_DIRS=${PROJ_PATH}/3rdparty/build/opencv_install/include/opencv4 \
    -DCMAKE_CXX_FLAGS="-O3 -DNDEBUG -std=gnu++11 -arch arm64 -fPIC -DWITH_OPENCV -D_POSIX_C_SOURCE=200809L -D__MACOSX__ -lz" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L/opt/homebrew/lib -L${SDK_PATH}/usr/lib -Wl,-undefined,dynamic_lookup" \
    -DCMAKE_EXE_LINKER_FLAGS="-L/opt/homebrew/lib -L${SDK_PATH}/usr/lib -Wl,-undefined,dynamic_lookup" \
    -DWITH_SAMPLES=ON \
    -DWITH_JAVA=${WITH_JAVA} \
    -DJAVA_HOME=${JAVA_HOME} \
    ..

echo "CMake configuration completed. Checking if OpenCV was found:"
grep -i opencv CMakeCache.txt | head -10 || echo "No OpenCV entries in CMakeCache.txt"

echo "Checking what's actually in the install/3rdparty/include directory:"
ls -la install/3rdparty/include/ || echo "Directory doesn't exist yet"

make install -j$(sysctl -n hw.ncpu)

cd make-install

export LIB_PATH="$(pwd)/lib"

# Adjust library copying for macOS
# Libraries will be .dylib
echo "Copying libraries for macOS"

if [ -d "python_api/face_sdk" ]; then
    cd python_api/face_sdk
    mkdir -p for_macos
    cd for_macos

    mkdir -p open_source_sdk
    if [ -f "${LIB_PATH}/libopen_source_sdk.dylib" ]; then
        cp "${LIB_PATH}/libopen_source_sdk.dylib" "$(pwd)/open_source_sdk/"
    else
        echo "Warning: libopen_source_sdk.dylib not found in ${LIB_PATH}"
    fi

    mkdir -p onnxruntime
    if [ -f "${PROJ_PATH}/3rdparty/build/onnxruntime/lib/libonnxruntime.${ONNX_VERSION}.dylib" ]; then
        cp "${PROJ_PATH}/3rdparty/build/onnxruntime/lib/libonnxruntime.${ONNX_VERSION}.dylib" "$(pwd)/onnxruntime/"
        # Create a symlink or copy to libonnxruntime.dylib for consistency if needed by the SDK
        ln -sf "libonnxruntime.${ONNX_VERSION}.dylib" "$(pwd)/onnxruntime/libonnxruntime.dylib"
    elif [ -f "${PROJ_PATH}/3rdparty/build/onnxruntime/lib/libonnxruntime.dylib" ]; then
         cp "${PROJ_PATH}/3rdparty/build/onnxruntime/lib/libonnxruntime.dylib" "$(pwd)/onnxruntime/"
    else
        echo "Warning: ONNX Runtime .dylib not found in ${PROJ_PATH}/3rdparty/build/onnxruntime/lib/"
    fi
    cd ${BUILD_DIR}
else
    echo "Warning: python_api/face_sdk directory not found in make-install. Skipping Python API library copy."
fi

echo "SDK build for macOS arm64 finished in ${BUILD_DIR}"
cd ${PROJ_PATH} # Go back to project root

echo "Final SDK contents in build/make-install"
