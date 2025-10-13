# Stage 1: Build PHP and SQLite for Android ABIs
FROM alpine:3.21 as buildsystem

# Install required packages
RUN apk update && apk add --no-cache wget unzip gcompat libgcc bash patch make curl build-base

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

# Download and build SQLite
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip
WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
ARG TARGET
RUN ${TARGET}-clang -o libsqlite3.so -shared -fPIC sqlite3.c

# Download PHP source
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

# Apply custom patches if any
COPY *.patch /root/
WORKDIR /root/php-${PHP_VERSION}
RUN for p in /root/*.patch; do patch -p1 < $p || true; done

# Prepare build directory
WORKDIR /root/build
RUN mkdir -p install

# Fetch missing Android resolver headers
WORKDIR /root/php-${PHP_VERSION}/ext/standard
RUN for hdr in resolv_params.h resolv_private.h resolv_static.h resolv_stats.h; do \
      curl https://android.googlesource.com/platform/bionic/+/refs/heads/android12--mainline-release/libc/dns/include/$hdr?format=TEXT \
      | base64 -d > $hdr; \
    done

WORKDIR /root/build
# Configure PHP for Android
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
      CC=${TARGET}-clang \
      --disable-phar \
      --disable-phpdbg \
      --with-sqlite3 \
      --with-pdo-sqlite

# Build PHP CLI
RUN make -j$(nproc) sapi/cli/php
RUN cp /root/build/sapi/cli/php /root/build/install/php.so
RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so /root/build/install/libsqlite3.so

# Copy headers (for Android NDK projects)
RUN cp -r /root/php-${PHP_VERSION} /root/build/install/php-headers

# Stage 2: Final artifacts
FROM alpine:3.21
RUN apk update && apk add --no-cache bash

WORKDIR /artifacts
# Copy compiled binaries and headers
COPY --from=buildsystem /root/build/install/php.so ./php.so
COPY --from=buildsystem /root/build/install/libsqlite3.so ./libsqlite3.so
COPY --from=buildsystem /root/build/install/php-headers ./headers/php
