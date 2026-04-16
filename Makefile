APP_NAME     = Koffeinum
BUNDLE_ID    = de.posalex.Koffeinum
PROJECT_DIR  = Koffeinum
XCODEPROJ    = $(PROJECT_DIR)/$(APP_NAME).xcodeproj
SCHEME       = $(APP_NAME)
BUILD_DIR    = build
ARCHIVE_PATH = $(BUILD_DIR)/$(APP_NAME).xcarchive
APP_PATH     = $(BUILD_DIR)/$(APP_NAME).app
ZIP_PATH     = $(BUILD_DIR)/$(APP_NAME).zip
INFO_PLIST   = $(PROJECT_DIR)/Resources/Info.plist
TAP_REPO    ?= $(HOME)/git/homebrew-tap
GITHUB_REPO  = posalex/Koffeinum

# Read current version / build number from Info.plist
VERSION      = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $(INFO_PLIST) 2>/dev/null || echo "1.0.0")
BUILD_NUMBER = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleVersion" $(INFO_PLIST) 2>/dev/null || echo "1")

# Signing / notarization (override on the CLI or export in the environment).
# DEVELOPMENT_TEAM : Apple Developer Team ID (e.g. ABCD123456)
# SIGN_IDENTITY    : e.g. "Developer ID Application: Your Name (ABCD123456)"
# NOTARIZE_PROFILE : keychain profile saved via `xcrun notarytool store-credentials`
DEVELOPMENT_TEAM ?=
SIGN_IDENTITY    ?=
NOTARIZE_PROFILE ?=

.PHONY: all build debug clean run archive zip install uninstall version \
        bump-major bump-minor bump-patch bump-build \
        tag release release-signed sign notarize staple \
        publish-tap check-clean help

# ─── Build ───────────────────────────────────────────────────────────────────

all: build

build: ## Build the app (Release)
	xcodebuild -project $(XCODEPROJ) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		CONFIGURATION_BUILD_DIR=$(CURDIR)/$(BUILD_DIR) \
		build

debug: ## Build the app (Debug)
	xcodebuild -project $(XCODEPROJ) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		CONFIGURATION_BUILD_DIR=$(CURDIR)/$(BUILD_DIR) \
		build

clean: ## Clean build artifacts
	rm -rf $(BUILD_DIR)
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) clean 2>/dev/null || true

run: build ## Build and run the app
	open $(APP_PATH)

# ─── Archive & Package ───────────────────────────────────────────────────────

archive: ## Create an Xcode archive
	xcodebuild -project $(XCODEPROJ) \
		-scheme $(SCHEME) \
		-configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		archive

zip: build ## Create a distributable .zip from the built app
	@mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && zip -r -y $(APP_NAME).zip $(APP_NAME).app
	@echo "📦 Created $(ZIP_PATH)"

# ─── Installation ────────────────────────────────────────────────────────────

install: build ## Install to /Applications
	@echo "📲 Installing $(APP_NAME) to /Applications..."
	cp -R $(APP_PATH) /Applications/
	@echo "✅ Installed."

uninstall: ## Remove from /Applications
	@echo "🗑  Removing $(APP_NAME) from /Applications..."
	rm -rf /Applications/$(APP_NAME).app
	@echo "✅ Removed."

# ─── Version Management ─────────────────────────────────────────────────────

version: ## Show current version
	@echo "$(VERSION) (build $(BUILD_NUMBER))"

bump-major: ## Bump major version (X.0.0) — also bumps build number
	@MAJOR=$$(echo $(VERSION) | cut -d. -f1); \
	NEW_VERSION=$$((MAJOR + 1)).0.0; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$NEW_VERSION" $(INFO_PLIST); \
	$(MAKE) -s bump-build; \
	echo "🔖 Version bumped to $$NEW_VERSION"

bump-minor: ## Bump minor version (x.X.0) — also bumps build number
	@MAJOR=$$(echo $(VERSION) | cut -d. -f1); \
	MINOR=$$(echo $(VERSION) | cut -d. -f2); \
	NEW_VERSION=$$MAJOR.$$((MINOR + 1)).0; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$NEW_VERSION" $(INFO_PLIST); \
	$(MAKE) -s bump-build; \
	echo "🔖 Version bumped to $$NEW_VERSION"

bump-patch: ## Bump patch version (x.x.X) — also bumps build number
	@MAJOR=$$(echo $(VERSION) | cut -d. -f1); \
	MINOR=$$(echo $(VERSION) | cut -d. -f2); \
	PATCH=$$(echo $(VERSION) | cut -d. -f3); \
	NEW_VERSION=$$MAJOR.$$MINOR.$$((PATCH + 1)); \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$NEW_VERSION" $(INFO_PLIST); \
	$(MAKE) -s bump-build; \
	echo "🔖 Version bumped to $$NEW_VERSION"

bump-build: ## Bump CFBundleVersion (build number) by 1
	@NEW_BUILD=$$(( $(BUILD_NUMBER) + 1 )); \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$NEW_BUILD" $(INFO_PLIST); \
	echo "🔢 Build number bumped to $$NEW_BUILD"

# ─── Release safety ─────────────────────────────────────────────────────────

