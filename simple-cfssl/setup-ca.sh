#!/bin/bash

set -ex

mkdir -p /cfssl/{ca,intermediate,certs}

# Create root CA
cd /cfssl/ca
cfssl genkey -initca /cfssl/ca-csr.json | cfssljson -bare ca

# Create & sign two intermediates
cd /cfssl/intermediate
cfssl genkey -initca /cfssl/intermediate1-csr.json | cfssljson -bare intermediate1
cfssl sign -ca /cfssl/ca/ca.pem -ca-key /cfssl/ca/ca-key.pem -config /cfssl/ca-config.json -profile intermediate_ca intermediate1.csr | cfssljson -bare intermediate1
cfssl genkey -initca /cfssl/intermediate2-csr.json | cfssljson -bare intermediate2
cfssl sign -ca /cfssl/ca/ca.pem -ca-key /cfssl/ca/ca-key.pem -config /cfssl/ca-config.json -profile intermediate_ca intermediate2.csr | cfssljson -bare intermediate2

# Create and sign a cert for host
cd /cfssl/certs
cfssl gencert -ca /cfssl/intermediate/intermediate1.pem -ca-key /cfssl/intermediate/intermediate1-key.pem -config /cfssl/ca-config.json -profile=server /cfssl/host.json | cfssljson -bare host
cat host.pem /cfssl/intermediate/intermediate1.pem /cfssl/ca/ca.pem > host-bundle.pem
