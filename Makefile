.PHONY: help disable_default_catalog_source update_pull_secret set_imagecontentsourcepolicy deploy_cnv upgrade_cnv test_cnv deploy_test upgrade_test

help:
	@echo "Run 'make deploy_test' to deploy and test $CNV_VERSION/$OCP_VERSION on target cluster"
	@echo "Run 'make upgrade_test' to deploy, upgrade and test $CNV_VERSION/$OCP_VERSION on target cluster"
	@echo "Use 'make quicklab' to setup target cluster for quicklab"

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

dump-state:
	./hack/dump-state.sh
