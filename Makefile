IMAGE_CONFIG ?= config/sequoia-15.6.1.env
PROFILE ?= base
SWIFT ?= xcrun swift
CLI = .build/release/macos-image

.PHONY: cli artifact-helper cli-test doctor validate vanilla base xcode test pull push

artifact-helper:
	mkdir -p .build/tools
	go build -trimpath -o .build/tools/image-artifact ./cmd/image-artifact

cli: artifact-helper
	GIT_ALLOW_PROTOCOL=file $(SWIFT) build --disable-keychain --skip-update --disable-automatic-resolution -c release --product macos-image

cli-test:
	GIT_ALLOW_PROTOCOL=file $(SWIFT) test --disable-keychain --skip-update --disable-automatic-resolution

doctor: cli
	IMAGE_CONFIG=$(IMAGE_CONFIG) $(CLI) doctor

validate: cli
	IMAGE_CONFIG=$(IMAGE_CONFIG) $(CLI) validate

vanilla: cli
	IMAGE_CONFIG=$(IMAGE_CONFIG) $(CLI) build vanilla

base: cli
	IMAGE_CONFIG=$(IMAGE_CONFIG) $(CLI) build base

xcode: cli
	@test -n "$(XCODE_VERSION)" || (echo "XCODE_VERSION is required" >&2; exit 1)
	IMAGE_CONFIG=$(IMAGE_CONFIG) $(CLI) build xcode "$(XCODE_VERSION)"

test: cli
	@test -n "$(VM)" || (echo "VM is required" >&2; exit 1)
	IMAGE_CONFIG=$(IMAGE_CONFIG) $(CLI) test "$(VM)" --profile "$(PROFILE)"

pull: cli
	@test -n "$(VARIANT)" || (echo "VARIANT is required" >&2; exit 1)
	IMAGE_CONFIG=$(IMAGE_CONFIG) $(CLI) pull "$(VARIANT)" $(if $(TAG),--tag "$(TAG)")

push: cli
	@test -n "$(VARIANT)" || (echo "VARIANT is required" >&2; exit 1)
	IMAGE_CONFIG=$(IMAGE_CONFIG) $(CLI) push "$(VARIANT)" $(if $(TAG),--tag "$(TAG)")
