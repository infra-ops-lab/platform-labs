package main

import (
	"context"
	"sort"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// Missing returns the sorted names of namespaces that do not carry label.
// It takes kubernetes.Interface so tests can pass a fake clientset.
func Missing(ctx context.Context, cs kubernetes.Interface, label string) ([]string, error) {
	var out []string
	opts := metav1.ListOptions{Limit: 500}
	for {
		list, err := cs.CoreV1().Namespaces().List(ctx, opts)
		if err != nil {
			return nil, err
		}
		for _, ns := range list.Items {
			if _, ok := ns.Labels[label]; !ok {
				out = append(out, ns.Name)
			}
		}
		if list.Continue == "" {
			break
		}
		opts.Continue = list.Continue // paginate: large clusters have thousands of namespaces
	}
	sort.Strings(out)
	return out, nil
}
