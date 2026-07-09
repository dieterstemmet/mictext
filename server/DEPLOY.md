# Deploying the MicText server fallback

One-time setup for a self-hosted fallback endpoint (the target of the web
library's explicit `slowDevice: 'server'` opt-in).

## 1. DNS

Create an A record for your STT hostname (e.g. `stt.example.com`) pointing
at your server.

## 2. On the server

```bash
git clone git@github.com:dieterstemmet/mictext.git
cd mictext/server

# Secrets — one key per consuming app, comma-separated:
#   openssl rand -hex 24   (once per key: web-app, mac-client, ...)
cat > .env <<'ENV'
API_KEYS=<key-web-app>,<key-mac-client>
WHISPER_MODEL=small.en
ALLOWED_ORIGINS=https://your-web-app.example.com
ENV
chmod 600 .env

docker compose up -d --build
```

The compose file assumes a Traefik reverse proxy on an external
`traefik-public` network handling TLS — adjust the labels (or strip them and
front it however you like) for your setup.

First transcription downloads the model into the `whisper-models` volume (one-time).

## 3. Verify

```bash
curl -s https://stt.example.com/health
# {"status":"ok","model":"small.en"}

ffmpeg -f lavfi -i "sine=frequency=440:duration=2" /tmp/sample.wav
curl -s -X POST https://stt.example.com/transcribe \
  -H "X-API-Key: <key>" -F audio=@/tmp/sample.wav
# {"text":"...","duration_ms":2000-ish}

curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://stt.example.com/transcribe -F audio=@/tmp/sample.wav
# 401
```

## 4. Wire up a consuming web app

Give the web library the endpoint + key (for a Vite app, as build-time env):

```
VITE_STT_FALLBACK_URL=https://stt.example.com
VITE_STT_FALLBACK_KEY=<key-web-app>
```

Unset = pure on-device (mic hidden on devices too slow to run Whisper).
A key baked into a served bundle is an accepted tradeoff: it's a
low-privilege, revocable, STT-only key.

## Ops notes

- No DB, no state: nothing to back up. The model volume re-downloads itself.
- Serial transcription by design (semaphore 1) — two concurrent jobs would
  OOM a small box.
