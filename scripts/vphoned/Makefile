# vphoned — iOS guest daemon (cross-compiled for arm64 iphoneos)

SRCS := $(wildcard *.m)
OUT  := vphoned

# Passed from parent Makefile
GIT_HASH ?= unknown

.PHONY: all clean

all: $(OUT) liblaunch_compat.dylib

$(OUT): $(SRCS) $(wildcard *.h)
	@echo "=== Building vphoned (arm64, iphoneos) ==="
	xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
		-I. \
		-Ivendor/libarchive \
		-DVPHONED_BUILD_HASH='"$(GIT_HASH)"' \
		-o $@ $(SRCS) \
		-larchive \
		-framework Foundation \
		-framework Security \
		-framework CoreServices
	@echo "  built OK"

liblaunch_compat.dylib: liblaunch_compat.c
	@echo "=== Building liblaunch_compat.dylib (arm64, iphoneos) ==="
	xcrun -sdk iphoneos clang -arch arm64 -Os -shared \
		-install_name /cores/liblaunch_compat.dylib \
		-o $@ $<
	@echo "  built OK"

clean:
	rm -f $(OUT) liblaunch_compat.dylib
