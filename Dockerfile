FROM alpine:3.21 as buildsystem

RUN apk update
RUN apk add wget unzip gcompat libgcc bash patch make curl

WORKDIR /opt
ENV NDK_VERSION android-ndk-r27c-linux
ENV NDK_ROOT /opt/android-ndk-r27c
RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip && \
    unzip ${NDK_VERSION}.zip && \
    rm ${NDK_VERSION}.zip
# Removed: mv /opt/android-ndk-r27c ${NDK_ROOT} as it was moving the folder onto itself

# CRITICAL FIX: Add the LLVM toolchain bin directory to the PATH
ENV PATH="${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"

WORKDIR /root

##########
# CONFIG #
##########
ARG TARGET=armv7a-linux-androideabi32
ARG PHP_VERSION=8.4.2

ENV SQLITE3_VERSION 3470200
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip
RUN unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip

WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
# This command should now find the compiler due to the fixed PATH
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

WORKDIR /root
RUN mkdir build install
WORKDIR /root/build

# Using CC=$TARGET-clang relies on the fixed PATH
RUN ../php-${PHP_VERSION}/configure \
  --host=${TARGET} \
  --disable-dom \
  --disable-simplexml \
  --disable-xml \
  --disable-xmlreader \
  --disable-xmlwriter \
  --without-pear \
  --without-libxml \
  SQLITE_CFLAGS="-I/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
  SQLITE_LIBS="-lsqlite3 -L/root/sqlite-amalgamation-${SQLITE3_VERSION}" \
  CC=$TARGET-clang \
  --disable-phar \
  --disable-phpdbg \
  --with-sqlite3 \
  --with-pdo-sqlite \
  ;

RUN \
  for hdr in resolv_params.h resolv_private.h resolv_static.h resolv_stats.h; do \
    curl https://android.googlesource.com/platform/bionic/+/refs/heads/android12--mainline-release/libc/dns/include/$hdr?format=TEXT | base64 -d > $hdr; \
  done
RUN make -j7 sapi/cli/php
RUN cp /root/build/sapi/cli/php /root/install/php.so
RUN cp /root/sqlite-amalgamation-${SQLITE3_VERSION}/libsqlite3.so /root/install/libsqlite3.so

FROM scratch
ARG LIBDIR
ENV LIBDIR ${LIBDIR}
COPY --from=buildsystem /root/install/* /app/src/main/jniLibs/${LIBDIR}/
