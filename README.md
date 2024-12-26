# PHP NDK

PHP distribution ready for bundling into Android apps

# Usage

To build for all tested platforms, simply run `make`, alternatively changing
`DESTDIR` variable to your installation path of choice, like so:

```
make DESTDIR=/some/path
```

It is also possible to build only for selected platform, including untested ones
targeting Android emulators, like:

```
make x86_64 DESTDIR=/installation/path
```
