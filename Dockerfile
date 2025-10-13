# ===========================
# Stage 1: Build PHP & SQLite
# ===========================
FROM alpine:3.21 AS buildsystem

# --- Install required build tools ---
RUN apk update && apk add --no-cache \
    wget unzip gcompat libgcc bash patch make curl build-base \
    autoconf bison re2c pkgconf libtool flex

WORKDIR /opt

# --- Download NDK ---
ENV NDK_VERSION=android-ndk-r27c-linux
ENV NDK_ROOT=/opt/android-ndk-r27c
RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip && \
    unzip ${NDK_VERSION}.zip && rm ${NDK_VERSION}.zip

ENV PATH="${PATH}:${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin"

# --- Versions ---
ARG PHP_VERSION=8.4.2
ENV SQLITE3_VERSION=3470200

# --- Download & Build SQLite ---
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip
WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}

# TARGET will be passed during docker build
ARG TARGET
RUN ${TARGET}-clang -o libsqlite3.so -shared -fPIC sqlite3.c

# --- Download PHP source ---
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

# --- Apply patches if any ---
COPY *.patch /root/
WORKDIR /root/php-${PHP_VERSION}
RUN for p in /root/*.patch; do patch -p1 < $p || true; done

# --- Prepare build directory ---
WORKDIR /root/build
RUN mkdir -p install

# --- Configure and build PHP ---
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
RUN cp sapi/cli/php install/php.so
RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so install/libsqlite3.so

# --- Copy PHP headers ---
RUN cp -r /root/php-${PHP_VERSION} install/php-headers

# ===========================
# Stage 2: Final Artifacts
# ===========================
FROM alpine:3.21
RUN apk update && apk add --no-cache bash

WORKDIR /artifacts

# Copy binaries and headers
COPY --from=buildsystem /root/build/install/php.so ./php.so
COPY --from=buildsystem /root/build/install/libsqlite3.so ./libsqlite3.so
COPY --from=buildsystem /root/build/install/php-headers ./headers/php
