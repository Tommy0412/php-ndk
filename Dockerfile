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
ARG TARGET=aarch64-linux-android
ARG API=28
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

# Global 16KB Alignment Flag
ENV LDFLAGS_16KB="-Wl,-z,max-page-size=16384"

# 1. Build OpenSSL (Static)
WORKDIR /root
RUN wget https://www.openssl.org/source/openssl-1.1.1w.tar.gz && \
    tar -xzf openssl-1.1.1w.tar.gz
WORKDIR /root/openssl-1.1.1w
RUN ANDROID_NDK_HOME="/opt/android-ndk-r27c" \
    ./Configure android-arm64 \
    -D__ANDROID_API__=${API} \
    -DOPENSSL_NO_EGD \
    --prefix=/root/openssl-install \
    no-shared no-asm no-comp no-hw no-engine && \
    make -j$(nproc) && make install_sw

# 2. Build cURL (Shared, 16KB)
WORKDIR /root
RUN wget https://curl.se/download/curl-8.13.0.tar.gz && \
    tar -xzf curl-8.13.0.tar.gz
WORKDIR /root/curl-8.13.0
RUN ./configure \
    --host=${TARGET} \
    --with-ssl=/root/openssl-install \
    --prefix=/root/curl-install \
    --enable-shared --disable-static \
    --disable-verbose --enable-ipv6 --disable-manual \
    --without-libidn2 --without-librtmp --without-brotli --without-zstd --without-libpsl \
    --with-zlib \
    CPPFLAGS="-I${SYSROOT}/usr/include -fPIC" \
    LDFLAGS="-L/root/openssl-install/lib ${LDFLAGS_16KB}" && \
    make -j$(nproc) && make install

# 3. Build SQLite (Shared, 16KB)
WORKDIR /root
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip
WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
RUN ${CC} -o libsqlite3.so -shared -fPIC ${LDFLAGS_16KB} sqlite3.c

# 4. Build Oniguruma (Shared, 16KB)
WORKDIR /root
RUN wget https://github.com/kkos/oniguruma/releases/download/v6.9.9/onig-6.9.9.tar.gz && \
    tar -xzf onig-6.9.9.tar.gz
WORKDIR /root/onig-6.9.9
RUN ./configure \
    --host=${TARGET} \
    --prefix=/root/onig-install \
    CC=${CC} CFLAGS="-fPIC" \
    LDFLAGS="${LDFLAGS_16KB}" && \
    make -j$(nproc) && make install

# 5. Build libzip (Static, 16KB Alignment via CMake)
WORKDIR /root
ENV LIBZIP_VERSION=1.11.4
RUN curl -LO https://libzip.org/download/libzip-${LIBZIP_VERSION}.tar.gz && \
    tar xzf libzip-${LIBZIP_VERSION}.tar.gz
WORKDIR /root/libzip-${LIBZIP_VERSION}
RUN mkdir build && cd build && \
    cmake .. \
        -DCMAKE_TOOLCHAIN_FILE=${NDK_ROOT}/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-${API} \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/root/libzip-install \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS_16KB}" \
        -DBUILD_SHARED_LIBS=OFF -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF && \
    make -j$(nproc) && make install

# 6. Build libxml2 (Static)
WORKDIR /root
ENV LIBXML2_VERSION=2.9.12
RUN wget https://download.gnome.org/sources/libxml2/2.9/libxml2-${LIBXML2_VERSION}.tar.xz && \
    tar -xJf libxml2-${LIBXML2_VERSION}.tar.xz
WORKDIR /root/libxml2-${LIBXML2_VERSION}
RUN ./configure \
    --host=${TARGET} \
    --prefix=/root/libxml2-install \
    CC=${CC} CFLAGS="-fPIC -I${SYSROOT}/usr/include" \
    LDFLAGS="-L${SYSROOT}/usr/lib/${TARGET}/${API} ${LDFLAGS_16KB}" \
    --without-iconv --without-python --without-lzma --enable-shared=no --enable-static=yes && \
    make -j$(nproc) && make install

# 7. Download and Patch PHP
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz
COPY *.patch /root/
WORKDIR /root/php-${PHP_VERSION}
RUN sed -i '1i#ifdef __ANDROID__\n#define eaccess(path, mode) access(path, mode)\n#endif' ext/posix/posix.c
RUN patch -p1 < ../ext-posix-posix.c.patch || true && \
    patch -p1 < ../ext-standard-php_fopen_wrapper.c.patch || true && \
    patch -p1 < ../main-streams-cast.c.patch || true

