# bmcctl iso-build — front-end for build.sh, render-config.sh, and
# the eventual `bmcctl install-arch` end of the pipeline.
#
# Typical flow:
#   make hosts                         # list available host configs
#   cp hosts/example.toml hosts/nas.toml && $EDITOR hosts/nas.toml
#   make iso HOST=nas                  # build out/bmcctl-installer-nas-*.iso
#   make publish HOST=nas              # upload to b2://j4y-bu/iso/ via bbm
#   bmcctl install-arch nas --iso https://...

ISO_BUILD_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OUT_DIR       := $(ISO_BUILD_DIR)/out
HOSTS_DIR     := $(ISO_BUILD_DIR)/hosts

# B2 bucket / key prefix for `make publish`. Override at the CLI:
#   make publish HOST=nas B2_BUCKET=my-bucket B2_PREFIX=installers/
B2_BUCKET ?= j4y-bu
B2_PREFIX ?= iso/

# QEMU smoke-test settings. Override at the CLI:
#   make test HOST=test VM_DISK_SIZE=64G VM_MEMORY=4G VM_CPUS=2
VM_DISK_SIZE ?= 32G
VM_MEMORY    ?= 4G
VM_CPUS      ?= 2

.PHONY: help hosts validate iso publish test test-shell clean clean-test _ovmf-vars
.DEFAULT_GOAL := help

help:
	@echo "bmcctl iso-build — Makefile targets"
	@echo
	@echo "  make hosts                    list configured hosts"
	@echo "  make validate                 shellcheck + bash -n on all scripts"
	@echo "  make iso     HOST=<label>     build out/bmcctl-installer-<label>-*.iso"
	@echo "  make test    HOST=<label>     boot the latest <label> ISO in QEMU on"
	@echo "                                a fresh blank disk; serial console attached"
	@echo "                                so you watch install.sh run live"
	@echo "  make test-shell HOST=<label>  same as test, but with a graphical window"
	@echo "                                in addition to the serial console (handy"
	@echo "                                if the install drops to a TTY login)"
	@echo "  make publish HOST=<label>     upload latest <label> ISO to B2 via bbm"
	@echo "  make clean                    remove out/ and per-host work dirs"
	@echo "  make clean-test               remove the QEMU smoke-test scratch disk"
	@echo
	@echo "Overrides:"
	@echo "  B2_BUCKET     (default $(B2_BUCKET))"
	@echo "  B2_PREFIX     (default $(B2_PREFIX))"
	@echo "  VM_DISK_SIZE  (default $(VM_DISK_SIZE))"
	@echo "  VM_MEMORY     (default $(VM_MEMORY))"
	@echo "  VM_CPUS       (default $(VM_CPUS))"

hosts:
	@echo "Host configs in $(HOSTS_DIR):"
	@ls -1 $(HOSTS_DIR) 2>/dev/null | sed 's/\.toml$$//;s/^/  /' || echo "  (none)"

validate:
	@echo "::: shellcheck"
	@shellcheck \
	    $(ISO_BUILD_DIR)/build.sh \
	    $(ISO_BUILD_DIR)/render-config.sh \
	    $(ISO_BUILD_DIR)/profile/airootfs/root/install.sh \
	    $(ISO_BUILD_DIR)/profile/profiledef.sh
	@echo "::: bash -n"
	@bash -n $(ISO_BUILD_DIR)/profile/airootfs/root/install.sh
	@bash -n $(ISO_BUILD_DIR)/profile/profiledef.sh
	@echo "::: ok"

iso:
ifndef HOST
	$(error HOST is unset. Try:  make iso HOST=nas)
endif
	@$(ISO_BUILD_DIR)/build.sh $(HOST)

publish:
ifndef HOST
	$(error HOST is unset. Try:  make publish HOST=nas)
endif
	@latest=$$(ls -t $(OUT_DIR)/bmcctl-installer-$(HOST)-*x86_64.iso 2>/dev/null | head -n1); \
	 if [[ -z $$latest ]]; then \
	    echo "no ISO for $(HOST) in $(OUT_DIR) — run \`make iso HOST=$(HOST)\` first" >&2; \
	    exit 2; \
	 fi; \
	 echo "::: publishing $$latest -> b2://$(B2_BUCKET)/$(B2_PREFIX)$$(basename $$latest)"; \
	 bbm push --bucket $(B2_BUCKET) --key $(B2_PREFIX)$$(basename $$latest) "$$latest"; \
	 echo "::: published. fetch URL via:"; \
	 echo "    bbm url --bucket $(B2_BUCKET) --key $(B2_PREFIX)$$(basename $$latest)"

clean:
	@rm -rf $(OUT_DIR) $(ISO_BUILD_DIR)/work-*
	@echo "cleaned $(OUT_DIR) and work-* dirs"

clean-test:
	@rm -f $(ISO_BUILD_DIR)/test-disk-*.qcow2 \
	      $(ISO_BUILD_DIR)/test-ovmf-vars-*.fd \
	      $(ISO_BUILD_DIR)/test-ovmf-vars-template.fd
	@echo "removed test-disk-*.qcow2 and test-ovmf-vars-*.fd"

