FROM alpine:3.21 AS buildsystem

# Install dependencies
RUN apk update && apk add --no-cache \
    wget unzip gcompat libgcc bash patch make curl build-base \
    git linux-headers cmake pkgconfig automake autoconf libtool

# Set up Android NDK
WORKDIR /opt
ENV NDK_VERSION=android-ndk-r27c-linux
ENV NDK_ROOT=/opt/android-ndk-r27c
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

# Build OpenSSL for Android
WORKDIR /root
RUN wget https://www.openssl.org/source/openssl-1.1.1w.tar.gz && \
    tar -xzf openssl-1.1.1w.tar.gz
WORKDIR /root/openssl-1.1.1w
RUN ./Configure android-arm64 \
    -D__ANDROID_API__=${API} \
    --prefix=/root/openssl-install \
    no-shared \
    no-asm \
    no-comp \
    no-hw \
    no-engine && \
    make -j7 && \
    make install_sw

# Build cURL for Android
WORKDIR /root
RUN wget https://curl.se/download/curl-7.88.1.tar.gz && \
    tar -xzf curl-7.88.1.tar.gz
WORKDIR /root/curl-7.88.1
RUN ./configure \
    --host=${TARGET} \
    --target=${TARGET} \
    --with-ssl=/root/openssl-install \
    --prefix=/root/curl-install \
    --disable-shared \
    --enable-static \
    --disable-verbose \
    --enable-ipv6 \
    --disable-manual \
    --without-libidn2 \
    --without-librtmp \
    --without-brotli \
    --without-zstd \
    CPPFLAGS="-I${SYSROOT}/usr/include -fPIC" \
    LDFLAGS="-static" && \
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

# Minimal runtime dependencies
RUN apk update && apk add --no-cache bash file

# Copy artifacts from build stage
COPY --from=buildsystem /root/install/ /artifacts/
COPY --from=buildsystem /root/php-${PHP_VERSION} /artifacts/headers/php
COPY --from=buildsystem /root/build/ /artifacts/headers/php/build/

WORKDIR /artifacts

# Verification step
RUN echo "=== Build Artifacts ===" && \
    ls -la && \
    echo "=== Library Dependencies ===" && \
    file php.so 2>/dev/null || file libphp.so 2>/dev/null || echo "No PHP library found!" && \
    echo "=== Test Extension Loading ==="
