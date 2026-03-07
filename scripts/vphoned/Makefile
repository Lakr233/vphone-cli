# vphoned — iOS guest daemon (cross-compiled for arm64 iphoneos)

SRCS := $(wildcard *.m)
OUT  := vphoned

# Passed from parent Makefile
GIT_HASH ?= unknown

.PHONY: all clean

all: $(OUT)

$(OUT): $(SRCS) $(wildcard *.h)
	@echo "=== Building vphoned (arm64, iphoneos) ==="
	xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
		-I. \
		-DVPHONED_BUILD_HASH='"$(GIT_HASH)"' \
		-o $@ $(SRCS) \
		-framework Foundation \
		-framework Security \
		-framework CoreServices
	@echo "  built OK"

clean:
	rm -f $(OUT)
