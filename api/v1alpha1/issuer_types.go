/*
Copyright 2023 The cert-manager Authors.
Copyright 2021 The Wikimedia Foundation, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// IssuerSpec defines the desired state of Issuer
type IssuerSpec struct {
	// URL is one or more base URLs for the CFSSL API, for example:
	// "https://sample-signer.example.com/api,https//cfssl.example.com".
	// If multiple comma seperated URLs are given and the first server cannot be reached,
	// the next is used. The client will proceed in this manner until the list of
	// servers is exhausted, and then an error is returned.
	URL string `json:"url"`

	// A reference to a Secret in the same namespace as the referent. If the
	// referent is a ClusterIssuer, the reference instead refers to the resource
	// with the given name in the configured 'cluster resource namespace', which
	// is set as a flag on the controller component (and defaults to the
	// namespace that the controller runs in).
	// The secret needs to contain a field "key" containing the hex string used to
	// authenticate against cfssl API as well as an optional "additional_data" field.
	AuthSecretName string `json:"authSecretName"`

	// A string specifying which CFSSL signer to be appointed to sign the CSR.
	// Label is mandatory as the info endpoint of the CFSSL API (which is used for
	// health checking the API) requires it to be set.
	Label string `json:"label"`

	// A string specifying the signing profile for the CFSSL signer (a signer may have
	// multiple different profiles configured).
	// If omitted, the "default" profile is used.
	Profile string `json:"profile,omitempty"`

	// A boolean specifying whether to include an "optimal" certificate bundle instead
	// of the certificate.
	Bundle bool `json:"bundle,omitempty"`
}

// IssuerStatus defines the observed state of Issuer
type IssuerStatus struct {
	// List of status conditions to indicate the status of a CertificateRequest.
	// Known condition types are `Ready`.
	// +optional
	Conditions []IssuerCondition `json:"conditions,omitempty"`
}

//+kubebuilder:object:root=true
//+kubebuilder:subresource:status

// Issuer is the Schema for the issuers API
type Issuer struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   IssuerSpec   `json:"spec,omitempty"`
	Status IssuerStatus `json:"status,omitempty"`
}

//+kubebuilder:object:root=true

// IssuerList contains a list of Issuer
type IssuerList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Issuer `json:"items"`
}

// IssuerCondition contains condition information for an Issuer.
type IssuerCondition struct {
	// Type of the condition, known values are ('Ready').
	Type IssuerConditionType `json:"type"`

	// Status of the condition, one of ('True', 'False', 'Unknown').
	Status ConditionStatus `json:"status"`

	// LastTransitionTime is the timestamp corresponding to the last status
	// change of this condition.
	// +optional
	LastTransitionTime *metav1.Time `json:"lastTransitionTime,omitempty"`

	// Reason is a brief machine readable explanation for the condition's last
	// transition.
	// +optional
	Reason string `json:"reason,omitempty"`

	// Message is a human readable description of the details of the last
	// transition, complementing reason.
	// +optional
	Message string `json:"message,omitempty"`
}

// IssuerConditionType represents an Issuer condition value.
type IssuerConditionType string

const (
	// IssuerConditionReady represents the fact that a given Issuer condition
	// is in ready state and able to issue certificates.
	// If the `status` of this condition is `False`, CertificateRequest controllers
	// should prevent attempts to sign certificates.
	IssuerConditionReady IssuerConditionType = "Ready"
)

// ConditionStatus represents a condition's status.
// +kubebuilder:validation:Enum=True;False;Unknown
type ConditionStatus string

// These are valid condition statuses. "ConditionTrue" means a resource is in
// the condition; "ConditionFalse" means a resource is not in the condition;
// "ConditionUnknown" means kubernetes can't decide if a resource is in the
// condition or not. In the future, we could add other intermediate
// conditions, e.g. ConditionDegraded.
const (
	// ConditionTrue represents the fact that a given condition is true
	ConditionTrue ConditionStatus = "True"

	// ConditionFalse represents the fact that a given condition is false
	ConditionFalse ConditionStatus = "False"

	// ConditionUnknown represents the fact that a given condition is unknown
	ConditionUnknown ConditionStatus = "Unknown"
)

func init() {
	SchemeBuilder.Register(&Issuer{}, &IssuerList{})
}
