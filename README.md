# cfssl-issuer

This is an an [External Issuer] for cert-manager to be used with [CFSSL] `multirootca`.
It is based off of the [sample-external-issuer] provided by cert-manager.

While it might work as well with `cfssl serve` instead of `multirootca` that has not been tested yet.

## Install
For the installation of cert-manager, please see the documentation at https://cert-manager.io/docs/installation/.

For the cfssl-issuer, there are helm charts (_cfssl-issuer_ and _cfssl-issuer-cdrs_) available at https://helm-charts.wikimedia.org/stable (source: [cfssl-issuer](https://gerrit.wikimedia.org/r/plugins/gitiles/operations/deployment-charts/+/refs/heads/master/charts/cfssl-issuer/), [cfssl-issuer-cdrs](https://gerrit.wikimedia.org/r/plugins/gitiles/operations/deployment-charts/+/refs/heads/master/charts/cfssl-issuer-crds/)). The corresponding docker images can be found at: https://docker-registry.wikimedia.org/cfssl-issuer/tags/

Please see the helm charts `values.yaml` for examples on how to create Issuer/ClusterIssuer objects.

## multirootca and bundles
The cfssl-issuer supports fetching bundles instead of certificates from the CFSSL endpoint `/api/v1/cfssl/authsign` (see [doc/api/endpoint_authsign.txt](https://github.com/cloudflare/cfssl/blob/master/doc/api/endpoint_authsign.txt)) which is currently only supported in a forked version of multirootca which can be fount at: https://github.com/wikimedia/cfssl/tree/wmf

A corresponding upstream PR is at: https://github.com/cloudflare/cfssl/pull/1218

## Root CA in kubernetes.io/tls Secret
In case the Issuer is configured with `bundle: true` (see node on multirootca support from above), the root CA is returned by the multirootca API and will be provided to the user in the resulting `kubernetes.io/tls` Secret.

As the multirootca API lacks the `/api/v1/cfssl/bundle` endpoint, this is unfortunately not possible with a `bundle: false` Issuer.

# Development

You will need the following command line tools installed on your PATH:

* [Git](https://git-scm.com/)
* [Golang v1.20+](https://golang.org/)
* [Docker v17.03+](https://docs.docker.com/install/)
* [Kind v0.18.0+](https://kind.sigs.k8s.io/docs/user/quick-start/)
* [Kubectl v1.26.3+](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
* [Kubebuilder v3.9.1+](https://book.kubebuilder.io/quick-start.html#installation)
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
    Sign(context.Context, []byte) ([]byte, []byte, error)
}

type SignerBuilder func(*cfsslissuerapi.IssuerSpec, map[string][]byte) (Signer, error)
```

Both are implemented by the `cfssl` signer in `internal/issuer/signer/cfssl.go`. The provided CSR is validated, transformed and finally send to the CFSSL API for signing (using the `Label` and `Profile` for the selected issuer).

## End-to-end tests

Those are implemented using [Kind] and a dummy CFSSL API container called simple-cfssl (which can be build from this source tree as well). End-to-end tests can be run via:
```
make e2e-all
```

If you already have a running Kubernetes cluster and want to test using the currently active context:
```
make docker-build deploy-simple-cfssl e2e
```

In the unit-tests, we can use a simple byte string for the certificate, but in E2E tests later we will use real certificate signing requests and real certificates.

#### An example signer

For the purposes of this example external issuer,
we will implement an `exampleSigner` which implements both the `HealthChecker` and the `Signer` interfaces, and
which signs the CSR using a static in-memory CA certificate.

In `internal/issuer/signer/signer.go` you will see that we:
decode the supplied CSR bytes,
and then sign the certificate using some libraries that were copied from the Kubernetes project.
This simple implementation is just sufficient to allow us (later) to perform some E2E tests with cert-manager.

In your external issuer, this is where you will plug in your CA client library,
or where you will instantiate an HTTP client and connect to your API.

Notice also that we add two concrete factory functions which are supplied to the `IssuerReconciler` and `CertificateRequestReconciler` in `main.go`.

#### What about the ClusterIssuerReconciler?

We have so far abandoned development of the `ClusterIssuerReconciler`, and that's because we want to re-use the `IssuerReconciler` rather than duplicating everything.

So here we delete the skaffolded `controllers/clusterissuer_controller.go` and update the `issuer_controller.go` to handle both types.

As well as juggling the code to handle both types, we:
aggregate the Kubebuilder RBAC annotations, and
add a new command line flag which allows us to set a `--cluster-resource-namespace`.

The `--cluster-resource-namespace` is the namespace where the issuer will look for `Secret` resources referred to by a `ClusterIssuer`,
since `ClusterIssuer` is cluster-scoped.
The default value of the flag is the namespace where the issuer is running in the cluster.

### Logging and Events

We want to make it easy to debug problems with the issuer,
so in addition to setting Conditions on the Issuer, ClusterIssuer and CertificateRequest,
we can provide more feedback to the user by logging Kubernetes Events.
You may want to read more about [Application Introspection and Debugging][] before continuing.

[Application Introspection and Debugging]: https://kubernetes.io/docs/tasks/debug-application-cluster/debug-application-introspection/

Kubernetes Events are saved to the API server on a best-effort basis,
they are (usually) associated with some other Kubernetes resource,
and they are temporary; old Events are periodically purged from the API server.
This allows tools such as `kubectl describe <resource-kind> <resource-name>` to show not only the resource details,
but also a table of the recent events associated with that resource.

The aim is to produce helpful debug output that looks like this:

```
$ kubectl describe clusterissuers.sample-issuer.example.com clusterissuer-sample
...
    Type:                  Ready
Events:
  Type     Reason            Age                From                    Message
  ----     ------            ----               ----                    -------
  Normal   IssuerReconciler  13s                cfssl-issuer  First seen
  Warning  IssuerReconciler  13s (x3 over 13s)  cfssl-issuer  Temporary error. Retrying: failed to get Secret containing Issuer credentials, secret name: cfssl-issuer-system/clusterissuer-sample-credentials, reason: Secret "clusterissuer-sample-credentials" not found
  Normal   IssuerReconciler  13s (x3 over 13s)  cfssl-issuer  Success
```
And this:

```
$ kubectl describe certificaterequests.cert-manager.io issuer-sample
...
Events:
  Type     Reason                        Age   From                    Message
  ----     ------                        ----  ----                    -------
  Normal   CertificateRequestReconciler  23m   cfssl-issuer  Initialising Ready condition
  Warning  CertificateRequestReconciler  23m   cfssl-issuer  Temporary error. Retrying: error getting issuer: Issuer.sample-issuer.example.com "issuer-sample" not found
  Normal   CertificateRequestReconciler  23m   cfssl-issuer  Signed

```

First add [record.EventRecorder][] attributes to the `IssuerReconciler` and to the `CertificateRequestReconciler`.
And then in the Reconciler code, you can then generate an event by executing `r.recorder.Eventf(...)` whenever a significant change is made to the resource.

[record.EventRecorder]: https://pkg.go.dev/k8s.io/client-go/tools/record#EventRecorder

You can also write unit tests to verify the Reconciler events by using a [record.FakeRecorder][].

[record.FakeRecorder]: https://pkg.go.dev/k8s.io/client-go/tools/record#FakeRecorder

See [PR 10: Generate Kubernetes Events](https://github.com/cert-manager/sample-external-issuer/pull/10) for an example of how you might generate events in your issuer.

### End-to-end tests

Now our issuer is almost feature complete and it should be possible to write an end-to-end test that
deploys a cert-manager `Certificate`
referring to an external `Issuer` and check that a signed `Certificate` is saved to the expected secret.

We can make such a test easier by tidying up the `Makefile` and adding some new targets
which will help create a test cluster and to help install cert-manager.

We can write a simple end-to-end test which deploys a `Certificate` manifest and waits for it to be ready.

```console
kubectl apply --filename config/samples
kubectl wait --for=condition=Ready --timeout=5s issuers.sample-issuer.example.com issuer-sample
kubectl wait --for=condition=Ready --timeout=5s  certificates.cert-manager.io certificate-by-issuer
```

You can of course write more complete tests than this,
but this is a good start and demonstrates that the issuer is doing what we hoped it would do.

Run the tests as follows:

```bash
# Create a Kind cluster along with cert-manager.
make kind-cluster deploy-cert-manager

# Wait for cert-manager to start...

# Build and install cfssl-issuer and run the E2E tests.
# This step can be run iteratively when ever you make changes to the code or to the installation manifests.
make docker-build kind-load deploy e2e
```

#### Continuous Integration

You should configure a CI system to automatically run the unit-tests when the code changes.
See the `.github/workflows/`  directory for some examples of using GitHub Actions
which are triggered by changes to pull request branches and by any changes to the master branch.

The E2E tests can be executed with GitHub Actions too.
The GitHub Actions Ubuntu runner has Docker installed and is capable of running a Kind cluster for the E2E tests.
The Kind cluster logs can be saved in the event of an E2E test failure,
and uploaded as a GitHub Actions artifact,
to make it easier to diagnose E2E test failures.

## Security considerations

We use a [Distroless Docker Image][] as our Docker base image,
and we configure our `manager` process to run as `USER: nonroot:nonroot`.
This limits the privileges of the `manager` process in the cluster.

The [kube-rbac-proxy][] sidecar Docker image also uses a non-root user by default (since v0.7.0).

Additionally we [Configure a Security Context][] for the manager Pod.
We set `runAsNonRoot`, which ensure that the Kubelet will validate the image at runtime
to ensure that it does not run as UID 0 (root) and fail to start the container if it does.

## Links

[External Issuer]: https://cert-manager.io/docs/contributing/external-issuers
[CFSSL]: https://github.com/cloudflare/cfssl
[cert-manager Concepts Documentation]: https://cert-manager.io/docs/concepts
[Kubebuilder Book]: https://book.kubebuilder.io
[kube-rbac-proxy]: https://github.com/brancz/kube-rbac-proxy
[Kind]: (https://kind.sigs.k8s.io/)
[sample-external-issuer]: https://github.com/cert-manager/sample-external-issuer
