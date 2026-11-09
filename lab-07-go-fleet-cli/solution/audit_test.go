package main

import (
	"context"
	"reflect"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func ns(name string, labels map[string]string) *corev1.Namespace {
	return &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels}}
}

func TestMissing(t *testing.T) {
	cs := fake.NewSimpleClientset(
		ns("payments", map[string]string{"cost-center": "cc-42"}),
		ns("tenant-acme", nil),
		ns("default", map[string]string{"team": "x"}),
	)
	got, err := Missing(context.Background(), cs, "cost-center")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"default", "tenant-acme"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}
