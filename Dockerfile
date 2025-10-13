# Stage 1: Build PHP and SQLite for Android ABI
FROM alpine:3.21 as buildsystem

# Install required packages
RUN apk update && apk add --no-cache \
    wget unzip gcompat libgcc bash patch make curl build-base coreutils \
    autoconf bison re2c pkgconf libtool flex

WORKDIR /opt

# Download NDK
ENV NDK_VERSION=android-ndk-r27c-linux
ENV NDK_ROOT=/opt/android-ndk-r27c
RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip && \
    unzip ${NDK_VERSION}.zip && \
    rm ${NDK_VERSION}.zip

# Add NDK toolchain to PATH
ENV PATH="${PATH}:${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin"

WORKDIR /root

# PHP & SQLite versions
ARG PHP_VERSION=8.4.2
ENV SQLITE3_VERSION=3470200
ARG API_LEVEL=32
ARG TARGET=aarch64-linux-android

# Download and build SQLite
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip

WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
RUN ${TARGET}${API_LEVEL}-clang -o libsqlite3.so -shared -fPIC sqlite3.c

# Download PHP source
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

# Copy patch files if they exist
RUN sh -c 'if compgen -G "*.patch" > /dev/null; then cp *.patch /root/; fi'

# Move into PHP source
WORKDIR /root/php-${PHP_VERSION}

# Apply patches
RUN for patch in /root/*.patch; do \
        [ -f "$patch" ] && patch -p1 < "$patch"; \
    done

# Prepare build directory
WORKDIR /root/build
RUN mkdir -p install

# Copy missing resolv headers from Android source
RUN for hdr in resolv_params.h resolv_private.h resolv_static.h resolv_stats.h; do \
        curl -s https://android.googlesource.com/platform/bionic/+/refs/heads/android12--mainline-release/libc/dns/include/$hdr?format=TEXT | base64 -d > $hdr; \
    done

# Configure PHP
RUN ../php-${PHP_VERSION}/configure \
      --host=${TARGET} \
      --enable-embed=shared \
      --disable-dom \
      --disable-simplexml \
      --disable-xml \
      --disable-xmlreader \
      --disable-xmlwriter \
      --without-pear \
      --without-libxml \
      SQLITE_CFLAGS="-I/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
      SQLITE_LIBS="-lsqlite3 -L/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
      CC=${TARGET}${API_LEVEL}-clang \
      --disable-phar \
      --disable-phpdbg \
      --with-sqlite3 \
      --with-pdo-sqlite

# Build PHP CLI
RUN make -j$(nproc) sapi/cli/php

# Install built binaries
RUN cp sapi/cli/php install/php.so
RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so install/libsqlite3.so

# Copy headers (for Android NDK projects)
RUN cp -r /root/php-${PHP_VERSION} install/php-headers

# Stage 2: Final artifacts
FROM alpine:3.21
RUN apk update && apk add --no-cache bash

WORKDIR /artifacts

# Copy the binaries and headers from build stage
COPY --from=buildsystem /root/build/install/php.so ./php.so
COPY --from=buildsystem /root/build/install/libsqlite3.so ./libsqlite3.so
COPY --from=buildsystem /root/build/install/php-headers ./headers/php
