#   make image           1: Build CentOS Stream 10 disk image with kiwi
#   make flash-artifacts 2: Extract EFI + rootfs from raw disk image
#   make flash           3: Assemble per-board flash packages (default)

SHELL := /bin/bash

ARCH     ?= aarch64

BUILD_OUTPUT ?= build/output
BUILD_LOGS   ?= build/logs

# Kiwi profile: console (headless, default) or gnome (GNOME desktop)
KIWI_PROFILE     ?= console

# Optional: extra kiwi-ng flags
EXTRA_KIWI_OPTS ?=

# Directory for custom kernel RPMs (populated before 'make image')
KIWI_PACKAGES_DIR ?= packages

# Directory of CentOS spec "overlays" rebuilt into KIWI_PACKAGES_DIR before
# the local repo is indexed. Empty/absent = no overlays (clean no-op).
OVERLAY_DIR      ?= overlay
# Container image used to rebuild overlay RPMs (qcom-rpm-utils rpm-builder).
RPM_BUILDER_IMAGE ?=

ARTIFACTDIR      ?= build/out
TARGET_BOARDS    ?= qcs6490-rb3gen2
# Set USE_FIT_IMAGE=0 to use single-DTB mode instead of FIT multi-DTB
USE_FIT_IMAGE    ?= 1
EXTRA_FLASH_OPTS ?=

export ARTIFACTDIR

IMAGE_RAW    := $(BUILD_OUTPUT)/image.raw
FLASHIMAGES  := $(BUILD_OUTPUT)/flashimages
EFI_BIN      := $(FLASHIMAGES)/efi.bin
ROOTFS_IMG   := $(FLASHIMAGES)/rootfs.img
DTBS_TAR     := $(FLASHIMAGES)/dtbs.tar.gz

.PHONY: all image overlays dtbs flash-artifacts flash clean clean-cache clean-downloads clean-overlays help

all: flash

