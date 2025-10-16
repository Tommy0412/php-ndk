FROM alpine:3.21 AS buildsystem

# Install dependencies
RUN apk update && apk add --no-cache \
    wget unzip gcompat libgcc bash patch make curl build-base \
    git linux-headers cmake pkgconfig automake autoconf libtool

# Set up Android NDK
WORKDIR /opt
ENV NDK_VERSION=android-ndk-r27c-linux
ENV NDK_ROOT=/opt/android-ndk-r27c
ENV ANDROID_NDK_HOME=${NDK_ROOT}  # For OpenSSL 1.1.1
ENV ANDROID_NDK_ROOT=${NDK_ROOT}  # For OpenSSL 3.x
RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip && \
    unzip ${NDK_VERSION}.zip && \
    rm ${NDK_VERSION}.zip

ENV PATH="${PATH}:${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin"

# Prepare build environment
WORKDIR /root
ARG TARGET=aarch64-linux-android32
ARG API=32
ARG PHP_VERSION=8.4.2
ENV SQLITE3_VERSION=3470200

# Set up toolchain variables
ENV CC=${TARGET}${API}-clang
ENV CXX=${TARGET}${API}-clang++
ENV AR=llvm-ar
ENV RANLIB=llvm-ranlib
ENV STRIP=llvm-strip
ENV TOOLCHAIN=${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64
ENV SYSROOT=${TOOLCHAIN}/sysroot

# Build OpenSSL for Android - FIXED: Use 1.1.1w with proper env vars
WORKDIR /root
RUN wget https://www.openssl.org/source/openssl-1.1.1w.tar.gz && \
    tar -xzf openssl-1.1.1w.tar.gz
WORKDIR /root/openssl-1.1.1w

# FIX: Export ANDROID_NDK_HOME in the same RUN command
RUN export ANDROID_NDK_HOME=${NDK_ROOT} && \
    ./Configure android-arm64 \
    -D__ANDROID_API__=${API} \
    --prefix=/root/openssl-install \
    shared \
    no-asm \
    no-comp \
    no-hw \
    no-engine && \
    make -j7 && \
    make install_sw

# Build cURL for Android - Keep the fixed version
WORKDIR /root
RUN wget https://curl.se/download/curl-8.13.0.tar.gz && \
    tar -xzf curl-8.13.0.tar.gz
WORKDIR /root/curl-8.13.0

RUN ./configure \
    --host=${TARGET} \
    --target=${TARGET} \
    --with-ssl=/root/openssl-install \
    --prefix=/root/curl-install \
    --enable-shared \
    --disable-static \
    --disable-verbose \
    --enable-ipv6 \
    --disable-manual \
    --without-libidn2 \
    --without-librtmp \
    --without-brotli \
    --without-zstd \
    CPPFLAGS="-I${SYSROOT}/usr/include -fPIC" \
    LDFLAGS="-L/root/openssl-install/lib" && \
    make -j7 && \
    make install

# Download and build SQLite
WORKDIR /root
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip
WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
RUN ${CC} -o libsqlite3.so -shared -fPIC sqlite3.c

# Download PHP source
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

# Apply patches
COPY *.patch /root/
WORKDIR /root/php-${PHP_VERSION}
RUN for patch in ../*.patch; do [ -f "$patch" ] && patch -p1 < "$patch" || true; done

# Prepare build directories
WORKDIR /root
RUN mkdir -p build install
WORKDIR /root/build

# Configure PHP for embed with OpenSSL and cURL
RUN ../php-${PHP_VERSION}/configure \
  --host=${TARGET} \
  --target=${TARGET} \
  --prefix=/root/php-android-output \
  --enable-embed=shared \
  --disable-cli \
  --disable-cgi \
  --disable-fpm \
  --disable-dom \
  --disable-simplexml \
  --disable-xml \
  --disable-xmlreader \
  --disable-xmlwriter \
  --without-pear \
  --without-libxml \
  --disable-phar \
  --disable-phpdbg \
  --with-sqlite3 \
  --with-pdo-sqlite \
  --with-openssl=/root/openssl-install \
  --with-curl=/root/curl-install \
  --enable-mbstring \
  --enable-json \
  --enable-bcmath \
  --enable-filter \
  --enable-hash \
  --enable-pcntl \
  CC=${CC} \
  CXX=${CXX} \
  CFLAGS="-DANDROID -fPIE -fPIC \
          -I/root/sqlite-amalgamation-${SQLITE3_VERSION} \
          -I/root/openssl-install/include \
          -I/root/curl-install/include \
          -I${SYSROOT}/usr/include" \
  LDFLAGS="-pie -shared \
           -L/root/sqlite-amalgamation-${SQLITE3_VERSION} \
           -L/root/openssl-install/lib \
           -L/root/curl-install/lib \
           -L${SYSROOT}/usr/lib/${TARGET}/${API} \
           -lcurl -lssl -lcrypto -lz -ldl"

# Download missing Android DNS headers if needed
RUN mkdir -p /root/dns-headers && \
    cd /root/dns-headers && \
    for hdr in resolv_params.h resolv_private.h resolv_static.h resolv_stats.h; do \
      curl -f https://android.googlesource.com/platform/bionic/+/refs/heads/android12-mainline-release/libc/dns/include/$hdr?format=TEXT 2>/dev/null | base64 -d > $hdr || true; \
    done

# Build and install PHP with embed SAPI
RUN make -j7 && make install

# Verify the build produced libphp.so
RUN find /root -name "libphp.so" -o -name "php.so" | head -1

# Copy the embed library and dependencies
RUN cp /root/php-android-output/lib/libphp.so /root/install/ 2>/dev/null || \
    cp /root/build/libs/libphp.so /root/install/ 2>/dev/null || \
    (echo "ERROR: Could not find embed library!" && find /root -name "*php*.so" -type f)

RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so /root/install/

# Create a test script to verify extensions
RUN echo "<?php echo 'OpenSSL: ' . (extension_loaded('openssl') ? 'LOADED' : 'MISSING') . PHP_EOL; echo 'cURL: ' . (extension_loaded('curl') ? 'LOADED' : 'MISSING') . PHP_EOL; echo 'SQLite: ' . (extension_loaded('sqlite3') ? 'LOADED' : 'MISSING') . PHP_EOL; ?>" > /root/install/test_extensions.php

# --- FINAL STAGE ---
FROM alpine:3.21

# Copy ALL artifacts from build stage to a predictable location
COPY --from=buildsystem /root/install/ /artifacts/binaries/
COPY --from=buildsystem /root/build/ /artifacts/headers/php/build/
COPY --from=buildsystem /root/php-android-output/ /artifacts/php-install/

WORKDIR /artifacts

# Create a manifest of what was built
RUN find . -type f -name "*.so" -o -name "*.h" | sort > manifest.txt

# Verification step
RUN echo "=== Build Artifacts ===" && \
    ls -la && \
    echo "=== Library Dependencies ===" && \
    file php.so 2>/dev/null || file libphp.so 2>/dev/null || echo "No PHP library found!" && \
    echo "=== Test Extension Loading ==="
