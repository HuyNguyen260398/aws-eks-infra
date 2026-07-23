.PHONY: terraform-fmt terraform-validate terraform-lint terraform-check yaml-lint helm-check kustomize-check yaml-check verify-prerequisites verify-platform check-drift

TF_ROOTS := bootstrap/terraform-state environments/platform modules/platform_cluster modules/platform_cluster_bootstrap modules/ack_iam_role_selector

terraform-fmt:
	terraform fmt -check -recursive

terraform-validate:
	@for root in $(TF_ROOTS); do \
		if [ -f "$$root/versions.tf" ]; then \
			terraform -chdir=$$root init -backend=false -input=false >/dev/null; \
			terraform -chdir=$$root validate; \
		fi; \
	done

terraform-lint:
	tflint --init
	tflint --recursive --config "$$(pwd)/.tflint.hcl"

terraform-check: terraform-fmt terraform-validate terraform-lint
	checkov -d . --framework terraform --config-file .checkov.yml

yaml-lint:
	yamllint -c .yamllint.yml .

helm-check:
	@if [ -f gitops/platform/charts/namespace-config/Chart.yaml ]; then \
		helm lint gitops/platform/charts/namespace-config -f gitops/platform/charts/namespace-config/values-test.yaml; \
		helm template namespace-config gitops/platform/charts/namespace-config -f gitops/platform/charts/namespace-config/values-test.yaml > /tmp/namespace-config-rendered.yaml; \
		kubeconform -strict -summary -ignore-missing-schemas /tmp/namespace-config-rendered.yaml; \
	fi

kustomize-check:
	@find gitops -name kustomization.yaml -print0 | while IFS= read -r -d '' file; do \
		dir=$$(dirname "$$file"); \
		kubectl kustomize "$$dir" | kubeconform -strict -summary -ignore-missing-schemas; \
	done

yaml-check: yaml-lint helm-check kustomize-check

verify-prerequisites:
	./scripts/verify-prerequisites.sh

verify-platform:
	./scripts/verify-platform.sh

check-drift:
	./scripts/check-drift.sh
