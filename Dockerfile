# ==========================================
# Stage 1: Build PHP for Android
# ==========================================
FROM alpine:3.21 AS buildsystem

# --- Base packages ---
RUN apk update && apk add wget unzip gcompat libgcc bash patch make curl autoconf build-base

WORKDIR /opt

# --- Setup Android NDK ---
ENV NDK_VERSION android-ndk-r27c-linux
ENV NDK_ROOT /opt/android-ndk-r27c
RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip \
    && unzip ${NDK_VERSION}.zip \
    && rm ${NDK_VERSION}.zip

# Add NDK toolchain to PATH
ENV PATH="${PATH}:${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin"

# ==========================================
# Stage 2: Download and build dependencies
# ==========================================
WORKDIR /root
ARG TARGET=aarch64-linux-android32
ARG PHP_VERSION=8.4.2
ENV SQLITE3_VERSION 3470200

# --- Build SQLite3 shared library ---
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip \
    && unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip
WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
RUN ${TARGET}-clang -o libsqlite3.so -shared -fPIC sqlite3.c

# --- Download and extract PHP source ---
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz \
    && tar -xvf php-${PHP_VERSION}.tar.gz

# --- Apply patches if any (optional) ---
COPY *.patch /root/
WORKDIR /root/php-${PHP_VERSION}
RUN \
patch -p1 < ../ext-standard-dns.c.patch && \
patch -p1 < ../resolv.patch && \
patch -p1 < ../ext-standard-php_fopen_wrapper.c.patch && \
patch -p1 < ../main-streams-cast.c.patch && \
patch -p1 < ../fork.patch \
;

# ==========================================
# Stage 3: Configure PHP (embedded mode)
# ==========================================
WORKDIR /root/build
RUN ../php-${PHP_VERSION}/configure \
    --host=${TARGET} \
    --prefix=/root/php-android-output \
    --enable-embed=shared \
    --disable-cli \
    --disable-cgi \
    --disable-fpm \
    --disable-phpdbg \
    --without-pear \
    --disable-dom \
    --disable-simplexml \
    --disable-xml \
    --disable-xmlreader \
    --disable-xmlwriter \
    --without-libxml \
    --disable-phar \
    --with-sqlite3 \
    --with-pdo-sqlite \
    CC=${TARGET}-clang \
    CFLAGS="-I/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
    LDFLAGS="-L/root/sqlite-amalgamation-${SQLITE3_VERSION}"

# ==========================================
# Stage 4: Build and install
# ==========================================
RUN make -j$(nproc)
RUN make install

# ==========================================
# Stage 5: Collect artifacts
# ==========================================
FROM alpine:3.21

RUN apk add --no-cache bash

# Copy PHP shared library (libphp.so)
COPY --from=buildsystem /root/php-android-output/lib/libphp.so /artifacts/php.so

# Copy SQLite3 shared lib
COPY --from=buildsystem /root/sqlite-amalgamation-*/libsqlite3.so /artifacts/libsqlite3.so

# Copy all PHP headers (includes Zend, TSRM, main, sapi)
COPY --from=buildsystem /root/php-android-output/include/php /artifacts/headers/php

# Working directory for exported artifacts
WORKDIR /artifacts

# Show directory structure when container runs
CMD ["bash", "-c", "echo 'Artifacts ready:' && find /artifacts -maxdepth 3 -type f"]
