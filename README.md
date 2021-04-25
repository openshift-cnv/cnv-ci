# cnv-ci

Contains the required files for running cnv builds on openshift-ci.

# version mapping

# How to create a json containing the required json from the UMB message:

```sh
$ jq -r '{ (.index.ocp_version | ltrimstr("v")): { "index_image": .index.index_image, "bundle_version": (.index.added_bundle_images[] | select(. | contains("hco-bundle-registry")) | split(":") | .[1]) } }'
```

## How to update the version mapping with content of message of UMB

```sh
$ cat version-mapping.json
{
  "4.6": {
    "index_image": "registry-proxy.engineering.redhat.com/rh-osbs/iib:1234",
    "bundle_version": "v2.5.0-55"
  },
  "4.7": {
    "index_image": "registry-proxy.engineering.redhat.com/rh-osbs/iib:11111",
    "bundle_version": "v2.6.0-100"
  }
}

$ jq '.' /tmp/message.json
jq '.' /tmp/message.json
{
  "timestamp": "2020-12-03T12:05:13.209513Z",
  "version": "0.1.0",
  "generated_at": "2020-12-03T12:05:13.209513Z",
  "ci": {
    "name": "Container Verification Pipeline",
    "team": "CVP Development Team",
    "doc": "https://docs.engineering.redhat.com/display/CVP/Container+Verification+Pipeline+E2E+Documentation",
    "url": "https://jenkins0-cvp.cloud.paas.psi.redhat.com/job/cvp-brew-operator-bundle-image-trigger/860/",
    "email": "cvp-ops@redhat.com"
  },
  "run": {
    "url": "https://jenkins-cvp-5c79a4e3d70cc51dd4c37805.cloud.paas.psi.redhat.com/job/cvp-redhat-operator-bundle-image-validation-test/171/",
    "log": "https://jenkins-cvp-5c79a4e3d70cc51dd4c37805.cloud.paas.psi.redhat.com/job/cvp-redhat-operator-bundle-image-validation-test/171/console"
  },
  "artifact": {
    "type": "cvp",
    "id": "1399778",
    "component": "cvp-teamcontainernativevirtualization",
    "issuer": "contra/pipeline",
    "brew_build_target": "Undefined Brew Target Name",
    "brew_build_tag": "Undefined Brew Tag Name",
    "nvr": "hco-bundle-registry-container-v2.6.0-304",
    "full_name": "Undefined Artifact Image Full Name",
    "registry_url": "Undefined Artifact Image Registry URL",
    "namespace": "Undefined Artifact Image Namespace",
    "name": "Undefined Artifact Image Name",
    "image_tag": "Undefined Artifact Image Tag",
    "advisory_id": "N/A",
    "scratch": "false"
  },
  "pipeline": {
    "name": "cvp-redhat-operator-bundle-image-validation-test",
    "id": "d505e2c2-c472-487a-8f8b-599c6af81403",
    "status": "running",
    "build": "171"
  },
  "index": {
    "index_image": "registry-proxy.engineering.redhat.com/rh-osbs/iib:29330",
    "added_bundle_images": [
      "registry-proxy.engineering.redhat.com/rh-osbs/container-native-virtualization-hco-bundle-registry:v2.6.0-304"
    ],
    "ocp_version": "v4.7"
  }
}

$ ./hack/update-version-mapping.sh -i version-mapping.json -m /tmp/message.json
$ cat version-mapping.json
{
  "4.6": {
    "index_image": "registry-proxy.engineering.redhat.com/rh-osbs/iib:1234",
    "bundle_version": "v2.5.0-55"
  },
  "4.7": {
    "index_image": "registry-proxy.engineering.redhat.com/rh-osbs/iib:29330",
    "bundle_version": "v2.6.0-306"
  }
}
```
