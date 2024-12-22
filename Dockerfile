FROM alpine:3.21

RUN apk update
RUN apk add wget unzip gcompat libgcc bash

WORKDIR /opt
ENV NDK_VERSION android-ndk-r27c-linux
RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip && unzip ${NDK_VERSION}.zip && rm ${NDK_VERSION}.zip

ENV PATH="$PATH:/opt/android-ndk-r27c/:/opt/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin"

WORKDIR /root

##########
# CONFIG #
##########
ARG TARGET=armv7a-linux-androideabi32

ENV SQLITE3_VERSION 3470200
RUN wget https://www.sqlite.org/2024/sqlite-amalgamation-${SQLITE3_VERSION}.zip
RUN unzip sqlite-amalgamation-${SQLITE3_VERSION}.zip

WORKDIR /root/sqlite-amalgamation-${SQLITE3_VERSION}
RUN ${TARGET}-clang -o libsqlite3.so -shared -fPIC sqlite3.c

WORKDIR /root
ENV PHP_VERSION 8.4.2
RUN wget https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz
RUN tar -xvf php-${PHP_VERSION}.tar.gz

RUN mkdir build install
WORKDIR /root/build
