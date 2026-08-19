CREATE TABLE IF NOT EXISTS messages (
    id         SERIAL PRIMARY KEY,
    body       TEXT NOT NULL,
    author     TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO messages (body, author)
SELECT 'This environment has its own database, seeded on deploy.', 'seed'
WHERE NOT EXISTS (SELECT 1 FROM messages);

INSERT INTO messages (body, author)
SELECT 'Messages posted here are invisible to other pull requests.', 'seed'
WHERE (SELECT count(*) FROM messages) < 2;
