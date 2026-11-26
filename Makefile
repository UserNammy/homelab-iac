SHELL := /bin/bash
.DEFAULT_GOAL := help

VENV        ?= .venv
BIN         := $(VENV)/bin
PLAYBOOK    ?= site.yml
VAULT_FILE  := inventory/group_vars/all/vault.yml
# Optional: export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/homelab/vault_pass
VAULT_ARGS  := $(if $(ANSIBLE_VAULT_PASSWORD_FILE),,--ask-vault-pass)
LIMIT       ?=
TAGS        ?=
EXTRA_ARGS  := $(if $(LIMIT),--limit $(LIMIT)) $(if $(TAGS),--tags $(TAGS))

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

$(VENV):
	python3 -m venv $(VENV)

.PHONY: deps
deps: $(VENV) ## Install Python tooling and Ansible collections
	$(BIN)/pip install --upgrade pip
	$(BIN)/pip install -r requirements-dev.txt
	$(BIN)/ansible-galaxy collection install -r requirements.yml

.PHONY: lint
lint: ## Run yamllint and ansible-lint
	$(BIN)/yamllint .
	$(BIN)/ansible-lint

.PHONY: test
test: ## Run the molecule scenario of the common role (needs Docker)
	cd roles/common && ../../$(BIN)/molecule test

.PHONY: ping
ping: ## Check SSH connectivity to every host
	$(BIN)/ansible homelab -m ansible.builtin.ping $(VAULT_ARGS)

.PHONY: check
check: ## Dry run with diff (LIMIT=host TAGS=tag to narrow down)
	$(BIN)/ansible-playbook $(PLAYBOOK) --check --diff $(VAULT_ARGS) $(EXTRA_ARGS)

.PHONY: deploy
deploy: ## Apply the playbook (LIMIT=host TAGS=tag to narrow down)
	$(BIN)/ansible-playbook $(PLAYBOOK) $(VAULT_ARGS) $(EXTRA_ARGS)

.PHONY: vault-init
vault-init: ## Create the vault from the example and encrypt it
	@test ! -f $(VAULT_FILE) || { echo "$(VAULT_FILE) already exists"; exit 1; }
	cp inventory/vault.example.yml $(VAULT_FILE)
	$${EDITOR:-vi} $(VAULT_FILE)
	$(BIN)/ansible-vault encrypt $(VAULT_FILE)

.PHONY: vault-edit
vault-edit: ## Edit the encrypted vault
	$(BIN)/ansible-vault edit $(VAULT_FILE)

.PHONY: vault-check
vault-check: ## Fail if the vault file exists but is not encrypted
	@if [ -f $(VAULT_FILE) ] && ! head -n1 $(VAULT_FILE) | grep -q '^\$$ANSIBLE_VAULT'; then \
		echo "ERROR: $(VAULT_FILE) is not encrypted"; exit 1; \
	else echo "vault OK"; fi

.PHONY: clean
clean: ## Remove caches and molecule leftovers
	rm -rf .cache .ansible
	cd roles/common && ../../$(BIN)/molecule destroy || true
