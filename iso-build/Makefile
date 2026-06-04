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

.PHONY: help hosts validate iso publish clean
.DEFAULT_GOAL := help

help:
	@echo "bmcctl iso-build — Makefile targets"
	@echo
	@echo "  make hosts                    list configured hosts"
	@echo "  make validate                 shellcheck + bash -n on all scripts"
	@echo "  make iso     HOST=<label>     build out/bmcctl-installer-<label>-*.iso"
	@echo "  make publish HOST=<label>     upload latest <label> ISO to B2 via bbm"
	@echo "  make clean                    remove out/ and per-host work dirs"
	@echo
	@echo "Override B2 destination:"
	@echo "  B2_BUCKET (default $(B2_BUCKET))"
	@echo "  B2_PREFIX (default $(B2_PREFIX))"

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
