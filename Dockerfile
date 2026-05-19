# Placeholder image. Serves a static "Guild" landing page on :80 via
# nginx so the deploy/Flux pipeline can run end-to-end before the real
# Elixir/Phoenix release Dockerfile lands. Replace this whole file with
# the Phoenix release Dockerfile when the app exists.
FROM nginx:alpine

COPY <<'HTML' /usr/share/nginx/html/index.html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Guild</title>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style>
      html, body { height: 100%; margin: 0; }
      body {
        display: flex; align-items: center; justify-content: center;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: #0b0d10; color: #e7ebef;
      }
      main { text-align: center; }
      h1 { font-size: 4rem; margin: 0 0 0.25rem; letter-spacing: -0.02em; }
      p { color: #8a93a0; margin: 0; }
      code { color: #c4d3df; }
    </style>
  </head>
  <body>
    <main>
      <h1>Guild</h1>
      <p>Placeholder. The real app is on its way.</p>
      <p><code>ghcr.io/jhgaylor/guild</code></p>
    </main>
  </body>
</html>
HTML
