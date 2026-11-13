NAME      := ReMini
BUNDLE_ID := local.remini
VERSION   ?= $(shell tr -d '[:space:]' < VERSION)
BUILD     ?= 1

APP      := $(NAME).app
CONTENTS := $(APP)/Contents
BIN      := $(CONTENTS)/MacOS/$(NAME)
PLIST    := $(CONTENTS)/Info.plist
ICON     := $(CONTENTS)/Resources/AppIcon.icns
ZIP      ?= $(NAME)-$(VERSION)-macos-$(shell uname -m).zip

SWIFTC      ?= swiftc
SWIFTFLAGS  ?= -O -swift-version 5
SIGN_ID     ?= -
PREFIX      ?= /Applications

.PHONY: all app run zip test icon install uninstall clean help
.DEFAULT_GOAL := app

all: app ## Same as app

app: .$(NAME).signed ## Build and ad-hoc sign ReMini.app

$(BIN): main.swift
	@mkdir -p $(@D)
	$(SWIFTC) $(SWIFTFLAGS) $< -o $@

$(ICON): AppIcon.icns
	@mkdir -p $(@D)
	cp $< $@

# rebuild the plist when VERSION/BUILD change
$(PLIST): Info.plist.in FORCE
	@mkdir -p $(@D)
	@sed -e 's/@NAME@/$(NAME)/g' -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' \
	     -e 's/@VERSION@/$(VERSION)/g' -e 's/@BUILD@/$(BUILD)/g' $< > $@.tmp
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@

.$(NAME).signed: $(BIN) $(ICON) $(PLIST)
	codesign -s "$(SIGN_ID)" --force $(APP)
	@touch $@
	@echo "built $(APP) $(VERSION) ($(BUILD))"

run: app ## Build and open the app
	open $(APP)

zip: app ## Package the app as a zip (keeps the code signature)
	@rm -f $(ZIP)
	ditto -c -k --sequesterRsrc --keepParent $(APP) $(ZIP)
	shasum -a 256 $(ZIP) > $(ZIP).sha256
	@cat $(ZIP).sha256

test: app ## Static checks of the built bundle
	plutil -lint $(PLIST)
	test -x $(BIN)
	test -f $(ICON)
	otool -L $(BIN) | grep -q AppKit.framework
	otool -L $(BIN) | grep -q WebKit.framework
	codesign --verify --deep --strict --verbose=2 $(APP)

icon: ## Regenerate AppIcon.icns (BASE=base.png to use your own image)
	swift make-icon.swift $(BASE)

install: app ## Copy the app to $(PREFIX)
	ditto $(APP) $(PREFIX)/$(APP)

uninstall: ## Remove the app from $(PREFIX)
	rm -rf $(PREFIX)/$(APP)

clean: ## Remove build outputs
	rm -rf $(APP) .$(NAME).signed $(NAME)-*.zip $(NAME)-*.zip.sha256

help: ## List targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

FORCE:
