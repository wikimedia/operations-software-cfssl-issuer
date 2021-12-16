module gerrit.wikimedia.org/r/operations/software/cfssl-issuer

go 1.15

require (
	github.com/cloudflare/cfssl v1.6.1
	github.com/go-logr/logr v0.4.0
	github.com/jetstack/cert-manager v1.5.4
	github.com/stretchr/testify v1.7.0
	k8s.io/api v0.21.4
	k8s.io/apimachinery v0.21.4
	k8s.io/client-go v0.21.4
	sigs.k8s.io/controller-runtime v0.9.7
)

replace github.com/cloudflare/cfssl => github.com/wikimedia/cfssl v1.6.2-0.20211221103754-1bae9faebdd0
