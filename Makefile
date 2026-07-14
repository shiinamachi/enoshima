SHELL := /usr/bin/bash
.DEFAULT_GOAL := bootstrap

PROFILE ?= tpx1c13
ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg
CHEZMOI_STATE := $(HOME)/.my-arch-configurations/chezmoi-state.boltdb
export ANSIBLE_CONFIG

.PHONY: audit validate postflight chezmoi-diff ansible-check apply bootstrap

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
