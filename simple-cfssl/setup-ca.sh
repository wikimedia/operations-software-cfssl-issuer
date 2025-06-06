#!/bin/bash
# This script sets up a Certificate Authority (CA) and two intermediate CAs to be used with cfssl multirootca.
set -ex

WORKDIR=/cfssl
CONFDIR="${WORKDIR}/config"
# The runtime directory can be mounted to write certificates to a persistent location.
RUNTIMEDIR="${WORKDIR}/runtime"

mkdir -p "${RUNTIMEDIR}"/{ca,intermediate,certs}

# Create the root CA
cd "${RUNTIMEDIR}/ca"
cfssl genkey -initca "${CONFDIR}/ca-csr.json" | cfssljson -bare ca

# Create & sign two intermediates
cd "${RUNTIMEDIR}/intermediate"
for i in 1 2; do
    cfssl genkey -initca "${CONFDIR}/intermediate${i}-csr.json" | cfssljson -bare "intermediate${i}"
    cfssl sign -ca "${RUNTIMEDIR}/ca/ca.pem" \
            -ca-key "${RUNTIMEDIR}/ca/ca-key.pem" \
            -config "${CONFDIR}/ca-config.json" \
            -profile intermediate_ca "intermediate${i}.csr" | cfssljson -bare "intermediate${i}"
done

# Create and sign (with intermediate 1) a cert for this "host" to be used by multirootca
cd "${RUNTIMEDIR}/certs"
cfssl gencert -ca "${RUNTIMEDIR}/intermediate/intermediate1.pem" \
              -ca-key "${RUNTIMEDIR}/intermediate/intermediate1-key.pem" \
              -config "${CONFDIR}/ca-config.json" \
              -profile=server "${CONFDIR}/host.json" | cfssljson -bare host
# Create a bundle with the host cert and the CA chain
cat host.pem "${RUNTIMEDIR}/intermediate/intermediate1.pem" "${RUNTIMEDIR}/ca/ca.pem" > host-bundle.pem
