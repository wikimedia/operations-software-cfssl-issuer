/*
Copyright 2020 The cert-manager Authors
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

package util

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	cfsslissuerapi "gerrit.wikimedia.org/r/operations/software/cfssl-issuer/api/v1alpha1"
)

func GetSpecAndStatus(issuer client.Object) (*cfsslissuerapi.IssuerSpec, *cfsslissuerapi.IssuerStatus, error) {
	switch t := issuer.(type) {
	case *cfsslissuerapi.Issuer:
		return &t.Spec, &t.Status, nil
	case *cfsslissuerapi.ClusterIssuer:
		return &t.Spec, &t.Status, nil
	default:
		return nil, nil, fmt.Errorf("not an issuer type: %t", t)
	}
}

func SetReadyCondition(status *cfsslissuerapi.IssuerStatus, conditionStatus cfsslissuerapi.ConditionStatus, reason, message string) {
	ready := GetReadyCondition(status)
	if ready == nil {
		ready = &cfsslissuerapi.IssuerCondition{
			Type: cfsslissuerapi.IssuerConditionReady,
		}
		status.Conditions = append(status.Conditions, *ready)
	}
	if ready.Status != conditionStatus {
		ready.Status = conditionStatus
		now := metav1.Now()
		ready.LastTransitionTime = &now
	}
	ready.Reason = reason
	ready.Message = message

	for i, c := range status.Conditions {
		if c.Type == cfsslissuerapi.IssuerConditionReady {
			status.Conditions[i] = *ready
			return
		}
	}
}

func GetReadyCondition(status *cfsslissuerapi.IssuerStatus) *cfsslissuerapi.IssuerCondition {
	for _, c := range status.Conditions {
		if c.Type == cfsslissuerapi.IssuerConditionReady {
			return &c
		}
	}
	return nil
}

func IsReady(status *cfsslissuerapi.IssuerStatus) bool {
	if c := GetReadyCondition(status); c != nil {
		return c.Status == cfsslissuerapi.ConditionTrue
	}
	return false
}
