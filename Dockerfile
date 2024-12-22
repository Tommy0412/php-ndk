FROM archlinux:latest

RUN pacman-key --init
RUN pacman -Sy archlinux-keyring --noconfirm
RUN pacman -Su --noconfirm
RUN pacman -S --noconfirm wget unzip

WORKDIR /opt
ENV NDK_VERSION android-ndk-r27c-linux
RUN wget https://dl.google.com/android/repository/${NDK_VERSION}.zip && unzip ${NDK_VERSION}.zip && rm ${NDK_VERSION}.zip

ENV PATH="$PATH:/opt/android-ndk-r27c/:android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin"
