# Dockerfile — build PHP (embed) + sqlite for arm64-v8a (Android)
FROM alpine:3.21 AS buildsystem

# -------------------------
# Install build prerequisites
# -------------------------
RUN apk update && apk add --no-cache \
    wget unzip gcompat libgcc bash patch make curl build-base coreutils \
    autoconf bison re2c pkgconf libtool flex

WORKDIR /opt

# -------------------------
# Download Android NDK (r27c)
# -------------------------
ENV NDK_VERSION=android-ndk-r27c-linux
ENV NDK_ROOT=/opt/android-ndk-r27c

RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip && \
    unzip ${NDK_VERSION}.zip && \
    rm ${NDK_VERSION}.zip

# Make NDK clang visible in PATH (use explicit binaries later)
ENV PATH="${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin:${PATH}"

WORKDIR /root

# -------------------------
# Versions / build args
# -------------------------
ARG PHP_VERSION=8.4.2
ENV SQLITE3_VERSION=3470200

# Default to arm64 (you can override with --build-arg TARGET=... but workflow will pass it)
ARG TARGET=aarch64-linux-android
ARG API_LEVEL=32

# -------------------------
# Download & build SQLite amalgamation
# -------------------------
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip

WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}

# Use full compiler name including API level
RUN ${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin/${TARGET}${API_LEVEL}-clang \
    -o libsqlite3.so -shared -fPIC sqlite3.c

# -------------------------
# Download PHP source
# -------------------------
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

# If you have patches, copy them. If none exist, this will do nothing.
COPY *.patch /root/ || true

WORKDIR /root/php-${PHP_VERSION}

# Apply optional patches (if present)
RUN for p in /root/*.patch; do \
      if [ -f "$p" ]; then patch -p1 < "$p" || true; fi; \
    done

# -------------------------
# Prepare resolver header fix (keep DNS enabled)
# -------------------------
# 1) Prefer to download Android resolver headers from AOSP for compatibility
# 2) Also patch dns.c to include <resolv.h> instead of private header as a safe fallback
WORKDIR /root/php-${PHP_VERSION}/ext/standard

# Try to download headers (if network available). If not, fallback to sed patch.
RUN set -eux; \
    for hdr in resolv_params.h resolv_private.h resolv_static.h resolv_stats.h; do \
      url="https://android.googlesource.com/platform/bionic/+/refs/heads/android12-mainline-release/libc/dns/include/${hdr}?format=TEXT"; \
      curl -fsSL "$url" | base64 -d > "${hdr}" || echo "couldn't fetch ${hdr}, proceeding"; \
    done; \
    # patch dns.c to include resolv.h if it still references resolv_private.h
RUN sed -i 's|#include <resolv_private.h>|#include <resolv.h>|g' /root/php-${PHP_VERSION}/ext/standard/dns.c || true

# -------------------------
# Configure & build PHP (embed)
# -------------------------
WORKDIR /root/build
RUN mkdir -p install

# Configure using NDK clang (explicit path)
RUN set -eux; \
    ../php-${PHP_VERSION}/configure \
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

# Build only CLI/SAPI binary (faster) — adjust if you need more targets
RUN make -j$(nproc) sapi/cli/php

# Copy outputs into an install folder
RUN cp sapi/cli/php install/php.so || cp sapi/cli/php sapi/cli/php || true
RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so install/libsqlite3.so || true

# Copy headers for usage in NDK projects
RUN cp -r /root/php-${PHP_VERSION} install/php-headers

# -------------------------
# Final stage: minimal runtime artifact image
# -------------------------
FROM alpine:3.21
RUN apk update && apk add --no-cache bash

WORKDIR /artifacts

COPY --from=buildsystem /root/build/install/php.so ./php.so
COPY --from=buildsystem /root/build/install/libsqlite3.so ./libsqlite3.so
COPY --from=buildsystem /root/build/install/php-headers ./headers/php

# Useful: print versions on run
CMD ["sh", "-c", "echo built: php.so && ls -la ./ && php -v || true"]
