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

RUN ANDROID_NDK_HOME="/opt/android-ndk-r27c" \
    ./Configure android-arm64 \
    -D__ANDROID_API__=21 \
    -DOPENSSL_NO_EGD \
    --prefix=/root/openssl-install \
    no-shared \
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
    --with-zlib \
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

# Build Oniguruma for Android
WORKDIR /root
RUN wget https://github.com/kkos/oniguruma/releases/download/v6.9.9/onig-6.9.9.tar.gz && \
    tar -xzf onig-6.9.9.tar.gz
WORKDIR /root/onig-6.9.9

RUN ./configure \
    --host=${TARGET} \
    --prefix=/root/onig-install \
    CC=${CC} \
    CFLAGS="-fPIC" && \
    make -j$(nproc) && \
    make install

# Build libzip for Android
WORKDIR /root
ENV LIBZIP_VERSION=1.11.4
RUN curl -LO https://libzip.org/download/libzip-${LIBZIP_VERSION}.tar.gz \
    && tar xzf libzip-${LIBZIP_VERSION}.tar.gz \
    && rm libzip-${LIBZIP_VERSION}.tar.gz

WORKDIR /root/libzip-${LIBZIP_VERSION}
RUN mkdir build && cd build \
    && cmake .. \
        -DCMAKE_TOOLCHAIN_FILE=/opt/android-ndk-r27c/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-32 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/root/libzip-install \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_EXAMPLES=OFF \
    && make -j7 \
    && make install

# Download PHP source
WORKDIR /root
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xvf php-${PHP_VERSION}.tar.gz

# Apply patches
COPY *.patch /root/
WORKDIR /root/php-${PHP_VERSION}

# Android POSIX fixes
# RUN sed -i '1i#ifdef __ANDROID__\n#define eaccess(path, mode) access(path, mode)\n#endif' /root/php-8.4.2/ext/posix/posix.c

RUN \
patch -p1 < ../gethostname_patch.patch && \
patch -p1 < ../resolv.patch && \
patch -p1 < ../ext-standard-php_fopen_wrapper.c.patch && \
patch -p1 < ../main-streams-cast.c.patch && \
patch -p1 < ../fork.patch \
;    
    
# Apply Android DNS stub
RUN { \
    echo '#ifdef __ANDROID__'; \
    echo '#include <sys/socket.h>'; \
    echo '#include <netinet/in.h>'; \
    echo '#include <sys/types.h>'; \
    echo ''; \
    echo 'typedef void* dns_handle_t;'; \
    echo 'static inline dns_handle_t dns_open(const char *nameserver) { return NULL; }'; \
    echo 'static inline void dns_free(dns_handle_t handle) {}'; \
    echo 'static inline int dns_search(dns_handle_t handle, const char *dname, int class, int type,'; \
    echo '    unsigned char *answer, int anslen, struct sockaddr *from, socklen_t *fromsize) {'; \
    echo '    return -1;'; \
    echo '}'; \
    echo ''; \
    echo '/* Disable the rest of the DNS implementation on Android */'; \
    echo '#define ANDROID_DNS_STUB'; \
    echo '#endif'; \
    echo ''; \
    echo '#ifndef ANDROID_DNS_STUB'; \
    cat ext/standard/dns.c; \
    echo '#endif'; \
} > ext/standard/dns.c.new && mv ext/standard/dns.c.new ext/standard/dns.c

# Patch proc_open.c for Android
RUN sed -i 's/r = posix_spawn_file_actions_addchdir_np(&factions, cwd);/r = -1; \/\/ Android compatibility/' ext/standard/proc_open.c

# syslog patch
RUN sed -i 's/#define syslog std_syslog/#ifdef __ANDROID__\n#define syslog(...)\n#else\n#define syslog std_syslog\n#endif/' main/php_syslog.c

# Prepare build directories
WORKDIR /root
RUN mkdir -p build install
WORKDIR /root/build

