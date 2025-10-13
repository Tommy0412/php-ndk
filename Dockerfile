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

# --- Copy patch files (optional) ---
RUN mkdir -p /root/patches
# ensure at least one file exists to avoid Docker COPY bug
RUN touch /tmp/noop.patch
COPY *.patch /root/patches/ || true

# --- Apply patches if exist ---
WORKDIR /root/php-${PHP_VERSION}
RUN for p in /root/patches/*.patch; do \
      if [ -f "$p" ]; then \
        echo "Applying patch: $p"; \
        patch -p1 < "$p"; \
      fi; \
    done

# --- Configure and build PHP ---
RUN ./buildconf --force || true && \
    ./configure \
      --host=${TARGET} \
      --target=${TARGET} \
      --disable-all \
      --enable-cli \
      --enable-embed=shared \
      --with-sqlite3=/root/sqlite-amalgamation-3470200 \
      --prefix=/root/build/install && \
    make -j$(nproc) && \
    make install

# --- Final artifacts ---
WORKDIR /root/build/install
RUN ls -lah

# --- Copy artifacts for extraction in workflow ---
CMD ["ls", "/root/build/install"]
