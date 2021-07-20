#!/bin/bash

CMD=${CMD:-oc}

function RunCmd {
    cmd=$@
    echo "Command: $cmd"
    echo ""
    bash -c "$cmd"
    stat=$?
    if [ "$stat" != "0" ]; then
        echo "Command failed: $cmd Status: $stat"
    fi
}

function ShowOperatorSummary {

    local kind=$1
    local name=$2
    local namespace=$3

    echo ""
    echo "Status of Operator object: kind=$kind name=$name"
    echo ""

    QUERY="{range .status.conditions[*]}{.type}{'\t'}{.status}{'\t'}{.message}{'\n'}{end}" 
    if [ "$namespace" == "." ]; then
        RunCmd "$CMD get $kind $name -o=jsonpath=\"$QUERY\""
    else
        RunCmd "$CMD get $kind $name -n $namespace -o=jsonpath=\"$QUERY\""
    fi
}

cat <<EOF
=================================
     Start of HCO state dump         
=================================

==========================
summary of operator status
==========================

EOF
NAMESPACE_ARG=$1
CNV_NAMESPACE=${NAMESPACE_ARG:-"openshift-cnv"}
echo $1

RunCmd "${CMD} get pods -n ${CNV_NAMESPACE}"
RunCmd "${CMD} get subscription -n ${CNV_NAMESPACE} -o yaml"
RunCmd "${CMD} get deployment/hco-operator -n ${CNV_NAMESPACE} -o yaml"
RunCmd "${CMD} get hyperconvergeds -n ${CNV_NAMESPACE} kubevirt-hyperconverged -o yaml"

ShowOperatorSummary  hyperconvergeds.hco.kubevirt.io kubevirt-hyperconverged ${CNV_NAMESPACE}

RELATED_OBJECTS=`${CMD} get hyperconvergeds.hco.kubevirt.io kubevirt-hyperconverged -n ${CNV_NAMESPACE} -o go-template='{{range .status.relatedObjects }}{{if .namespace }}{{ printf "%s %s %s\n" .kind .name .namespace }}{{ else }}{{ printf "%s %s .\n" .kind .name }}{{ end }}{{ end }}'`

echo "${RELATED_OBJECTS}" | while read line; do 

    fields=( $line )
    kind=${fields[0]} 
    name=${fields[1]} 
    namespace=${fields[2]} 

    if [ "$kind" != "ConfigMap" ]; then
        ShowOperatorSummary $kind $name $namespace
    fi
done

cat <<EOF

======================
ClusterServiceVersions
======================
EOF

RunCmd "${CMD} get clusterserviceversions -n ${CNV_NAMESPACE}"
RunCmd "${CMD} get clusterserviceversions -n ${CNV_NAMESPACE} -o yaml"

cat <<EOF

============
InstallPlans
============
EOF

RunCmd "${CMD} get installplans -n ${CNV_NAMESPACE} -o yaml"

cat <<EOF

==============
OperatorGroups
==============
EOF

RunCmd "${CMD} get operatorgroups -n ${CNV_NAMESPACE} -o yaml"

cat <<EOF

========================
HCO operator related CRD
========================
EOF

echo "${RELATED_OBJECTS}" | while read line; do 

    fields=( $line )
    kind=${fields[0]} 
    name=${fields[1]} 
    namespace=${fields[2]} 

    if [ "$namespace" == "." ]; then
        echo "Related object: kind=$kind name=$name"
        RunCmd "$CMD get $kind $name -o json"
    else
        echo "Related object: kind=$kind name=$name namespace=$namespace"
        RunCmd "$CMD get $kind $name -n $namespace -o json"
    fi
done

cat <<EOF

========
HCO Pods
========

EOF

RunCmd "$CMD get pods -n ${CNV_NAMESPACE} -o json"

cat <<EOF

=================================
HyperConverged Operator pods logs
=================================
EOF

namespace=kubevirt-hyperconverged
RunCmd "$CMD logs -n $namespace -l name=hyperconverged-cluster-operator"

cat <<EOF

=================================
HyperConverged Webhook pods logs
=================================
EOF
RunCmd "$CMD logs -n $namespace -l name=hyperconverged-cluster-webhook"

cat <<EOF

============
Catalog logs
============
EOF

catalog_namespace=openshift-operator-lifecycle-manager
RunCmd "$CMD logs -n $catalog_namespace $($CMD get pods -n $catalog_namespace | grep catalog-operator | head -1 | awk '{ print $1 }')"


cat <<EOF

===============
HCO Deployments
===============

EOF

RunCmd "$CMD get deployments -n ${CNV_NAMESPACE} -o json"

cat <<EOF
===============================
     End of HCO state dump    
===============================
EOF
