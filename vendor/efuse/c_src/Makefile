# Modified for superblock: build against libfuse3 via pkg-config, drop the
# vestigial (and unused) erl_interface flags that broke on OTP 23+.

FUSE_CFLAGS := $(shell pkg-config --cflags fuse3)
FUSE_LIBS   := $(shell pkg-config --libs fuse3)

all: efuse

efuse: efuse.c efuse_defs.h
	$(CC) -Wall -std=gnu11 -O2 -D_FILE_OFFSET_BITS=64 $(FUSE_CFLAGS) efuse.c $(FUSE_LIBS) -pthread -o efuse
	mkdir -p ../priv
	cp efuse ../priv/

clean:
	rm -f efuse.o efuse.d efuse ../priv/efuse
