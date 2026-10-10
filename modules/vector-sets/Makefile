# Compiler settings
CC = cc

CLANG := $(findstring clang,$(shell $(CC) --version 2>/dev/null | head -1))

ifdef SANITIZER
ifeq ($(SANITIZER),address)
	SAN=-fsanitize=address
else
ifeq ($(SANITIZER),undefined)
	SAN=-fsanitize=undefined
	# The Redis module API calls every RedisModule_* symbol through a
	# type-erased (void*-cast) function pointer, which is ABI-safe but trips
	# clang UBSan's -fsanitize=function check. Disable that sub-check (the
	# option/check is clang-only; gcc has no `function` sanitizer for C).
	ifeq ($(CLANG),clang)
		SAN+=-fno-sanitize=function
	endif
else
ifeq ($(SANITIZER),thread)
	SAN=-fsanitize=thread
else
    $(error "unknown sanitizer=${SANITIZER}")
endif
endif
endif
endif

CFLAGS = -O2 -Wall -Wextra -g $(SAN) -std=c11
LDFLAGS = -lm $(SAN)

# Detect OS
uname_S := $(shell sh -c 'uname -s 2>/dev/null || echo not')
uname_M := $(shell sh -c 'uname -m 2>/dev/null || echo not')

# Shared library compile flags for linux / osx
ifeq ($(uname_S),Linux)
	SHOBJ_CFLAGS ?= -W -Wall -fno-common -g -ggdb -std=c11 -O2
	SHOBJ_LDFLAGS ?= -shared
ifneq (,$(findstring armv,$(uname_M)))
	SHOBJ_LDFLAGS += -latomic
endif
ifneq (,$(findstring aarch64,$(uname_M)))
	SHOBJ_LDFLAGS += -latomic
endif
else
	SHOBJ_CFLAGS ?= -W -Wall -dynamic -fno-common -g -ggdb -std=c11 -O3
	SHOBJ_LDFLAGS ?= -bundle -undefined dynamic_lookup
endif

# OS X 11.x doesn't have /usr/lib/libSystem.dylib and needs an explicit setting.
ifeq ($(uname_S),Darwin)
ifeq ("$(wildcard /usr/lib/libSystem.dylib)","")
LIBS = -L /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib -lsystem
endif
endif

.SUFFIXES: .c .so .xo .o

all: vset.so

.c.xo:
	$(CC) -I. $(CFLAGS) $(SHOBJ_CFLAGS) -fPIC -c $< -o $@

vset.xo: ../../src/redismodule.h expr.c

vset.so: vset.xo hnsw.xo vset_config.xo
	$(CC) -o $@ $^ $(SHOBJ_LDFLAGS) $(LIBS) $(SAN) -lc

# Example sources / objects
SRCS = hnsw.c w2v.c vset_config.c
OBJS = $(SRCS:.c=.o)

TARGET = w2v
MODULE = vset.so

# Default target
all: $(TARGET) $(MODULE)

# Example linking rule
$(TARGET): $(OBJS)
	$(CC) $(OBJS) $(LDFLAGS) -o $(TARGET)

# Compilation rule for object files
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

expr-test: expr.c fastjson.c fastjson_test.c
	$(CC) $(CFLAGS) expr.c -o expr-test -DTEST_MAIN -lm

# Clean rule
clean:
	rm -f $(TARGET) $(OBJS) *.xo *.so

# Declare phony targets
.PHONY: all clean