# Android DNS and POSIX fixes
RUN { \
    echo '#include "php.h"'; echo '#include "php_ini.h"'; echo '#include "ext/standard/php_dns.h"'; \
    echo '#ifdef __ANDROID__'; echo 'typedef void* dns_handle_t;'; \
    echo 'static inline dns_handle_t dns_open(const char *n) { return NULL; }'; \
    echo 'static inline void dns_free(dns_handle_t h) {}'; \
    echo 'static inline int dns_search(dns_handle_t h, const char *d, int c, int t, unsigned char *a, int al, struct sockaddr *f, socklen_t *fs) { return -1; }'; \
    echo 'PHP_FUNCTION(gethostname) { RETURN_STRING("localhost"); }'; \
    echo '#define ANDROID_DNS_STUB'; echo '#endif'; \
    echo '#ifndef ANDROID_DNS_STUB'; cat ext/standard/dns.c; echo '#endif'; \
} > ext/standard/dns.c.new && mv ext/standard/dns.c.new ext/standard/dns.c
RUN sed -i 's/r = posix_spawn_file_actions_addchdir_np(&factions, cwd);/r = -1;/' ext/standard/proc_open.c
RUN sed -i 's/#define syslog std_syslog/#ifdef __ANDROID__\n#define syslog(...)\n#else\n#define syslog std_syslog\n#endif/' main/php_syslog.c
RUN sed -i '1i#ifdef ANDROID\n#define getloadavg(load, nelem) (-1)\n#endif' ext/standard/basic_functions.c

# 8. Final PHP Build (Bypassing pkg-config entirely)
WORKDIR /root/build
RUN ../php-${PHP_VERSION}/configure \
    --host=${TARGET} \
    --prefix=/root/php-android-output \
    --enable-embed=shared \
    --with-openssl=/root/openssl-install \
    --with-curl=/root/curl-install \
    --with-sqlite3 \
    --with-pdo-sqlite \
    --with-zip \
    --with-libxml \
    --enable-dom \
    --disable-cli --disable-cgi --disable-fpm --disable-posix --without-pear --disable-phar --disable-phpdbg \
    CC=${CC} CXX=${CXX} \
    SQLITE_CFLAGS="-I/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
    SQLITE_LIBS="-lsqlite3 -L/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
    ONIG_CFLAGS="-I/root/onig-install/include" \
    ONIG_LIBS="-L/root/onig-install/lib -lonig" \
    LIBZIP_CFLAGS="-I/root/libzip-install/include" \
    LIBZIP_LIBS="-L/root/libzip-install/lib -lzip" \
    LIBXML2_CFLAGS="-I/root/libxml2-install/include/libxml2" \
    LIBXML2_LIBS="-L/root/libxml2-install/lib -lxml2" \
    CURL_CFLAGS="-I/root/curl-install/include" \
    CURL_LIBS="-L/root/curl-install/lib -lcurl" \
    OPENSSL_CFLAGS="-I/root/openssl-install/include" \
    OPENSSL_LIBS="-L/root/openssl-install/lib -lssl -lcrypto" \
    CFLAGS="-DANDROID -fPIC -I${SYSROOT}/usr/include" \
    LDFLAGS="-shared ${LDFLAGS_16KB} \
         -Wl,--whole-archive /root/openssl-install/lib/libssl.a /root/openssl-install/lib/libcrypto.a -Wl,--no-whole-archive \
         -L/root/sqlite-amalgamation-${SQLITE3_VERSION} -L/root/curl-install/lib -L/root/onig-install/lib \
         -L/root/libzip-install/lib -L/root/libxml2-install/lib -L${SYSROOT}/usr/lib/${TARGET}/${API} \
         -lc -ldl -lz" && \
    make -j$(nproc) && make install

# Prepare Artifacts
RUN mkdir -p /root/install && \
    cp /root/onig-install/lib/libonig.so /root/install/ && \
    cp /root/php-android-output/lib/libphp.so /root/install/ && \
    cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so /root/install/ && \
    cp /root/curl-install/lib/libcurl.so /root/install/

# 16KB Verification Step
RUN for f in /root/install/*.so; do \
      echo "Checking $f alignment..."; \
      readelf -l $f | grep LOAD | awk '{print $NF}' | grep -q "0x4000" || (echo "$f is NOT 16KB aligned!" && exit 1); \
    done

# Final Stage
FROM alpine:3.21
COPY --from=buildsystem /root/install/ /artifacts/
COPY --from=buildsystem /root/php-android-output/include/php/ /artifacts/headers/php/
WORKDIR /artifacts
