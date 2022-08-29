# Build the manager binary
FROM golang:1.17 as builder

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64 \
    GO111MODULE=on

WORKDIR /workspace
COPY . /workspace/

# Do an initial compilation before setting the version so that there is less to
# re-compile when the version changes
RUN go build -mod=vendor ./...

ARG VERSION

# Build
RUN go build \
  -ldflags="-X=gerrit.wikimedia.org/r/operations/software/cfssl-issuer/internal/version.Version=${VERSION}" \
  -mod=vendor \
  -o manager main.go

# Use distroless as minimal base image to package the manager binary
# Refer to https://github.com/GoogleContainerTools/distroless for more details
FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=builder /workspace/manager .

ENTRYPOINT ["/manager"]
