SHELL := /bin/bash

MACHINES := luebeck

.PHONY: ignition iso installer image publish check smoke signing-key host-key validate-machine

validate-machine:
	@./scripts/validate-machine.sh "$(MACHINE)"

ignition: validate-machine
	@./scripts/build-ignition.sh "$(MACHINE)"

iso: validate-machine
	@./scripts/build-iso.sh "$(MACHINE)"

installer: ignition iso

image: validate-machine
	@./scripts/build-image.sh "$(MACHINE)"

publish: validate-machine
	@./scripts/publish-image.sh "$(MACHINE)"

check:
	@./scripts/check.sh

smoke: validate-machine
	@./scripts/qemu-smoke.sh "$(MACHINE)" "$(SSH_KEY)"

signing-key:
	@./scripts/generate-signing-key.sh

host-key: validate-machine
	@./scripts/generate-host-key.sh "$(MACHINE)"
