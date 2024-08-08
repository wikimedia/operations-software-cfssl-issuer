FROM docker-registry.wikimedia.org/bullseye

RUN apt-get update && apt-get install -y --no-install-recommends golang-cfssl

# Get defaults from:
# docker run --rm cfssl/cfssl print-defaults config > ca-config.json
# docker run --rm cfssl/cfssl print-defaults csr > ca-csr.json
WORKDIR /cfssl
ADD * /cfssl/
RUN /cfssl/setup-ca.sh

EXPOSE 8888

ENTRYPOINT ["/usr/bin/multirootca"]
CMD ["-loglevel=0", "-a=0.0.0.0:8888", "-roots=/cfssl/multiroot.conf", "-tls-cert=/cfssl/certs/host-bundle.pem", "-tls-key=/cfssl/certs/host-key.pem"]
