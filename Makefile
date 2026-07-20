SHELL := /usr/bin/bash
.DEFAULT_GOAL := bootstrap

PROFILE ?= tpx1c13
ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg
CHEZMOI_STATE := $(HOME)/.enoshima/chezmoi-state.boltdb
MISE_CONFIG_FILE := $(CURDIR)/home/dot_config/mise/config.toml
export ANSIBLE_CONFIG

.PHONY: audit validate postflight chezmoi-diff ansible-check apply bootstrap \
	vm-preflight vm-smoke vm-converge vm-reboot vm-desktop vm-full vm-clean vm-unit

audit:
	./scripts/capture-state.sh "$(PROFILE)"

validate:
	./scripts/validate.sh

postflight:
	./scripts/postflight.sh

chezmoi-diff:
	install -d -m 0700 "$(dir $(CHEZMOI_STATE))"
	chezmoi --config /dev/null --config-format toml \
		--source "$(CURDIR)" --persistent-state "$(CHEZMOI_STATE)" diff

ansible-check:
	ansible-playbook -K --check --diff \
		-i ansible/inventory/hosts.yml \
		ansible/site.yml --limit "$(PROFILE)"

apply:
	./bootstrap.sh "$(PROFILE)"

bootstrap:
	./bootstrap.sh "$(PROFILE)"

vm-preflight:
	MISE_CONFIG_FILE="$(MISE_CONFIG_FILE)" mise exec -- \
		uv run --locked --project tests/vm enoshima-vm preflight smoke

vm-smoke:
	MISE_CONFIG_FILE="$(MISE_CONFIG_FILE)" mise exec -- \
		uv run --locked --project tests/vm enoshima-vm run smoke

vm-converge:
	MISE_CONFIG_FILE="$(MISE_CONFIG_FILE)" mise exec -- \
		uv run --locked --project tests/vm enoshima-vm run converge

vm-reboot:
	MISE_CONFIG_FILE="$(MISE_CONFIG_FILE)" mise exec -- \
		uv run --locked --project tests/vm enoshima-vm run reboot

vm-desktop:
	MISE_CONFIG_FILE="$(MISE_CONFIG_FILE)" mise exec -- \
		uv run --locked --project tests/vm enoshima-vm run desktop

vm-full: vm-converge vm-desktop

vm-clean:
	MISE_CONFIG_FILE="$(MISE_CONFIG_FILE)" mise exec -- \
		uv run --locked --project tests/vm enoshima-vm clean

vm-unit:
	MISE_CONFIG_FILE="$(MISE_CONFIG_FILE)" mise exec -- \
		uv run --locked --project tests/vm pytest
