FROM debian:bullseye

# Get defaults from:
# docker run --rm cfssl/cfssl print-defaults config > ca-config.json
# docker run --rm cfssl/cfssl print-defaults csr > ca-csr.json

RUN apt-get update && \
    apt-get install -y --no-install-recommends golang-cfssl

WORKDIR /cfssl
ADD * /cfssl/
RUN /cfssl/setup-ca.sh

EXPOSE 8888

ENTRYPOINT ["/usr/bin/multirootca"]
CMD ["-a=0.0.0.0:8888", "-roots=/cfssl/multiroot.conf", "-tls-cert=/cfssl/certs/host-bundle.pem", "-tls-key=/cfssl/certs/host-key.pem"]