SHELL := /bin/bash

.PHONY: fmt fmt-check validate policy-check check

fmt:
	tofu fmt -recursive

fmt-check:
	tofu fmt -check -recursive

validate:
	./scripts/validate.sh

policy-check:
	./scripts/check-policy.sh

check: fmt-check validate policy-check
