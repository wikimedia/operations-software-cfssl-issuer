# Build the manager binary
FROM golang:1.16.3 as builder

WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64 \
    GO111MODULE=on

# Copy the go source
COPY main.go main.go
COPY api/ api/
COPY internal/ internal/

# Do an initial compilation before setting the version so that there is less to
# re-compile when the version changes
RUN go build -mod=readonly ./...

ARG VERSION

# Build
RUN go build \
  -ldflags="-X=gerrit.wikimedia.org/r/operations/software/cfssl-issuer/internal/version.Version=${VERSION}" \
  -mod=readonly \
  -o manager main.go

# Use distroless as minimal base image to package the manager binary
# Refer to https://github.com/GoogleContainerTools/distroless for more details
FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=builder /workspace/manager .

ENTRYPOINT ["/manager"]
