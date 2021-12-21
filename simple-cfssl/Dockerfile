FROM golang:1.16.3 as builder

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64 \
    GO111MODULE=on

WORKDIR /workdir

ARG CFSSL_VERSION=wmf
RUN git clone https://github.com/wikimedia/cfssl.git && \
    cd cfssl && git checkout ${CFSSL_VERSION} && \
    make all

FROM debian:bullseye
COPY --from=builder /workdir/cfssl/bin/* /usr/bin/

# Get defaults from:
# docker run --rm cfssl/cfssl print-defaults config > ca-config.json
# docker run --rm cfssl/cfssl print-defaults csr > ca-csr.json
WORKDIR /cfssl
ADD * /cfssl/
RUN /cfssl/setup-ca.sh

EXPOSE 8888

ENTRYPOINT ["/usr/bin/multirootca"]
CMD ["-loglevel=0", "-a=0.0.0.0:8888", "-roots=/cfssl/multiroot.conf", "-tls-cert=/cfssl/certs/host-bundle.pem", "-tls-key=/cfssl/certs/host-key.pem"]
