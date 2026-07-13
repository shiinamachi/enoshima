SHELL := /usr/bin/bash

PROFILE ?= tpx1c13
ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg
export ANSIBLE_CONFIG

.PHONY: audit validate chezmoi-diff ansible-check apply bootstrap

audit:
	./scripts/capture-state.sh "$(PROFILE)"

validate:
	./scripts/validate.sh

chezmoi-diff:
	chezmoi --source "$(CURDIR)" diff

ansible-check:
	ansible-playbook -K --check --diff \
		-i ansible/inventory/hosts.yml \
		ansible/site.yml --limit "$(PROFILE)"

apply:
	ansible-playbook -K \
		-i ansible/inventory/hosts.yml \
		ansible/site.yml --limit "$(PROFILE)"
	chezmoi --source "$(CURDIR)" diff
	chezmoi --source "$(CURDIR)" apply

bootstrap:
	./bootstrap.sh "$(PROFILE)"
