// fleetcheck: report namespaces missing a label across every context in $KUBECONFIG.
// Exit codes: 0 all labelled, 1 some namespaces missing the label, 2 a cluster could not be checked.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

type result struct {
	Context string   `json:"context"`
	Missing []string `json:"missing"`
	Error   string   `json:"error,omitempty"`
}

func main() {
	label := flag.String("label", "cost-center", "label every namespace must carry")
	timeout := flag.Duration("timeout", 10*time.Second, "per-cluster timeout")
	output := flag.String("output", "text", "text or json")
	flag.Parse()

	rules := clientcmd.NewDefaultClientConfigLoadingRules() // honours $KUBECONFIG (colon-separated too)
	cfg, err := rules.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "load kubeconfig:", err)
		os.Exit(2)
	}
	names := make([]string, 0, len(cfg.Contexts))
	for n := range cfg.Contexts {
		names = append(names, n)
	}
	sort.Strings(names)

	// Fan out: one goroutine per cluster, each bounded by its own timeout.
	// Results are written by index, so no mutex is needed and the output order is stable.
	results := make([]result, len(names))
	var wg sync.WaitGroup
	for i, name := range names {
		wg.Add(1)
		go func(i int, name string) {
			defer wg.Done()
			results[i] = check(*cfg, rules, name, *label, *timeout)
		}(i, name)
	}
	wg.Wait()

	code := 0
	for _, r := range results {
		switch {
		case r.Error != "":
			code = 2
		case len(r.Missing) > 0 && code == 0:
			code = 1
		}
	}
	if *output == "json" {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(results)
	} else {
		for _, r := range results {
			switch {
			case r.Error != "":
				fmt.Printf("%-8s ERROR %s\n", r.Context, r.Error)
			case len(r.Missing) == 0:
				fmt.Printf("%-8s ok: every namespace has %q\n", r.Context, *label)
			default:
				fmt.Printf("%-8s %d missing %q: %v\n", r.Context, len(r.Missing), *label, r.Missing)
			}
		}
	}
	os.Exit(code)
}

func check(cfg clientcmdapi.Config, rules *clientcmd.ClientConfigLoadingRules, name, label string, timeout time.Duration) result {
	r := result{Context: name}
	rest, err := clientcmd.NewNonInteractiveClientConfig(cfg, name, &clientcmd.ConfigOverrides{}, rules).ClientConfig()
	if err != nil {
		r.Error = err.Error()
		return r
	}
	rest.Timeout = timeout // also bounds dial/TLS, not just the request
	cs, err := kubernetes.NewForConfig(rest)
	if err != nil {
		r.Error = err.Error()
		return r
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	m, err := Missing(ctx, cs, label)
	if err != nil {
		r.Error = err.Error()
		return r
	}
	r.Missing = m
	return r
}
