# cfssl-issuer

This is an an [External Issuer] for cert-manager to be used with [CFSSL] multirootca.
It is based off of the [sample-external-issuer] provided by cert-manager.

## Install

```
make build/install.yaml
kubectl apply -f build/install.yaml
```
# Development

You will need the following command line tools installed on your PATH:

* [Git](https://git-scm.com/)
* [Golang v1.15+](https://golang.org/)
* [Docker v17.03+](https://docs.docker.com/install/)
* [Kind v0.9.0+](https://kind.sigs.k8s.io/docs/user/quick-start/)
* [Kubectl v1.11.3+](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
* [Kubebuilder v2.3.1+](https://book.kubebuilder.io/quick-start.html#installation)
* [Kustomize v3.8.1+](https://kustomize.io/)

You may also want to read: the [Kubebuilder Book] and the [cert-manager Concepts Documentation].

## The CertificateRequest

The `CertificateRequestReconciler` is triggered by changes to any `CertificateRequest` resource in the cluster.
The `Reconcile` function is called with the name of the object that changed, and
the first thing we need to do is to `GET` the complete object from the Kubernetes API server.

The `Reconcile` function may occasionally be triggered with the names of deleted resources,
so we have to handle that case gracefully.

In the implementation we are careful to `return Result{}, nil` when the `CertificateRequest` is not found.
This tells controller-runtime *do not retry*.
Other error types are assumed to be temporary errors and are returned.

NOTE: If you return an `error`, controller-runtime will retry with an increasing backoff,
so it is very important to distinguish between temporary and permanent errors.

## Ignore foreign CertificateRequest

We only want to reconcile `CertificateRequest` resources that are configured for our issuer.
So the next piece of controller logic attempts to exit early if `CertificateRequest.Spec.IssuerRef` does not refer to our particular `Issuer` or `ClusterIssuer` types.

Also note how in the implementation we use the `Scheme.New`  method to verify the `Kind`.
This later will allow us to easily handle both `Issuer` and `ClusterIssuer` references.

If there is a mismatch in the `IssuerRef` we ignore the `CertificateRequest`.

## Check that the CertificateRequest is Approved

Issuers must only sign `Approved` `CertificateRequest` resources.
If the `CertificateRequest` has been `Denied`, then the Issuer should set a
`Ready` condition to `False`, and set the `FailureTime`.
If the `CertificateRequest` has been `Approved`, then the Issuer should process
the request.

Issuers are not responsible for approving `CertificateRequests`.
You can read more about the [CertificateRequest Approval API][] in the cert-manager documentation.

[CertificateRequest Approval API]: https://cert-manager.io/docs/concepts/certificaterequest/#approval

The [cert-manager API utility package][] contains functions for checking the `Approved` and `Denied` conditions of a `CertificateRequest`.

[cert-manager API utility package]: https://pkg.go.dev/github.com/jetstack/cert-manager@v1.3.0/pkg/api/util#CertificateRequestIsApproved

If using an older version of cert-manager (pre v1.3), you can disable this check
by supplying the command line flag `-disable-approved-check` to the Deployment.

## Set the CertificateRequest Ready condition

The [External Issuer] documentation says the following:

 It is important to update the condition status of the `CertificateRequest` to a ready state,
 as this is what is used to signal to higher order controllers, such as the Certificate controller, that the resource is ready to be consumed.
 Conversely, if the `CertificateRequest` fails, it is important to mark the resource as such, as this will also be used to signal to higher order controllers.

So now we need to ensure that our issuer always sets one of the [strongly defined conditions](https://cert-manager.io/docs/concepts/certificaterequest/#conditions)
on all the `CertificateRequest` referring to our `Group`.

The first thing to check is whether the `Ready` condition is already `true` in which case we can exit early.

## The Issuer or ClusterIssuer

The `Issuer` or `ClusterIssuer` for the `CertificateRequest` contain configuration that you will need to connect to the CFSSL API (such as the `Label` and `Profile` to use).
It also contains a reference to a `Secret` containing credentials which you will use to authenticate with with the CFSSL API.

An `Issuer` has both a name and a namespace.
A `ClusterIssuer` is [cluster scoped](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/#not-all-objects-are-in-a-namespace) and does not have a namespace.
So we check which type we have in order to derive the correct name.

## Get the Issuer or ClusterIssuer credentials from a Secret

The CFSSL API requires some configuration and credentials and the obvious place to store these is in a Kubernetes `Secret`.

The Secret for an Issuer MUST be in the same namespace as the Issuer.
The Secret for a ClusterIssuer MUST be in a namespace defined via command line argument. If no configuration is given, the namespace running the cfssl-issuer is used.

NOTE: Ideally, we would `WATCH` for the particular `Secret` and trigger the reconciliation when it becomes available.
And that may be a future enhancement to this project.


## Issuer health checks

As the issuer connects to a CFSSL API it performs periodic health checks to ensure that the API server is responding and if not,
to set update the `Ready` condition of the `Issuer` to false and log a meaningful error message with the condition.
This will give early warning of problems with the configuration or with the API,
rather than waiting a for `CertificateRequest` to fail before being alerted to the problem.

Since we want the health checks to be performed periodically,
we need to make controller-runtime retry reconciling regularly, even when the current reconcile succeeds.
We do this by setting the `Result.RequeueAfter` field of the returned result.


## Sign the CertificateRequest

Now we turn back to the `CertificateRequestReconciler` and think about how we want it to handle the certificate signing request (CSR).

The `signer` package contains a new simple `Interface` and a factory function definition:

```
type Signer interface {
    Sign([]byte) ([]byte, error)
}

type SignerBuilder func(*cfsslissuerapi.IssuerSpec, map[string][]byte) (Signer, error)
```

Both are implemented by the `cfssl` signer in `internal/issuer/signer/cfssl.go`. The provided CSR is validated, transformed and finally send to the CFSSL API for signing (using the `Label` and `Profile` for the selected issuer).

## End-to-end tests

Those are implemented using [Kind] and a dummy CFSSL API container called simple-cfssl which I currently don't know where to put. Assuming access to it, e2e tests can be run via:
```
make e2e-all
```

If you already have a running Kubernetes cluster and want to test using the currently active context:
```
make docker-build deploy-simple-cfssl e2e
```

## Links

[External Issuer]: https://cert-manager.io/docs/contributing/external-issuers
[CFSSL]: https://github.com/cloudflare/cfssl
[cert-manager Concepts Documentation]: https://cert-manager.io/docs/concepts
[Kubebuilder Book]: https://book.kubebuilder.io
[kube-rbac-proxy]: https://github.com/brancz/kube-rbac-proxy
[Kind]: (https://kind.sigs.k8s.io/)
[sample-external-issuer]: https://github.com/cert-manager/sample-external-issuer
