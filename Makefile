# --- Config ---
PHP_VERSION=8.4.2
PATCHLEVEL=1
API_LEVEL=32
IMAGE_NAME=php-ndk
DESTDIR=release-package
LIBDIR_PATH=app/src/main/jniLibs

EABI_PLATFORMS=armv7a aarch64
NOABI_PLATFORMS=i686 x86_64 riscv64
PLATFORMS=$(EABI_PLATFORMS) $(NOABI_PLATFORMS)
INSTALL_PLATFORMS=$(foreach platform,$(PLATFORMS),install-$(platform))

armv7a_LIBDIR=armeabi-v7a
aarch64_LIBDIR=arm64-v8a
i686_LIBDIR=x86
x86_64_LIBDIR=x86_64
riscv64_LIBDIR=riscv64

# --- Targets ---
all: $(EABI_PLATFORMS) install

$(EABI_PLATFORMS):
	docker build \
		--build-arg TARGET=$@-linux-androideabi$(API_LEVEL) \
		--build-arg LIBDIR=$($@_LIBDIR) \
		--tag $(IMAGE_NAME):$(PHP_VERSION)-$@-api$(API_LEVEL)-$(PATCHLEVEL) \
		.

$(INSTALL_PLATFORMS):
	$(eval PLATFORM=$(subst install-,,$@))
	$(eval CONTAINER=$(shell docker create $(IMAGE_NAME):$(PHP_VERSION)-$(PLATFORM)-api$(API_LEVEL)-$(PATCHLEVEL) /dummy))
	# Copy binaries into ABI-specific folder
	docker cp $(CONTAINER):/root/install/. $(DESTDIR)/binaries/$($(_LIBDIR))
	# Copy headers only once (armeabi-v7a)
	if [ "$(PLATFORM)" = "armv7a" ]; then \
		docker cp $(CONTAINER):/root/php-$(PHP_VERSION)/. $(DESTDIR)/includes/php; \
	fi
	docker rm -f $(CONTAINER)

.PHONY: all $(PLATFORMS) install-$(PLATFORMS)
