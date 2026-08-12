package main

import (
	"database/sql"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	_ "github.com/lib/pq"
)

type message struct {
	Body      string
	Author    string
	CreatedAt time.Time
}

type pageData struct {
	PRNumber string
	Commit   string
	Color    string
	Messages []message
	DBError  string
}

var db *sql.DB

var page = template.Must(template.New("index").Parse(`<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Preview — PR {{.PRNumber}}</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; min-height:100vh; font-family:system-ui,sans-serif;
         background:{{.Color}}; color:#fff; display:flex; justify-content:center; }
  main { width:min(640px, 92vw); padding:3rem 0; }
  header { text-align:center; margin-bottom:2.5rem; }
  h1 { font-size:3.5rem; margin:0; }
  .sub { opacity:.8; }
  code { background:rgba(0,0,0,.25); padding:.15em .45em; border-radius:4px; font-size:.85em; }
  form { display:flex; gap:.5rem; margin-bottom:1.5rem; }
  input { flex:1; padding:.7rem .9rem; border:0; border-radius:6px; font-size:1rem; }
  button { padding:.7rem 1.2rem; border:0; border-radius:6px; font-size:1rem;
           background:rgba(255,255,255,.9); cursor:pointer; }
  ul { list-style:none; padding:0; margin:0; }
  li { background:rgba(0,0,0,.2); padding:.85rem 1rem; border-radius:8px; margin-bottom:.6rem; }
  .who { opacity:.7; font-size:.85rem; }
  .err { background:rgba(0,0,0,.35); padding:1rem; border-radius:8px; }
</style>
</head>
<body>
<main>
  <header>
    <h1>PR #{{.PRNumber}}</h1>
    <p class="sub">preview environment is live · <code>{{.Commit}}</code></p>
  </header>

  {{if .DBError}}
    <p class="err">database unavailable: {{.DBError}}</p>
  {{else}}
    <form method="post" action="/messages">
      <input name="body" placeholder="Leave a message in this environment" required maxlength="200">
      <button type="submit">Post</button>
    </form>
    <ul>
      {{range .Messages}}
        <li>{{.Body}}<div class="who">{{.Author}} · {{.CreatedAt.Format "15:04:05"}}</div></li>
      {{else}}
        <li>No messages yet.</li>
      {{end}}
    </ul>
  {{end}}
</main>
</body>
</html>`))

func main() {
	if dsn := os.Getenv("DATABASE_URL"); dsn != "" {
		var err error
		db, err = sql.Open("postgres", dsn)
		if err != nil {
			log.Printf("open db: %v", err)
		}
	}

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	http.HandleFunc("/messages", postMessage)
	http.HandleFunc("/", index)

	port := env("PORT", "8080")
	log.Printf("listening on :%s (pr=%s)", port, env("PR_NUMBER", "local"))
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func index(w http.ResponseWriter, r *http.Request) {
	data := pageData{
		PRNumber: env("PR_NUMBER", "local"),
		Commit:   env("GIT_SHA", "dev"),
		Color:    env("BG_COLOR", "#1a4d8f"),
	}

	msgs, err := listMessages()
	if err != nil {
		data.DBError = err.Error()
	} else {
		data.Messages = msgs
	}

	if err := page.Execute(w, data); err != nil {
		log.Printf("render: %v", err)
	}
}

func postMessage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body := strings.TrimSpace(r.FormValue("body"))
	if body == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	if db == nil {
		http.Error(w, "no database configured", http.StatusServiceUnavailable)
		return
	}

	author := "pr-" + env("PR_NUMBER", "local")
	if _, err := db.Exec(`INSERT INTO messages (body, author) VALUES ($1, $2)`, body, author); err != nil {
		log.Printf("insert: %v", err)
		http.Error(w, "could not save message", http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func listMessages() ([]message, error) {
	if db == nil {
		return nil, fmt.Errorf("DATABASE_URL not set")
	}
	rows, err := db.Query(`SELECT body, author, created_at FROM messages ORDER BY created_at DESC LIMIT 20`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []message
	for rows.Next() {
		var m message
		if err := rows.Scan(&m.Body, &m.Author, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
