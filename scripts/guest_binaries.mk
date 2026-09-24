# vphone-tier: build
# Compile the only guest binary shipped by the JB runtime. This runs on the
# build machine, where Xcode and the iPhoneOS SDK are allowed.

GUEST_DIR ?= .build/guest
GIT_HASH ?= unknown

.PHONY: guest_binaries guest_binaries_clean

guest_binaries: $(GUEST_DIR)/vphoned $(GUEST_DIR)/icli
	@echo "  guest binaries → $(GUEST_DIR)/vphoned, $(GUEST_DIR)/icli"

$(GUEST_DIR):
	@mkdir -p $(GUEST_DIR)

$(GUEST_DIR)/vphoned: $(wildcard scripts/vphoned/*.m) $(wildcard scripts/vphoned/*.h) $(wildcard scripts/vphoned/Swift/*.swift) scripts/vphoned/Package.swift scripts/vphoned/Package.resolved | $(GUEST_DIR)
	@xcrun --sdk iphoneos --show-sdk-path >/dev/null || (echo "Error: iPhoneOS SDK is required on the build machine" >&2; exit 1)
	@$(MAKE) --no-print-directory -C scripts/vphoned GIT_HASH=$(GIT_HASH)
	@cp -f scripts/vphoned/vphoned $@

# The complete icli command surface is available to the guest API without
# reimplementing its command parser or accepting shell text.
$(GUEST_DIR)/icli: $(GUEST_DIR)/vphoned
	@swift build --package-path .build/vphoned-swiftpm/checkouts/icli \
		--scratch-path .build/icli-guest-swiftpm --triple arm64-apple-ios15.0 \
		--sdk "$$(xcrun --sdk iphoneos --show-sdk-path)" -c release --product icli \
		--jobs $(or $(SWIFT_JOBS),4)
	@cp "$$(swift build --package-path .build/vphoned-swiftpm/checkouts/icli \
		--scratch-path .build/icli-guest-swiftpm --triple arm64-apple-ios15.0 \
		--sdk "$$(xcrun --sdk iphoneos --show-sdk-path)" -c release --show-bin-path)/icli" $@

guest_binaries_clean:
	@rm -rf $(GUEST_DIR)
	@$(MAKE) --no-print-directory -C scripts/vphoned clean
