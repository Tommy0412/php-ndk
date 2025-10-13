# =============================
# Build PHP for Android arm64-v8a
# =============================

FROM alpine:3.21 AS buildsystem

ARG TARGET=aarch64-linux-android
ARG API_LEVEL=32
ARG PHP_VERSION=8.4.2
ENV NDK_VERSION=android-ndk-r27c

WORKDIR /opt

# --- Install tools ---
RUN apk update && apk add --no-cache \
    wget unzip gcompat libgcc bash patch make curl build-base \
    autoconf bison re2c pkgconf libtool flex

# --- Download and extract Android NDK ---
RUN wget https://dl.google.com/android/repository/${NDK_VERSION}-linux.zip && \
    unzip ${NDK_VERSION}-linux.zip && \
    rm ${NDK_VERSION}-linux.zip

# --- Download SQLite amalgamation ---
WORKDIR /root
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-3470200.zip && \
    unzip sqlite-amalgamation-3470200.zip

WORKDIR /root/sqlite-amalgamation-3470200
RUN /opt/${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64/bin/${TARGET}${API_LEVEL}-clang \
    -o libsqlite3.so -shared -fPIC sqlite3.c

# --- Download and extract PHP ---
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

# --- Copy patch files only if they exist ---
RUN mkdir -p /root/patches
# Docker COPY ne podržava wildcard bez fajlova, pa koristimo shell trik
# Ako nema .patch fajlova, kopira prazan fajl umjesto da pukne
COPY . /root/context
RUN sh -c 'find /root/context -maxdepth 1 -type f -name "*.patch" -exec cp {} /root/patches/ \; || true'

# --- Apply patches if exist ---
WORKDIR /root/php-${PHP_VERSION}
RUN for p in /root/patches/*.patch; do \
      if [ -f "$p" ]; then \
        echo "Applying patch: $p"; \
        patch -p1 < "$p"; \
      fi; \
    done

# --- Remove problematic standard extensions ---
RUN rm -f ext/standard/dns.c \
          ext/standard/gettext.c \
          ext/standard/iconv.c \
          ext/standard/pear.c \
          ext/standard/phpdbg.c

# --- Configure and build PHP ---
RUN ./buildconf --force || true && \
    SQLITE_CFLAGS="-I/root/sqlite-amalgamation-3470200" \
    SQLITE_LIBS="-L/root/sqlite-amalgamation-3470200 -lsqlite3" \
    ./configure \
        --host=${TARGET} \
        --target=${TARGET} \
        --disable-all \
        --enable-cli \
        --enable-embed=shared \
        --with-sqlite3 \
        --prefix=/root/build/install && \
    make -j$(nproc) V=1 && \
    make install

# --- Final artifacts ---
WORKDIR /root/build/install
RUN ls -lah

# --- Copy artifacts for extraction in workflow ---
CMD ["ls", "/root/build/install"]
