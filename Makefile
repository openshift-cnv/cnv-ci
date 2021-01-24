.PHONY: help disable_default_catalog_source update_pull_secret set_imagecontentsourcepolicy deploy_cnv upgrade_cnv test_cnv all deploy_test upgrade_test

help:
	@echo "Run 'make all' to test and deploy $CNV_VERSION/$OCP_VERSION on target cluster"
	@echo "Use 'make quicklab' to setup target cluster for quicklab"

# This target is kept around since it's still being referenced in the openshift/release job configuration.
# Once the job configuration is modified to run `make deploy_test`, it can be removed.
all: deploy_cnv

deploy_test: disable_default_catalog_source update_pull_secret set_imagecontentsourcepolicy deploy_cnv test_cnv

upgrade_test: update_pull_secret set_imagecontentsourcepolicy upgrade_cnv test_cnv

disable_default_catalog_source:
	hack/disable-default-catalog-source.sh

update_pull_secret:
	hack/update-pull-secret.sh

set_imagecontentsourcepolicy:
	hack/set-imagecontentsourcepolicy.sh

deploy_cnv:
	hack/deploy-cnv.sh

upgrade_cnv:
	hack/upgrade-cnv.sh

test_cnv:
	hack/patch-hco-pre-test.sh
	hack/test-cnv.sh

quicklab:
	hack/quicklab.sh