# Overlay packages: each $(OVERLAY_DIR)/<pkg>/ with an overlay.conf carries a
# diff against a CentOS spec, rebuilt into $(KIWI_PACKAGES_DIR) before indexing.
OVERLAY_PKGS := $(wildcard $(OVERLAY_DIR)/*/overlay.conf)

# Rebuild + stage any spec overlays into the local package dir. Clean no-op
# when $(OVERLAY_DIR) has no package directories.
overlays:
	OVERLAY_DIR="$(OVERLAY_DIR)" \
	PACKAGES_DIR="$(KIWI_PACKAGES_DIR)" \
	$(if $(RPM_BUILDER_IMAGE),RPM_BUILDER_IMAGE="$(RPM_BUILDER_IMAGE)",) \
	  scripts/build_overlay_rpms.sh

# When overlays exist, build+stage them before the repo index so freshly
# rebuilt RPMs are always picked up (forces a refresh each run). When none
# exist, the index keeps its normal incremental behavior.
ifneq ($(OVERLAY_PKGS),)
$(KIWI_PACKAGES_DIR)/repodata: overlays
endif

# Build (or refresh) the local RPM-MD repository index.
$(KIWI_PACKAGES_DIR)/repodata: $(wildcard $(KIWI_PACKAGES_DIR)/*.rpm)
	createrepo_c $(KIWI_PACKAGES_DIR)/

$(IMAGE_RAW): kiwi/config.xml $(KIWI_PACKAGES_DIR)/repodata
	mkdir -p $(BUILD_OUTPUT) $(BUILD_LOGS)
	sudo kiwi-ng --target-arch $(ARCH) --profile $(KIWI_PROFILE) --type oem system build \
	  --description kiwi/ \
	  --target-dir $(BUILD_OUTPUT) \
	  --add-repo file://$(CURDIR)/$(KIWI_PACKAGES_DIR),rpm-md,local-packages,1 \
	  $(EXTRA_KIWI_OPTS) \
	  2>&1 | tee $(BUILD_LOGS)/build-cs-stream-$(KIWI_PROFILE).log
	@# Rename kiwi output (e.g. centos-stream10-aarch64.aarch64-10.0.0.raw) to image.raw
	@find $(BUILD_OUTPUT) -maxdepth 1 -name "*.raw" ! -name "image.raw" \
	  | head -1 | xargs -I{} mv {} $(IMAGE_RAW) 2>/dev/null || true
	@test -f $(IMAGE_RAW) || { echo "[!] kiwi did not produce $(IMAGE_RAW)"; exit 1; }

image: $(IMAGE_RAW)

dtbs: $(DTBS_TAR)

$(FLASHIMAGES)/.extracted: $(IMAGE_RAW)
	mkdir -p $(FLASHIMAGES)
	sudo scripts/extract_flash_artifacts.sh $< $(FLASHIMAGES)
	@touch $@

$(EFI_BIN) $(ROOTFS_IMG) $(DTBS_TAR): $(FLASHIMAGES)/.extracted

flash-artifacts: $(EFI_BIN) $(ROOTFS_IMG) $(DTBS_TAR)

flash: $(EFI_BIN) $(ROOTFS_IMG) $(DTBS_TAR)
	./scripts/generate_flat_build.sh \
	  --dtbs-tar=$(DTBS_TAR) \
	  --esp-vfat=$(EFI_BIN) \
	  --rootfs-ext4=$(ROOTFS_IMG) \
	  --target-boards=$(TARGET_BOARDS) \
	  --use-fit-image=$(USE_FIT_IMAGE) \
	  $(EXTRA_FLASH_OPTS)

clean:
	rm -rf $(BUILD_OUTPUT) $(ARTIFACTDIR) $(BUILD_LOGS)

# Remove overlay build scratch (SRPMs, exploded specs, rebuilt RPMs).
# Does not touch the tracked overlay/ sources.
clean-overlays:
	rm -rf build/overlay

# Remove the generated repodata index from the local packages directory
clean-cache:
	rm -rf $(KIWI_PACKAGES_DIR)/repodata

# Remove cached boot-binary and CDT downloads
clean-downloads:
	rm -rf downloads/

help:
	@echo "Usage: make [TARGET] [VARIABLE=value ...]"
	@echo ""
	@echo "Build targets:"
	@echo "  image           Step 1: Build CentOS Stream 10 disk image (kiwi)"
	@echo "  overlays        Rebuild CentOS spec overlays into $(KIWI_PACKAGES_DIR) (auto-run by image)"
	@echo "  flash-artifacts Step 2: Extract EFI + rootfs from raw disk image"
	@echo "  flash           Step 3: Assemble per-board flash packages"
	@echo "  all             All steps (default)"
	@echo ""
	@echo "Utility targets:"
	@echo "  clean           Remove build outputs (BUILD_OUTPUT, ARTIFACTDIR, BUILD_LOGS)"
	@echo "  clean-cache     Remove local package repo repodata ($(KIWI_PACKAGES_DIR)/repodata)"
	@echo "  clean-overlays  Remove overlay build scratch (build/overlay)"
	@echo "  clean-downloads Remove cached boot-binary and CDT downloads"
	@echo "  help            Show this help"
	@echo ""
	@echo "Variables (override on command line):"
	@echo "  ARCH               Target architecture for kiwi (default: $(ARCH))"
	@echo "  DTBS_TAR           DTB tarball (auto: $(FLASHIMAGES)/dtbs.tar.gz from rootfs)"
	@echo "  TARGET_BOARDS      Boards to flash (default: $(TARGET_BOARDS))"
	@echo "                     Use 'all' to build all supported boards"
	@echo "  USE_FIT_IMAGE      1 (default) = FIT multi-DTB image (recommended)"
	@echo "                     0           = single-DTB VFAT image"
	@echo "  ARTIFACTDIR        Flash package output directory (default: $(ARTIFACTDIR))"
	@echo "  EXTRA_FLASH_OPTS   Extra flags for generate_flat_build.sh"
	@echo "  EXTRA_KIWI_OPTS    Extra flags for kiwi-ng"
	@echo "  KIWI_PACKAGES_DIR  Directory for custom RPMs (default: $(KIWI_PACKAGES_DIR))"
	@echo "  OVERLAY_DIR        Directory of CentOS spec overlays (default: $(OVERLAY_DIR))"
	@echo "  RPM_BUILDER_IMAGE  Overlay build container (default: qcom-rpm-utils rpm-builder:centos10)"
	@echo "  KIWI_PROFILE       Image profile: console (default) = headless"
	@echo "                                    gnome             = GNOME desktop"
	@echo ""
	@echo "Example: include custom RPMs before 'make image':"
	@echo "  cp work/linux/rpmbuild/RPMS/aarch64/*.rpm $(KIWI_PACKAGES_DIR)/"
	@echo ""
	@echo "Example: build GNOME desktop image:"
	@echo "  make flash KIWI_PROFILE=gnome"
