package main

// indexPage answers the relay's root address. It says what the address is and nothing about
// the servers, members or version behind it: the page is public.
const indexPage = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Server Monitor relay</title>
<style>
:root { color-scheme: light dark; --bg: #F6F7F9; --card: #FFFFFF; --text: #0B0D10; --muted: #5B636E; --line: #E2E5EA; --in: #0070BA; --ok: #12925A; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #0B0D10; --card: #14171C; --text: #FFFFFF; --muted: #A3AAB4; --line: #262B33; --in: #009CDE; --ok: #3DD68C; }
}
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 16px; background: var(--bg); color: var(--text);
  font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { width: 100%; max-width: 440px; padding: 28px; background: var(--card); border: 1px solid var(--line); border-radius: 18px; }
h1 { margin: 0 0 8px; font-size: 24px; letter-spacing: -0.3px; }
p { margin: 0; color: var(--muted); }
.status { display: flex; align-items: center; gap: 8px; margin-bottom: 16px; font-size: 14px; font-weight: 600; color: var(--ok); }
.dot { width: 9px; height: 9px; border-radius: 50%; background: var(--ok); }
.brand { margin-top: 22px; padding-top: 16px; border-top: 1px solid var(--line); font-weight: 700; }
.brand span { color: var(--in); }
</style>
</head>
<body>
<main>
  <div class="status"><i class="dot"></i>Relay is running</div>
  <h1>Server Monitor relay</h1>
  <p>This address connects the Server Monitor app with the servers it watches. There is nothing to sign in to here. Enter this address in the app under Team, or join with an invite.</p>
  <div class="brand">app<span>in</span>source</div>
</main>
</body>
</html>
`
