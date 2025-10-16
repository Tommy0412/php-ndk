FROM alpine:3.21 AS buildsystem

# Install dependencies
RUN apk update && apk add --no-cache \
    wget unzip gcompat libgcc bash patch make curl build-base \
    git linux-headers cmake pkgconfig automake autoconf libtool

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
ARG API=32
ARG PHP_VERSION=8.4.2
ENV SQLITE3_VERSION=3470200

# Set up toolchain variables
ENV CC=${TARGET}${API}-clang
ENV CXX=${TARGET}${API}-clang++
ENV AR=llvm-ar
ENV RANLIB=llvm-ranlib
ENV STRIP=llvm-strip
ENV TOOLCHAIN=${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64
ENV SYSROOT=${TOOLCHAIN}/sysroot

# Build OpenSSL for Android - FINAL WORKING VERSION
WORKDIR /root
RUN wget https://www.openssl.org/source/openssl-1.1.1w.tar.gz && \
    tar -xzf openssl-1.1.1w.tar.gz
WORKDIR /root/openssl-1.1.1w

RUN ANDROID_NDK_HOME="/opt/android-ndk-r27c" ./Configure android-arm64 \
    -D__ANDROID_API__=21 \
    --prefix=/root/openssl-install \
    shared \
    no-asm \
    no-comp \
    no-hw \
    no-engine && \
    make -j4 && \
    make install_sw

# Build cURL for Android
WORKDIR /root
RUN wget https://curl.se/download/curl-8.13.0.tar.gz && \
    tar -xzf curl-8.13.0.tar.gz
WORKDIR /root/curl-8.13.0

RUN ./configure \
    --host=${TARGET} \
    --target=${TARGET} \
    --with-ssl=/root/openssl-install \
    --prefix=/root/curl-install \
    --enable-shared \
    --disable-static \
    --disable-verbose \
    --enable-ipv6 \
    --disable-manual \
    --without-libidn2 \
    --without-librtmp \
    --without-brotli \
    --without-zstd \
    --without-libpsl \
    CPPFLAGS="-I${SYSROOT}/usr/include -fPIC" \
    LDFLAGS="-L/root/openssl-install/lib" && \
    make -j7 && \
    make install

# Download and build SQLite
WORKDIR /root
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip
WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
RUN ${CC} -o libsqlite3.so -shared -fPIC sqlite3.c

# Download PHP source
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

# Apply patches
COPY *.patch /root/
WORKDIR /root/php-${PHP_VERSION}
RUN for patch in ../*.patch; do [ -f "$patch" ] && patch -p1 < "$patch" || true; done

# Prepare build directories
WORKDIR /root

# Install required dependencies BEFORE running ./configure
RUN apk add --no-cache \
    libxml2-dev \
    pkgconfig \
    build-base
RUN mkdir -p build install
WORKDIR /root/build

RUN PKG_CONFIG_PATH="/root/openssl-install/lib/pkgconfig:/root/curl-install/lib/pkgconfig:${PKG_CONFIG_PATH}" \
  OPENSSL_CFLAGS="-I/root/openssl-install/include" \
  OPENSSL_LIBS="-L/root/openssl-install/lib -lssl -lcrypto" \
  CURL_CFLAGS="-I/root/curl-install/include" \
  CURL_LIBS="-L/root/curl-install/lib -lcurl" \
  ../php-${PHP_VERSION}/configure \
  --host=${TARGET} \
  --target=${TARGET} \
  --prefix=/root/php-android-output \
  --enable-embed=shared \
  --disable-cli \
  --disable-cgi \
  --disable-fpm \
  --without-pear \
  --disable-phar \
  --with-sqlite3 \
  --with-pdo-sqlite \
  --with-openssl=/root/openssl-install \
  --with-curl=/root/curl-install \
  --enable-mbstring \
  --enable-bcmath \
  --enable-filter \
  --enable-pcntl \
  CC=${CC} \
  CXX=${CXX} \
  CFLAGS="-DANDROID -fPIE -fPIC \
          -I/root/sqlite-amalgamation-${SQLITE3_VERSION} \
          -I/root/openssl-install/include \
          -I/root/curl-install/include \
          -I${SYSROOT}/usr/include" \
  LDFLAGS="-pie -shared \
           -L/root/sqlite-amalgamation-${SQLITE3_VERSION} \
           -L/root/openssl-install/lib \
           -L/root/curl-install/lib \
           -L${SYSROOT}/usr/lib/${TARGET}/${API}"

# Build and install PHP with embed SAPI
RUN make -j7 && make install

# Copy the compiled libraries
RUN cp /root/php-android-output/lib/libphp.so /root/install/
RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so /root/install/
RUN cp /root/openssl-install/lib/libssl.so.1.1 /root/install/
RUN cp /root/openssl-install/lib/libcrypto.so.1.1 /root/install/
RUN cp /root/curl-install/lib/libcurl.so.4 /root/install/

# --- FINAL STAGE ---
FROM alpine:3.21

# Copy all artifacts
COPY --from=buildsystem /root/install/ /artifacts/
COPY --from=buildsystem /root/build/ /artifacts/headers/php-build/
COPY --from=buildsystem /root/php-8.4.2/ /artifacts/headers/php-source/

WORKDIR /artifacts
