# --- Remove problematic files before buildconf ---
RUN rm -f ext/standard/dns.c \
          ext/standard/gettext.c \
          ext/standard/iconv.c \
          ext/standard/pear.c \
          ext/standard/phpdbg.c

# --- Configure and build PHP ---
RUN ./buildconf --force || true && \
    SQLITE_CFLAGS="-I/root/sqlite-amalgamation-3470200" \
    SQLITE_LIBS="-L/root/sqlite-amalgamation-3470200 -lsqlite3" \
    ./configure \
        --host=${TARGET} \
        --target=${TARGET} \
        --disable-all \
        --enable-cli \
        --enable-embed=shared \
        --with-sqlite3 \
        --prefix=/root/build/install && \
    make -j$(nproc) V=1 && \
    make install
