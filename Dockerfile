# --- Stage 1: Build PHP and SQLite for Android ABIs ---
FROM alpine:3.21 AS buildsystem

# Install required packages
RUN apk update && apk add --no-cache wget unzip gcompat libgcc bash patch make curl build-base coreutils

WORKDIR /opt

# Download NDK
ENV NDK_VERSION=android-ndk-r27c-linux
ENV NDK_ROOT=/opt/android-ndk-r27c
RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip && \
    unzip ${NDK_VERSION}.zip && \
    rm ${NDK_VERSION}.zip

# Add NDK toolchains to PATH
ENV PATH="${PATH}:${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin"

WORKDIR /root

# PHP & SQLite versions
ARG PHP_VERSION=8.4.2
ENV SQLITE3_VERSION=3470200

# Download and prepare SQLite
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip

# Download PHP source
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

# Copy any required patches
COPY *.patch /root/

# --- Function to build for a specific ABI ---
ARG TARGET
ARG API_LEVEL=32

WORKDIR /root/build

# Build SQLite first
WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
RUN ${TARGET}-clang -o libsqlite3.so -shared -fPIC sqlite3.c

# Build PHP
WORKDIR /root/build
RUN mkdir -p install

WORKDIR /root/php-${PHP_VERSION}
RUN patch -p1 < ../ext-standard-dns.c.patch && \
    patch -p1 < ../resolv.patch && \
    patch -p1 < ../ext-standard-php_fopen_wrapper.c.patch && \
    patch -p1 < ../main-streams-cast.c.patch && \
    patch -p1 < ../fork.patch

WORKDIR /root/build
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

RUN make -j$(nproc) sapi/cli/php

# Copy outputs
RUN cp sapi/cli/php install/php.so
RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so install/libsqlite3.so
RUN cp -r /root/php-${PHP_VERSION} install/php-headers

# --- Stage 2: Final artifacts ---
FROM alpine:3.21

RUN apk update && apk add --no-cache bash coreutils

WORKDIR /artifacts

# Copy binaries and headers
COPY --from=buildsystem /root/build/install/php.so ./php.so
COPY --from=buildsystem /root/build/install/libsqlite3.so ./libsqlite3.so
COPY --from=buildsystem /root/build/install/php-headers ./headers/php
