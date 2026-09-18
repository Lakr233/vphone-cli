# libvcamcaptured — dylib loaded into cameracaptured via LC_LOAD_DYLIB

SRCS := $(wildcard *.m) ../vcamshared/vcam_dataplane.c
OUT  := libvcamcaptured.dylib

.PHONY: all clean

all: $(OUT)

$(OUT): $(SRCS) $(wildcard *.h) ../vcamshared/vcam_dataplane.h
	@echo "=== Building libvcamcaptured (arm64e, iphoneos, dylib) ==="
	xcrun -sdk iphoneos clang -arch arm64e -Os -fobjc-arc \
		-miphoneos-version-min=15.0 \
		-dynamiclib \
		-install_name /var/jb/usr/lib/libvcamcaptured.dylib \
		-I. \
		-o $@ $(SRCS) \
		-framework Foundation \
		-framework CoreMedia \
		-framework CoreVideo \
		-framework CoreGraphics
	@echo "  built OK ($$(stat -f%z $(OUT)) bytes)"

clean:
	rm -f $(OUT)
