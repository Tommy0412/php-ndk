# Usage: make DESTDIR=/binary/installation/path
DESTDIR=./
EABI_PLATFORMS=armv7a
NOABI_PLATFORMS=aarch64 i686 riscv64 x86_64
PLATFORMS=$(EABI_PLATFORMS) $(NOABI_PLATFORMS)
INSTALL_PLATFORMS=$(foreach platform,$(PLATFORMS),install-$(platform))
LIBDIR_PATH=app/src/main/jniLibs/
armv7a_LIBDIR=armeabi-v7a
aarch64_LIBDIR=arm64-v8a
i686_LIBDIR=x86
x86_64_LIBDIR=x86_64
riscv64_LIBDIR=riscv64
LIBDIRS=armv7a_LIBDIR aarch64_LIBDIR
ENABLED_PLATFORMS=armv7a aarch64
ENABLES_INSTALLS=$(foreach platform,$(ENABLED_PLATFORMS),install-$(platform))

PHP_VERSION=8.4.2
PATCHLEVEL=1
API_LEVEL=32
IMAGE_NAME=php-ndk

all: $(ENABLED_PLATFORMS)
install: $(ENABLES_INSTALLS)

$(EABI_PLATFORMS):
	docker build --build-arg=TARGET=$@-linux-androideabi$(API_LEVEL) --build-arg=LIBDIR=$($@_LIBDIR) -t $(IMAGE_NAME):$(PHP_VERSION)-$@-api$(API_LEVEL)-$(PATCHLEVEL) .

$(NOABI_PLATFORMS):
	docker build --build-arg=TARGET=$@-linux-android$(API_LEVEL) --build-arg=LIBDIR=$($@_LIBDIR) -t $(IMAGE_NAME):$(PHP_VERSION)-$@-api$(API_LEVEL)-$(PATCHLEVEL) .

$(INSTALL_PLATFORMS):
	$(eval CONTAINER=$(shell docker create $(IMAGE_NAME):$(PHP_VERSION)-$(subst install-,,$@)-api$(API_LEVEL)-$(PATCHLEVEL) /dummy))
	docker cp $(CONTAINER):/app $(DESTDIR)
	docker rm -f $(CONTAINER)

.PHONY: $(PLATFORMS) install-$(PLATFORMS)
