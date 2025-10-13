FROM alpine:3.21 as buildsystem

RUN apk update
RUN apk add wget unzip gcompat libgcc bash patch make curl autoconf bison re2c pkgconfig

WORKDIR /opt
ENV NDK_VERSION android-ndk-r27c-linux
ENV NDK_ROOT /opt/android-ndk-r27c
RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip && \
    unzip ${NDK_VERSION}.zip && \
    rm ${NDK_VERSION}.zip

# CRITICAL FIX: Ensure the NDK toolchain is in the PATH
ENV PATH="${PATH}:${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin"

WORKDIR /root

##########
# CONFIG #
##########
ARG TARGET=aarch64-linux-android32
ARG PHP_VERSION=8.4.2

ENV SQLITE3_VERSION 3470200
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip
RUN unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip

WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
RUN ${TARGET}-clang -o libsqlite3.so -shared -fPIC sqlite3.c

WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz
RUN tar -xvf php-${PHP_VERSION}.tar.gz

COPY *.patch /root/
WORKDIR /root/php-${PHP_VERSION}
RUN \
patch -p1 < ../ext-standard-dns.c.patch && \
patch -p1 < ../resolv.patch && \
patch -p1 < ../ext-standard-php_fopen_wrapper.c.patch && \
patch -p1 < ../main-streams-cast.c.patch && \
patch -p1 < ../fork.patch \
;

# Regenerate configure script (sometimes needed for Android builds)
RUN autoconf

WORKDIR /root
RUN mkdir build install
WORKDIR /root/build

# Configure with embed SAPI but minimal features to avoid dependencies
RUN ../php-${PHP_VERSION}/configure \
  --host=${TARGET} \
  --enable-embed=shared \
  --disable-cli \
  --disable-cgi \
  --disable-fpm \
  --disable-phpdbg \
  --without-pear \
  --without-libxml \
  --disable-all \
  --enable-json \
  --enable-hash \
  --enable-session \
  --enable-tokenizer \
  --enable-pdo \
  --with-sqlite3 \
  --with-pdo-sqlite \
  --enable-filter \
  --enable-ctype \
  --disable-mbstring \
  --disable-mbregex \
  SQLITE_CFLAGS="-I/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
  SQLITE_LIBS="-lsqlite3 -L/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
  CC=$TARGET-clang \
  CFLAGS="-DANDROID -fPIC -D__ANDROID_API__=24" \
  LDFLAGS="-landroid -llog -lz" \
  --enable-shared \
  --with-pic \
  ;

# Build everything
RUN make -j$(nproc) V=1 2>&1 | tee build.log && \
    if [ ${PIPESTATUS[0]} -ne 0 ]; then \
        echo "Build failed, showing last 50 lines of log:"; \
        tail -50 build.log; \
        exit 1; \
    fi

# Check what libraries were built
RUN echo "=== Checking build results ===" && \
    find /root/build -type f -name "*.so" -exec ls -la {} \; && \
    find /root/build -name "libphp*" -type f

# Copy the embed SAPI library (try multiple possible locations)
RUN cp /root/build/sapi/embed/.libs/libphp.so /root/install/php.so 2>/dev/null || \
    cp /root/build/sapi/embed/libphp.so /root/install/php.so 2>/dev/null || \
    cp /root/build/libs/libphp.so /root/install/php.so 2>/dev/null || \
    cp /root/build/libphp.so /root/install/php.so 2>/dev/null || \
    echo "ERROR: Could not find any embed library!" && \
    find /root/build -name "libphp*" -type f

RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so /root/install/libsqlite3.so

# --- FINAL STAGE ---
FROM alpine:3.21
RUN apk update && apk add --no-cache bash

# Copy the compiled binaries
COPY --from=buildsystem /root/install/php.so /artifacts/php.so
COPY --from=buildsystem /root/install/libsqlite3.so /artifacts/libsqlite3.so

# Copy PHP Source/Headers required for external linking (Android NDK projects)
COPY --from=buildsystem /root/php-8.4.2 /artifacts/headers/php

# Copy PHP Build/Headers (generated config headers)
COPY --from=buildsystem /root/build/ /artifacts/headers/php/build/

# Expose the artifacts folder
WORKDIR /artifacts
