########## BUILD PHP ##########
FROM alpine:3.21 as buildsystem

# --- Install core build deps ---
RUN apk update && apk add --no-cache \
    wget unzip gcompat libgcc bash patch make curl pkgconf autoconf automake libtool

WORKDIR /opt
ENV NDK_VERSION=android-ndk-r27c-linux
ENV NDK_ROOT=/opt/android-ndk-r27c

RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip && \
    unzip ${NDK_VERSION}.zip && \
    rm ${NDK_VERSION}.zip

# Add NDK toolchain to PATH
ENV PATH="${PATH}:${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin"

WORKDIR /root

########## CONFIG ##########
ARG TARGET=aarch64-linux-android32
ARG PHP_VERSION=8.4.2
ENV SQLITE3_VERSION=3470200

# --- Build SQLite ---
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip && \
    unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip
WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
RUN ${TARGET}-clang -o libsqlite3.so -shared -fPIC sqlite3.c

# --- Prepare PHP source ---
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

WORKDIR /root/build

# --- Configure PHP ---
RUN \
  SQLITE_CFLAGS="-I/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
  SQLITE_LIBS="-L/root/sqlite-amalgamation-${SQLITE3_VERSION} -lsqlite3" \
  ../php-${PHP_VERSION}/configure \
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

# --- Build and install ---
RUN make -j$(nproc)
RUN make install

########## EXPORT BUILT FILES ##########
WORKDIR /root/install
RUN cp /root/php-android-output/lib/libphp.so /root/install/php.so && \
    cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so /root/install/libsqlite3.so

# --- Copy headers for JNI use ---
FROM alpine:3.21
RUN apk add --no-cache bash
COPY --from=buildsystem /root/install/php.so /artifacts/php.so
COPY --from=buildsystem /root/install/libsqlite3.so /artifacts/libsqlite3.so
COPY --from=buildsystem /root/php-android-output/include/php /artifacts/headers/php
WORKDIR /artifacts
