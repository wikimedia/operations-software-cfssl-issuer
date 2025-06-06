FROM docker-registry.wikimedia.org/repos/sre/cfssl:wmf-1.6.5

# Get defaults from:
# docker run --rm cfssl/cfssl print-defaults config > ca-config.json
# docker run --rm cfssl/cfssl print-defaults csr > ca-csr.json
WORKDIR /cfssl
COPY setup-ca.sh /cfssl/
COPY ca-config.json \
     ca-csr.json \
     intermediate1-csr.json \
     intermediate2-csr.json \
     intermediate-config.json \
     multiroot.conf \
     host.json \
     /cfssl/config/
RUN /cfssl/setup-ca.sh

EXPOSE 8888

ENTRYPOINT ["/usr/bin/multirootca"]
CMD ["-loglevel=0", "-a=0.0.0.0:8888", "-roots=/cfssl/config/multiroot.conf", "-tls-cert=/cfssl/runtime/certs/host-bundle.pem", "-tls-key=/cfssl/runtime/certs/host-key.pem"]
