# The Deevnet container image factory.
#
# Builds container images FROM SOURCE for software the substrate runs but does
# not write. Its sibling, deevnet-image-factory, bakes OS images with Packer;
# this bakes service images with podman. An OS image is a machine you clone, a
# container image is a service you run.
#
# This is deliberately NOT the builder collection's artifacts role. That role
# PULLS an upstream image and saves it, which is right for minio, postgres,
# pdns and the Omada controller. An image here exists because the upstream
# binary cannot simply be pulled - VerneMQ's are EULA-encumbered while its
# source is Apache-2.0 - so the build recipe is the artifact, and it needs a
# commit history of its own.

IMAGE          ?=
ARTIFACTS_ROOT ?= /srv/deevnet-http
REGISTRY       ?= localhost
IMAGE_PREFIX   ?= deevnet-

IMAGE_DIR  = images/$(IMAGE)
VERSION    = $(shell cat $(IMAGE_DIR)/version 2>/dev/null)
TAG        = $(REGISTRY)/$(IMAGE_PREFIX)$(IMAGE):$(VERSION)
TARBALL    = $(IMAGE)-$(VERSION).tar
STAGE_DIR  = $(ARTIFACTS_ROOT)/container-images/$(IMAGE)
COMMIT     = $(shell git describe --always --dirty 2>/dev/null || echo unknown)
BUILT      = $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

IMAGES = $(notdir $(wildcard images/*))

.PHONY: default help list check-image image stage clean

default: help

help:
	@echo "Targets (all take IMAGE=<name>):"
	@echo "  list    the images this factory can build"
	@echo "  image   podman build"
	@echo "  stage   image, then save it under $(ARTIFACTS_ROOT)/container-images/<name> (sudo)"
	@echo "  clean   remove built tarballs"
	@echo ""
	@echo "Images: $(IMAGES)"
	@echo "Example: make stage IMAGE=vernemq"

list:
	@for i in $(IMAGES); do printf "  %-12s %s\n" "$$i" "$$(cat images/$$i/version)"; done

# Guard: every target below needs a real image directory and a version.
check-image:
	@test -n "$(IMAGE)" || { echo "set IMAGE=<name>; one of: $(IMAGES)" >&2; exit 1; }
	@test -d "$(IMAGE_DIR)" || { echo "no such image: $(IMAGE)" >&2; exit 1; }
	@test -n "$(VERSION)" || { echo "$(IMAGE_DIR)/version is missing or empty" >&2; exit 1; }

image: check-image
	podman build \
	  --build-arg VERSION=$(VERSION) \
	  --label org.opencontainers.image.version=$(VERSION) \
	  --label org.opencontainers.image.revision=$(COMMIT) \
	  --label org.opencontainers.image.created=$(BUILT) \
	  -t $(TAG) \
	  -f $(IMAGE_DIR)/Containerfile $(IMAGE_DIR)

# A dirty tree is refused. The version here is UPSTREAM's, not a tag of this
# repository, so the version alone does not say which recipe produced the
# image - the factory commit does, and it is recorded as an OCI label. A staged
# image has to be reproducible from a commit, so an uncommitted recipe is not
# allowed to leave the building.
stage: image
	@case "$(COMMIT)" in *-dirty|unknown) echo "refusing to stage from a dirty or untracked tree ($(COMMIT)); commit first" >&2; exit 1;; esac
	@mkdir -p bin
	@# podman save refuses to write over an existing archive.
	rm -f bin/$(TARBALL)
	podman save -o bin/$(TARBALL) $(TAG)
	sudo install -d -o nginx -g nginx -m 0755 $(STAGE_DIR)
	sudo install -o nginx -g nginx -m 0644 bin/$(TARBALL) $(STAGE_DIR)/$(TARBALL)
	sudo ln -sfn $(TARBALL) $(STAGE_DIR)/$(IMAGE)-latest.tar
	@echo "staged $(STAGE_DIR)/$(TARBALL) from $(COMMIT)"

clean:
	rm -rf bin
