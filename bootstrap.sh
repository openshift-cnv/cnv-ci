#!/usr/bin/env bash

echo "Boostrapping cluster"
unset NAMESPACE
oc apply -f ./cnv-imagestreams.yaml