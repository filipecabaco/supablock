# Modified for supablock. Picks a FUSE userspace API automatically:
#
#   * libfuse3 (Linux default) when pkg-config finds `fuse3`
#   * the libfuse 2.9 API otherwise — that is what macFUSE and FUSE-T
#     provide on macOS (pkg-config names `fuse` and `fuse-t`)
#
# On Linux the port links libfuse3 STATICALLY whenever the static archive is
# available, so the shipped binary needs no libfuse package on the target
# machine — only the (universally present) kernel module, plus fusermount3
# for non-root mounts. macOS always links dynamically: the dylib is part of
# the macFUSE/FUSE-T install the user needs anyway (kernel side included).
#
# Overrides:
#   SUPABLOCK_FUSE_API=2|3       force an API generation
#   SUPABLOCK_STATIC_FUSE=0|1    disable/force static linking

UNAME_S := $(shell uname -s)

PKGS_3 := fuse3
PKGS_2 := $(shell pkg-config --exists fuse && echo fuse || (pkg-config --exists fuse-t && echo fuse-t))

ifeq ($(SUPABLOCK_FUSE_API),2)
  FUSE_PKG := $(PKGS_2)
  API_DEFS := -DSUPABLOCK_FUSE2
else ifeq ($(SUPABLOCK_FUSE_API),3)
  FUSE_PKG := fuse3
  API_DEFS :=
else ifeq ($(UNAME_S),Darwin)
  # Always the 2.9 API on macOS. Recent macFUSE also ships a "fuse3" pc
  # file, but its fuse3 flavour uses Darwin-specific types
  # (struct fuse_darwin_attr, fuse_darwin_fill_dir_t) that portable
  # libfuse3 code cannot compile against — the 2.9 API is the one both
  # macFUSE and FUSE-T implement compatibly.
  FUSE_PKG := $(PKGS_2)
  API_DEFS := -DSUPABLOCK_FUSE2
else ifeq ($(shell pkg-config --exists fuse3 && echo yes),yes)
  FUSE_PKG := fuse3
  API_DEFS :=
else
  FUSE_PKG := $(PKGS_2)
  API_DEFS := -DSUPABLOCK_FUSE2
endif

ifeq ($(strip $(FUSE_PKG)),)
  $(error No FUSE userspace library found. Linux: apt install libfuse3-dev pkg-config; \
macOS: install macFUSE (https://macfuse.github.io) or FUSE-T (https://www.fuse-t.org))
endif

FUSE_CFLAGS := $(shell pkg-config --cflags $(FUSE_PKG))
FUSE_LIBDIR := $(shell pkg-config --variable=libdir $(FUSE_PKG))
FUSE_ARCHIVE := $(FUSE_LIBDIR)/lib$(FUSE_PKG).a

ifeq ($(SUPABLOCK_STATIC_FUSE),0)
  WANT_STATIC := no
else ifeq ($(SUPABLOCK_STATIC_FUSE),1)
  WANT_STATIC := yes
else ifeq ($(UNAME_S),Linux)
  # Default: static when the archive exists (portable single binary).
  WANT_STATIC := $(shell test -f $(FUSE_ARCHIVE) && echo yes || echo no)
else
  WANT_STATIC := no
endif

ifeq ($(WANT_STATIC),yes)
  # Link the archive directly so everything else stays dynamic.
  FUSE_LIBS := $(FUSE_ARCHIVE)
else
  FUSE_LIBS := $(shell pkg-config --libs $(FUSE_PKG))
endif

ifeq ($(UNAME_S),Darwin)
  API_DEFS += -D_DARWIN_USE_64_BIT_INODE
endif

all: efuse

efuse: efuse.c efuse_defs.h
	$(CC) -Wall -std=gnu11 -O2 -D_FILE_OFFSET_BITS=64 $(API_DEFS) $(FUSE_CFLAGS) efuse.c $(FUSE_LIBS) -pthread -o efuse
	mkdir -p ../priv
	cp efuse ../priv/

clean:
	rm -f efuse.o efuse.d efuse ../priv/efuse