check-clean: ## Fail if the working tree is dirty or the current version is already tagged
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "❌ Working tree is dirty. Commit or stash before releasing."; \
		git status --short; \
		exit 1; \
	fi
	@if git rev-parse "v$(VERSION)" >/dev/null 2>&1; then \
		echo "❌ Tag v$(VERSION) already exists. Bump the version first (make bump-patch / bump-minor / bump-major)."; \
		exit 1; \
	fi
	@echo "✅ Working tree is clean and v$(VERSION) is unused."

# ─── Signing & Notarization ─────────────────────────────────────────────────

sign: build ## Codesign the .app with hardened runtime (requires SIGN_IDENTITY)
	@if [ -z "$(SIGN_IDENTITY)" ]; then \
		echo "❌ SIGN_IDENTITY is not set. Example:"; \
		echo '   make sign SIGN_IDENTITY="Developer ID Application: Your Name (ABCD123456)"'; \
		exit 1; \
	fi
	@echo "🔏 Signing $(APP_PATH) with $(SIGN_IDENTITY)..."
	codesign --force --deep --options runtime \
		--entitlements $(PROJECT_DIR)/Resources/Koffeinum.entitlements \
		--sign "$(SIGN_IDENTITY)" \
		$(APP_PATH)
	codesign --verify --deep --strict --verbose=2 $(APP_PATH)
	@echo "✅ Signed."

notarize: zip ## Submit the .zip to Apple notarytool (requires NOTARIZE_PROFILE)
	@if [ -z "$(NOTARIZE_PROFILE)" ]; then \
		echo "❌ NOTARIZE_PROFILE is not set. Create one with:"; \
		echo '   xcrun notarytool store-credentials <profile-name> --apple-id <id> --team-id <team> --password <app-specific-password>'; \
		exit 1; \
	fi
	@echo "📮 Submitting $(ZIP_PATH) to notarytool..."
	xcrun notarytool submit $(ZIP_PATH) \
		--keychain-profile "$(NOTARIZE_PROFILE)" \
		--wait
	@echo "✅ Notarization finished."

staple: ## Staple the notarization ticket to the .app
	xcrun stapler staple $(APP_PATH)
	spctl --assess --verbose=4 --type execute $(APP_PATH)
	@echo "✅ Stapled."

# ─── Release (GitHub) ───────────────────────────────────────────────────────

tag: ## Create a git tag for the current version
	git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	@echo "🏷  Tagged v$(VERSION)"

release: check-clean zip tag ## Create a GitHub release with an (unsigned) .zip asset
	@echo "⚠️  This release is UNSIGNED. End users will see Gatekeeper warnings on first launch."
	@echo "    Use 'make release-signed' if you have a Developer ID configured."
	@echo "🚀 Creating GitHub release v$(VERSION)..."
	gh release create "v$(VERSION)" $(ZIP_PATH) \
		--repo $(GITHUB_REPO) \
		--title "Koffeinum v$(VERSION)" \
		--notes "Release v$(VERSION)" \
		--generate-notes
	@echo "✅ Release v$(VERSION) published."

release-signed: check-clean build sign zip notarize staple ## Sign, notarize, staple, and publish a release
	@echo "🔁 Re-zipping stapled app..."
	rm -f $(ZIP_PATH)
	cd $(BUILD_DIR) && zip -r -y $(APP_NAME).zip $(APP_NAME).app
	$(MAKE) -s tag
	gh release create "v$(VERSION)" $(ZIP_PATH) \
		--repo $(GITHUB_REPO) \
		--title "Koffeinum v$(VERSION)" \
		--notes "Release v$(VERSION)" \
		--generate-notes
	@echo "✅ Signed + notarized release v$(VERSION) published."

# ─── Homebrew Tap ────────────────────────────────────────────────────────────

publish-tap: ## Update Homebrew formula/cask with current version SHA
	@if [ ! -f $(ZIP_PATH) ]; then echo "❌ Run 'make zip' first."; exit 1; fi
	@if [ ! -d "$(TAP_REPO)" ]; then \
		echo "❌ Tap repo not found at $(TAP_REPO)."; \
		echo "   Override with: make publish-tap TAP_REPO=/path/to/homebrew-tap"; \
		exit 1; \
	fi
	@SHA=$$(shasum -a 256 $(ZIP_PATH) | awk '{print $$1}'); \
	URL="https://github.com/$(GITHUB_REPO)/releases/download/v$(VERSION)/$(APP_NAME).zip"; \
	echo "🍺 Updating Homebrew tap at $(TAP_REPO)..."; \
	TARGET=""; \
	if [ -f "$(TAP_REPO)/Casks/koffeinum.rb" ]; then TARGET="$(TAP_REPO)/Casks/koffeinum.rb"; \
	elif [ -f "$(TAP_REPO)/Formula/koffeinum.rb" ]; then TARGET="$(TAP_REPO)/Formula/koffeinum.rb"; \
	else echo "❌ No koffeinum.rb found under Casks/ or Formula/ in $(TAP_REPO)"; exit 1; fi; \
	sed -i '' "s|url \".*\"|url \"$$URL\"|" $$TARGET; \
	sed -i '' "s|sha256 \".*\"|sha256 \"$$SHA\"|" $$TARGET; \
	sed -i '' "s|version \".*\"|version \"$(VERSION)\"|" $$TARGET; \
	echo "✅ Updated $$TARGET: $$URL (sha256: $$SHA)"; \
	echo "   Don't forget to commit and push the tap repo."

# ─── Help ────────────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
