.PHONY: help disable_default_catalog_source update_pull_secret set_imagecontentsourcepolicy deploy_cnv test_cnv all

help:
	@echo "Run 'make all' to test and deploy $CNV_VERSION/$OCP_VERSION on target cluster"
	@echo "Use 'make quicklab' to setup target cluster for quicklab"

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

quicklab:
	hack/quicklab.sh
