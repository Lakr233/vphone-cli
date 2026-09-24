# vphoned — iOS guest daemon (SwiftNIO + IcliKit + native vphone operations)

SRCS := $(wildcard *.m) $(wildcard *.h) $(wildcard Swift/*.swift) Package.swift Package.resolved
OUT  := vphoned
SDK  := $(shell xcrun --sdk iphoneos --show-sdk-path)
SCRATCH := $(abspath ../../.build/vphoned-swiftpm)
SWIFT_BUILD := swift build --scratch-path $(SCRATCH) --triple arm64-apple-ios15.0 --sdk $(SDK) -c release --product vphoned --jobs $(or $(SWIFT_JOBS),4)

# Passed from parent Makefile
GIT_HASH ?= unknown

.PHONY: all clean

all: $(OUT)

$(OUT): $(SRCS)
	@echo "=== Building vphoned (arm64, iphoneos) ==="
	GIT_HASH=$(GIT_HASH) $(SWIFT_BUILD)
	@cp "$$($(SWIFT_BUILD) --show-bin-path)/vphoned" $@
	@echo "  built OK"

clean:
	rm -f $(OUT)
