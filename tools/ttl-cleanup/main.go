package main

import (
	"context"
	"log"
	"os"
	"strings"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	lastDeployAnnotation = "preview.ravidu.space/last-deploy"
	namespacePrefix      = "pr-"
)

func main() {
	ttl := duration("TTL", 48*time.Hour)
	dryRun := os.Getenv("DRY_RUN") == "true"

	client, err := newClient()
	if err != nil {
		log.Fatalf("kubernetes client: %v", err)
	}

	ctx := context.Background()
	namespaces, err := client.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Fatalf("list namespaces: %v", err)
	}

	now := time.Now()
	var checked, deleted int

	for _, ns := range namespaces.Items {
		if !strings.HasPrefix(ns.Name, namespacePrefix) {
			continue
		}
		checked++

		idle := idleFor(ns.Annotations[lastDeployAnnotation], ns.CreationTimestamp.Time, now)
		if idle < ttl {
			log.Printf("keep %s (idle %s)", ns.Name, idle.Round(time.Minute))
			continue
		}

		if dryRun {
			log.Printf("would delete %s (idle %s)", ns.Name, idle.Round(time.Minute))
			deleted++
			continue
		}

		if err := client.CoreV1().Namespaces().Delete(ctx, ns.Name, metav1.DeleteOptions{}); err != nil {
			log.Printf("delete %s: %v", ns.Name, err)
			continue
		}
		log.Printf("deleted %s (idle %s)", ns.Name, idle.Round(time.Minute))
		deleted++
	}

	log.Printf("checked %d preview namespaces, %d expired (ttl %s)", checked, deleted, ttl)
}

// idleFor prefers the last-deploy annotation and falls back to namespace creation time,
// so a namespace created outside the workflow is still eligible for cleanup.
func idleFor(annotation string, created, now time.Time) time.Duration {
	if annotation != "" {
		if t, err := time.Parse(time.RFC3339, annotation); err == nil {
			return now.Sub(t)
		}
		log.Printf("unparseable %s annotation %q, falling back to creation time", lastDeployAnnotation, annotation)
	}
	return now.Sub(created)
}

func newClient() (*kubernetes.Clientset, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, err
	}
	return kubernetes.NewForConfig(config)
}

func duration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
		log.Printf("invalid %s=%q, using %s", key, v, fallback)
	}
	return fallback
}
