# Stage 1: Build PHP and SQLite for arm64-v8a
FROM alpine:3.21 as buildsystem

# Install required packages
RUN apk update && apk add wget unzip gcompat libgcc bash patch make curl build-base

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
ARG API_LEVEL=32
ARG TARGET=aarch64-linux-android

# Download and build SQLite
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip
WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}

# Compile SQLite for arm64-v8a
RUN ${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin/${TARGET}${API_LEVEL}-clang \
    -o libsqlite3.so -shared -fPIC sqlite3.c

# Download PHP source
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

COPY *.patch /root/
WORKDIR /root/php-${PHP_VERSION}
RUN patch -p1 < ../ext-standard-dns.c.patch && \
    patch -p1 < ../resolv.patch && \
    patch -p1 < ../ext-standard-php_fopen_wrapper.c.patch && \
    patch -p1 < ../main-streams-cast.c.patch && \
    patch -p1 < ../fork.patch

# Prepare build directory
WORKDIR /root/build
RUN mkdir -p install

# Configure PHP for arm64-v8a
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
    CC=${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin/${TARGET}${API_LEVEL}-clang \
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

# Copy the binaries and headers
COPY --from=buildsystem /root/build/install/php.so ./php.so
COPY --from=buildsystem /root/build/install/libsqlite3.so ./libsqlite3.so
COPY --from=buildsystem /root/build/install/php-headers ./headers/php
