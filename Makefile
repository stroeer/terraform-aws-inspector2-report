DESCRIBE           := $(shell git fetch --all > /dev/null && git describe --match "v*" --always --tags)
DESCRIBE_PARTS     := $(subst -, ,$(DESCRIBE))
# 'v0.2.0'
VERSION_TAG        := $(word 1,$(DESCRIBE_PARTS))
# '0.2.0'
VERSION            := $(subst v,,$(VERSION_TAG))
# '0 2 0'
VERSION_PARTS      := $(subst ., ,$(VERSION))

MAJOR              := $(word 1,$(VERSION_PARTS))
MINOR              := $(word 2,$(VERSION_PARTS))
PATCH              := $(word 3,$(VERSION_PARTS))

BUMP ?= patch
ifeq ($(BUMP), major)
NEXT_VERSION		:= $(shell echo $$(($(MAJOR)+1)).0.0)
else ifeq ($(BUMP), minor)
NEXT_VERSION		:= $(shell echo $(MAJOR).$$(($(MINOR)+1)).0)
else
NEXT_VERSION		:= $(shell echo $(MAJOR).$(MINOR).$$(($(PATCH)+1)))
endif
NEXT_TAG 			:= v$(NEXT_VERSION)

STACKS = $(shell find . -not -path "*/\.*" -iname "*.tf" | sed -E "s|/[^/]+$$||" | sort --unique)
ROOT_DIR := $(shell pwd)

all: fmt validate tfsec tflint

init: ## Initialize a Terraform working directory
	@echo "+ $@"
	@terraform init -backend=false > /dev/null

.PHONY: fmt
fmt: ## Checks config files against canonical format
	@echo "+ $@"
	@terraform fmt -check=true -recursive

.PHONY: validate
validate: ## Validates the Terraform files
	@echo "+ $@"
	@for s in $(STACKS); do \
		echo "validating $$s"; \
		terraform -chdir=$$s init -backend=false > /dev/null; \
		terraform -chdir=$$s validate || exit 1 ;\
    done;

.PHONY: tflint
tflint: ## Runs tflint on all Terraform files
	@echo "+ $@"
	@tflint --init
	@for s in $(STACKS); do \
		echo "tflint $$s"; \
		terraform -chdir=$$s init -backend=false -lockfile=readonly > /dev/null; \
		tflint --chdir=$$s --format=compact --config=$(ROOT_DIR)/.tflint.hcl || exit 1;\
	done;

.PHONY: tfsec
tfsec: ## Runs tfsec on all Terraform files
	@echo "+ $@"
	@for s in $(STACKS); do \
		echo "tfsec $$s"; \
		cd $$s; terraform init -backend=false > /dev/null; \
		tfsec --concise-output --exclude-downloaded-modules --minimum-severity HIGH || exit 1; cd $(ROOT_DIR);\
	done;

bump ::
	@echo bumping version from $(VERSION_TAG) to $(NEXT_TAG)
	@sed -i '' s/$(VERSION)/$(NEXT_VERSION)/g README.md

.PHONY: check-git-clean
check-git-clean:
	@git diff-index --quiet HEAD || (echo "There are uncomitted changes"; exit 1)

.PHONY: check-git-branch
check-git-branch: check-git-clean
	git fetch --all --tags --prune
	git checkout main

release: check-git-branch bump
	git add README.md
	git commit -vsam "Bump version to $(NEXT_TAG)"
	git tag -a $(NEXT_TAG) -m "$(NEXT_TAG)"
	git push origin $(NEXT_TAG)
	git push
	# create GH release if GITHUB_TOKEN is set
	if [ ! -z "${GITHUB_TOKEN}" ] ; then 												\
    	curl 																		\
    		-H "Authorization: token ${GITHUB_TOKEN}" 								\
    		-X POST 																\
    		-H "Accept: application/vnd.github.v3+json"								\
    		https://api.github.com/repos/stroeer/terraform-aws-inspector2-report/releases \
    		-d "{\"tag_name\":\"$(NEXT_TAG)\",\"generate_release_notes\":true}"; 									\
	fi;

help: ## Display this help screen
	@grep -E '^[0-9a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
