FROM alpine:3.21 AS buildsystem

# Install dependencies including Perl for OpenSSL build
RUN apk update && apk add --no-cache \
    wget unzip gcompat libgcc bash patch make curl build-base \
    openssl-dev curl-dev perl

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
ARG PHP_VERSION=8.4.2
ENV SQLITE3_VERSION=3470200

# Download and build OpenSSL for Android (proper approach)
RUN wget https://www.openssl.org/source/openssl-3.0.14.tar.gz && \
    tar -xzf openssl-3.0.14.tar.gz && \
    cd openssl-3.0.14 && \
    export ANDROID_NDK_ROOT=${NDK_ROOT} && \
    export MACHINE=aarch64 && \
    export RELEASE=android-21 && \
    export SYSTEM=android && \
    export ARCH=aarch64 && \
    export CROSS_COMPILE=${TARGET}- && \
    ./Configure linux-aarch64 --prefix=/root/openssl-android --openssldir=/root/openssl-android/ssl && \
    make -j7 && make install && \
    cd ..

# Download and build SQLite
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip
WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
RUN ${TARGET}-clang -o libsqlite3.so -shared -fPIC sqlite3.c

# Download PHP source
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

# Apply patches
COPY *.patch /root/
WORKDIR /root/php-${PHP_VERSION}
RUN patch -p1 < ../ext-standard-dns.c.patch && \
    patch -p1 < ../resolv.patch && \
    patch -p1 < ../ext-standard-php_fopen_wrapper.c.patch && \
    patch -p1 < ../main-streams-cast.c.patch && \
    patch -p1 < ../fork.patch

# Prepare build directories
WORKDIR /root
RUN mkdir build install
WORKDIR /root/build

# Configure PHP for embed
RUN ../php-${PHP_VERSION}/configure \
  --host=${TARGET} \
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
  --with-openssl=/root/openssl-android \
  --with-curl \
  CC=${TARGET}-clang \
  SQLITE_CFLAGS="-I/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
  SQLITE_LIBS="-lsqlite3 -L/root/sqlite-amalgamation-${SQLITE3_VERSION}"

# Download missing Android DNS headers
RUN for hdr in resolv_params.h resolv_private.h resolv_static.h resolv_stats.h; do \
      curl https://android.googlesource.com/platform/bionic/+/refs/heads/android12--mainline-release/libc/dns/include/$hdr?format=TEXT | base64 -d > $hdr; \
    done

# Build and install PHP with embed SAPI
RUN make -j7 && make install

# Copy the embed library and SQLite
RUN cp /root/php-android-output/lib/libphp.so /root/install/php.so || \
    echo "ERROR: Could not find embed library!"

RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so /root/install/libsqlite3.so

# --- FINAL STAGE ---
FROM alpine:3.21

# Minimal runtime dependencies
RUN apk update && apk add --no-cache bash

# Copy artifacts from build stage
COPY --from=buildsystem /root/install/php.so /artifacts/php.so
COPY --from=buildsystem /root/install/libsqlite3.so /artifacts/libsqlite3.so
COPY --from=buildsystem /root/php-${PHP_VERSION} /artifacts/headers/php
COPY --from=buildsystem /root/build/ /artifacts/headers/php/build/

WORKDIR /artifacts
