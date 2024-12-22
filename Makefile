EABI_PLATFORMS=aarch64 armv7a
NOABI_PLATFORMS=i686 riscv64 x86_64
PLATFORMS=$(EABI_PLATFORMS) $(NOABI_PLATFORMS)
DESTDIR=./

PHP_VERSION=8.4.2
PATCHLEVEL=1
API_LEVEL=32
IMAGE_NAME=php-ndk

all: aarch64 armv7a

$(EABI_PLATFORMS):
	docker build --build-arg=TARGET=$@-linux-androideabi$(API_LEVEL) -t $(IMAGE_NAME):$(PHP_VERSION)-$@-api$(API_LEVEL)-$(PATCHLEVEL) .
	$(eval CONTAINER=$(shell docker create $(IMAGE_NAME):$(PHP_VERSION)-$@-api$(API_LEVEL)-$(PATCHLEVEL) /dummy))
	docker cp $(CONTAINER):/app $(DESTDIR)
	docker rm -f $(CONTAINER)

$(NOABI_PLATFORMS):
	docker build --build-arg=TARGET=$@-linux-android$(API_LEVEL) -t $(IMAGE_NAME):$(PHP_VERSION)-$@-api$(API_LEVEL)-$(PATCHLEVEL) .
	$(eval CONTAINER=$(shell docker create $(IMAGE_NAME):$(PHP_VERSION)-$@-api$(API_LEVEL)-$(PATCHLEVEL) /dummy))
	docker cp $(CONTAINER):/app $(DESTDIR)
	docker rm -f $(CONTAINER)