# RUN PKG_CONFIG_PATH="/root/onig-install/lib/pkgconfig:/root/openssl-install/lib/pkgconfig:/root/curl-install/lib/pkgconfig" \
RUN PKG_CONFIG_PATH="/root/libzip-install/lib/pkgconfig:/root/onig-install/lib/pkgconfig:/root/openssl-install/lib/pkgconfig:/root/curl-install/lib/pkgconfig" \
  OPENSSL_CFLAGS="-I/root/openssl-install/include" \
  OPENSSL_LIBS="/root/openssl-install/lib/libssl.a /root/openssl-install/lib/libcrypto.a" \
  CURL_CFLAGS="-I/root/curl-install/include" \
  CURL_LIBS="-L/root/curl-install/lib -lcurl" \
  ONIG_CFLAGS="-I/root/onig-install/include" \
  ONIG_LIBS="-L/root/onig-install/lib -lonig" \
  LIBZIP_CFLAGS="-I/root/libzip-install/include" \
  LIBZIP_LIBS="-L/root/libzip-install/lib -lzip" \
  ../php-${PHP_VERSION}/configure \
    --host=${TARGET} \
    --prefix=/root/php-android-output \
    --enable-embed=shared \
    --with-openssl=/root/openssl-install \
    --with-curl=/root/curl-install \
    --with-sqlite3 \
    --with-pdo-sqlite \
    --with-zip \
    --disable-cli \
    --disable-cgi \
    --disable-fpm \
    --disable-dom \
    --disable-simplexml \
    --disable-xml \
    --disable-xmlreader \
    --disable-xmlwriter \
    --disable-posix \
    --disable-random \
    --without-pear \
    --without-libxml \
    --disable-phar \
    --disable-phpdbg \
    --disable-opcache \
    --disable-opcache-jit \
    --disable-pcntl \
    --disable-shmop \
    --disable-sysvshm \
    --disable-sysvsem \
    --disable-sysvmsg \
    CC=${CC} \
    CXX=${CXX} \
    SQLITE_CFLAGS="-I/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
    SQLITE_LIBS="-lsqlite3 -L/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
    CFLAGS="-DOPENSSL_NO_EGD -DRAND_egd\(file\)=0 \
        -DANDROID -fPIE -fPIC \
        -Dexplicit_bzero\(a,b\)=memset\(a,0,b\) \
        -I${SYSROOT}/usr/include \
        -I/root/sqlite-amalgamation-${SQLITE3_VERSION} \
        -I/root/openssl-install/include \
        -I/root/curl-install/include \
        -I/root/onig-install/include" \
    LDFLAGS="-pie -shared \
         -Wl,--whole-archive \
         /root/openssl-install/lib/libssl.a \
         /root/openssl-install/lib/libcrypto.a \
         -Wl,--no-whole-archive \
         -L/root/sqlite-amalgamation-${SQLITE3_VERSION} \
         -L/root/curl-install/lib \
         -L/root/onig-install/lib \
         -L/root/libzip-install/lib \
         -L${SYSROOT}/usr/lib/${TARGET}/${API} \
         -lc -ldl"

# Download missing Android DNS headers
RUN for hdr in resolv_params.h resolv_private.h resolv_static.h resolv_stats.h; do \
      curl https://android.googlesource.com/platform/bionic/+/refs/heads/android12--mainline-release/libc/dns/include/$hdr?format=TEXT | base64 -d > $hdr; \
    done

# Build and install PHP with embed SAPI
# RUN make -j7 && make install

# Copy the compiled libraries
RUN cp /root/onig-install/lib/libonig.so /root/install/
RUN cp /root/php-android-output/lib/libphp.so /root/install/
RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so /root/install/
RUN cp /root/curl-install/lib/libcurl.so /root/install/
# RUN cp /root/openssl-install/lib/libssl.so.1.1 /root/install/
# RUN cp /root/openssl-install/lib/libcrypto.so.1.1 /root/install/

RUN readelf -d /root/install/libphp.so | grep NEEDED
RUN nm -D /root/php-android-output/lib/libphp.so | grep zif_gethostname

# --- FINAL STAGE ---
FROM alpine:3.21

# Copy all artifacts
COPY --from=buildsystem /root/install/ /artifacts/
COPY --from=buildsystem /root/build/ /artifacts/headers/php-build/
COPY --from=buildsystem /root/php-8.4.2/ /artifacts/headers/php-source/
COPY --from=buildsystem /root/php-android-output/include/php/ /artifacts/headers/php/
COPY --from=buildsystem /root/install/libonig.so /artifacts/libonig.so

WORKDIR /artifacts
