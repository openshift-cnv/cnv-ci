#!/usr/bin/env bash

echo "Boostrapping cluster"
unset NAMESPACE
sleep 3600
oc apply -f ./cnv-imagestreams.yaml