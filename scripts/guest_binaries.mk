# vphone-tier: build
# Compile the only guest binary shipped by the JB runtime. This runs on the
# build machine, where Xcode and the iPhoneOS SDK are allowed.

GUEST_DIR ?= .build/guest
GIT_HASH ?= unknown

.PHONY: guest_binaries guest_binaries_clean

guest_binaries: $(GUEST_DIR)/vphoned
	@echo "  guest daemon → $(GUEST_DIR)/vphoned"

$(GUEST_DIR):
	@mkdir -p $(GUEST_DIR)

$(GUEST_DIR)/vphoned: $(wildcard scripts/vphoned/*.m) $(wildcard scripts/vphoned/*.h) | $(GUEST_DIR)
	@xcrun --sdk iphoneos --show-sdk-path >/dev/null || (echo "Error: iPhoneOS SDK is required on the build machine" >&2; exit 1)
	@$(MAKE) --no-print-directory -C scripts/vphoned GIT_HASH=$(GIT_HASH)
	@cp -f scripts/vphoned/vphoned $@

guest_binaries_clean:
	@rm -rf $(GUEST_DIR)
	@$(MAKE) --no-print-directory -C scripts/vphoned clean
