SHELL := /bin/bash

MACHINES := luebeck

.PHONY: ignition iso installer check smoke signing-key validate-machine

validate-machine:
	@./scripts/validate-machine.sh "$(MACHINE)"

ignition: validate-machine
	@./scripts/build-ignition.sh "$(MACHINE)"

iso: validate-machine
	@./scripts/build-iso.sh "$(MACHINE)"

installer: ignition iso

check:
	@./scripts/check.sh

smoke: validate-machine
	@./scripts/qemu-smoke.sh "$(MACHINE)" "$(SSH_KEY)"

signing-key:
	@./scripts/generate-signing-key.sh