# Create a fresh writable OVMF VARS file. Brew's qemu only ships the
# READ-ONLY edk2-x86_64-code.fd half of the firmware; the writable
# NVRAM half (vars.fd) we have to materialize ourselves. A 4 MB blob
# of zeros works — EDK2 detects it as uninitialized NVRAM on first
# boot and writes a fresh GPT/Boot variable layout into it.
# We make a TEMPLATE here once, then `make test` copies it per-run
# so each VM starts with virgin NVRAM (matching what a freshly
# powered-on real machine would have).
_ovmf-vars: $(ISO_BUILD_DIR)/test-ovmf-vars-template.fd

$(ISO_BUILD_DIR)/test-ovmf-vars-template.fd:
	@dd if=/dev/zero of=$@ bs=1M count=4 status=none
	@echo "created $@ (4 MB writable NVRAM template)"

# `make test` boots the latest ISO for HOST in QEMU on a fresh blank
# disk. Serial console is attached so install.sh's output streams to
# this terminal — closest analogue to what SOL on a real BMC looks like.
#
# Notes:
#   * On Apple Silicon, x86_64 emulation is full-software (TCG); the
#     install will be SLOW (10-30 min vs 2-3 min on a real CPU). That's
#     fine for a smoke test; pacstrap is the bottleneck either way.
#   * We always create a FRESH qcow2 disk, never overwrite one in place,
#     and refuse to attach a real disk. There's no path here that can
#     touch your Mac's filesystem.
#   * The disk filename includes HOST so multiple hosts don't collide.
test: _ovmf-vars
ifndef HOST
	$(error HOST is unset. Try:  make test HOST=test)
endif
	@latest=$$(ls -t $(OUT_DIR)/bmcctl-installer-$(HOST)-*x86_64.iso 2>/dev/null | head -n1); \
	 if [[ -z $$latest ]]; then \
	    echo "no ISO for $(HOST) in $(OUT_DIR) — run \`make iso HOST=$(HOST)\` first" >&2; \
	    exit 2; \
	 fi; \
	 disk=$(ISO_BUILD_DIR)/test-disk-$(HOST).qcow2; \
	 vars=$(ISO_BUILD_DIR)/test-ovmf-vars-$(HOST).fd; \
	 echo "::: ISO  $$latest"; \
	 echo "::: disk $$disk ($(VM_DISK_SIZE), fresh)"; \
	 echo "::: vars $$vars (fresh NVRAM for this run)"; \
	 rm -f $$disk; \
	 qemu-img create -f qcow2 $$disk $(VM_DISK_SIZE) >/dev/null; \
	 cp $(ISO_BUILD_DIR)/test-ovmf-vars-template.fd $$vars; \
	 echo "::: launching qemu (TCG, x86_64, UEFI). install.sh logs to this serial."; \
	 echo "::: Ctrl-A then x to quit qemu. Or close the terminal."; \
	 echo; \
	 qemu-system-x86_64 \
	   -name "bmcctl-installer-$(HOST)" \
	   -machine q35 -accel tcg \
	   -cpu max -smp $(VM_CPUS) -m $(VM_MEMORY) \
	   -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
	   -drive if=pflash,format=raw,file=$$vars \
	   -drive file=$$disk,format=qcow2,if=virtio \
	   -drive file=$$latest,media=cdrom,if=none,id=cd0,readonly=on \
	   -device virtio-scsi-pci,id=scsi0 \
	   -device scsi-cd,drive=cd0,bus=scsi0.0 \
	   -boot d \
	   -nic user,model=virtio-net-pci \
	   -nographic

# `make test-shell` is `make test` with a graphical display attached
# in addition to the serial console. Useful if the install drops to
# a tty1 login because something failed — you can see the framebuffer.
test-shell: _ovmf-vars
ifndef HOST
	$(error HOST is unset. Try:  make test-shell HOST=test)
endif
	@latest=$$(ls -t $(OUT_DIR)/bmcctl-installer-$(HOST)-*x86_64.iso 2>/dev/null | head -n1); \
	 if [[ -z $$latest ]]; then \
	    echo "no ISO for $(HOST) in $(OUT_DIR) — run \`make iso HOST=$(HOST)\` first" >&2; \
	    exit 2; \
	 fi; \
	 disk=$(ISO_BUILD_DIR)/test-disk-$(HOST).qcow2; \
	 vars=$(ISO_BUILD_DIR)/test-ovmf-vars-$(HOST).fd; \
	 rm -f $$disk; \
	 qemu-img create -f qcow2 $$disk $(VM_DISK_SIZE) >/dev/null; \
	 cp $(ISO_BUILD_DIR)/test-ovmf-vars-template.fd $$vars; \
	 qemu-system-x86_64 \
	   -name "bmcctl-installer-$(HOST)" \
	   -machine q35 -accel tcg \
	   -cpu max -smp $(VM_CPUS) -m $(VM_MEMORY) \
	   -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
	   -drive if=pflash,format=raw,file=$$vars \
	   -drive file=$$disk,format=qcow2,if=virtio \
	   -drive file=$$latest,media=cdrom,if=none,id=cd0,readonly=on \
	   -device virtio-scsi-pci,id=scsi0 \
	   -device scsi-cd,drive=cd0,bus=scsi0.0 \
	   -boot d \
	   -nic user,model=virtio-net-pci \
	   -serial stdio
