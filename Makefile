IMAGE_CONFIG ?= config/sequoia-15.6.1.env

.PHONY: doctor validate vanilla base xcode test pull push

doctor:
	IMAGE_CONFIG=$(IMAGE_CONFIG) ./scripts/image doctor

validate:
	IMAGE_CONFIG=$(IMAGE_CONFIG) ./scripts/image validate

vanilla:
	IMAGE_CONFIG=$(IMAGE_CONFIG) ./scripts/image build vanilla

base:
	IMAGE_CONFIG=$(IMAGE_CONFIG) ./scripts/image build base

xcode:
	@test -n "$(XCODE_VERSION)" || (echo "XCODE_VERSION is required" >&2; exit 1)
	IMAGE_CONFIG=$(IMAGE_CONFIG) ./scripts/image build xcode "$(XCODE_VERSION)"

test:
	@test -n "$(VM)" || (echo "VM is required" >&2; exit 1)
	IMAGE_CONFIG=$(IMAGE_CONFIG) ./scripts/image test "$(VM)" "$(PROFILE)"

pull:
	@test -n "$(VARIANT)" || (echo "VARIANT is required" >&2; exit 1)
	IMAGE_CONFIG=$(IMAGE_CONFIG) ./scripts/image pull "$(VARIANT)" "$(TAG)"

push:
	@test -n "$(VARIANT)" || (echo "VARIANT is required" >&2; exit 1)
	IMAGE_CONFIG=$(IMAGE_CONFIG) ./scripts/image push "$(VARIANT)" "$(TAG)"

