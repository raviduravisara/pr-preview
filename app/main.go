package main

import (
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
)

type pageData struct {
	PRNumber string
	Commit   string
	Color    string
}

var page = template.Must(template.New("index").Parse(`<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Preview — PR {{.PRNumber}}</title>
<style>
  body { margin:0; height:100vh; display:flex; align-items:center; justify-content:center;
         font-family:system-ui,sans-serif; background:{{.Color}}; color:#fff; }
  .card { text-align:center; }
  h1 { font-size:5rem; margin:0; }
  p  { font-size:1.25rem; opacity:.85; }
  code { background:rgba(0,0,0,.25); padding:.2em .5em; border-radius:4px; }
</style>
</head>
<body>
  <div class="card">
    <h1>PR #{{.PRNumber}}</h1>
    <p>preview environment is live</p>
    <p><code>{{.Commit}}</code></p>
  </div>
</body>
</html>`))

func main() {
	data := pageData{
		PRNumber: env("PR_NUMBER", "local"),
		Commit:   env("GIT_SHA", "dev"),
		Color:    env("BG_COLOR", "#1a4d8f"),
	}

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if err := page.Execute(w, data); err != nil {
			log.Printf("render: %v", err)
		}
	})

	port := env("PORT", "8080")
	log.Printf("listening on :%s (pr=%s)", port, data.PRNumber)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
