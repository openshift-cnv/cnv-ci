.PHONY: help disable_default_catalog_source update_pull_secret set_imagecontentsourcepolicy deploy_cnv test_cnv all

help:
	@echo "Run 'make all' to update configuration against the current KUBECONFIG"

all: disable_default_catalog_source update_pull_secret set_imagecontentsourcepolicy deploy_cnv test_cnv

disable_default_catalog_source:
	hack/disable-default-catalog-source.sh

update_pull_secret:
	hack/update-pull-secret.sh

set_imagecontentsourcepolicy:
	hack/set-imagecontentsourcepolicy.sh

deploy_cnv:
	hack/deploy-cnv.sh

test_cnv:
	hack/test-cnv.sh
