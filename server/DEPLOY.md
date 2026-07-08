# Deploying the MicText server fallback (stt.flexsolutions.ph)

The dev box can't do these steps (restricted prod gate, no aws CLI, repo-creation
needs your say-so). Everything below is one-time, in order.

## 1. GitHub repo

```bash
cd ~/Personal/mictext
gh repo create dieterstemmet/mictext --private --source . --push
```

## 2. DNS

Route53 (account 494327826930, zone `Z0828140M9CUSR7YWTSG`, profile `flex`):
A record `stt.flexsolutions.ph → 5.223.51.1`.

## 3. On the server (root@5.223.51.1)

```bash
git clone git@github.com:dieterstemmet/mictext.git /root/projects/mictext
cd /root/projects/mictext/server

# Secrets — one key per consuming app, comma-separated:
#   openssl rand -hex 24   (once per key: agent-platform, mac-client, ...)
cat > .env <<'ENV'
API_KEYS=<key-agent-platform>,<key-mac-client>
WHISPER_MODEL=small.en
ALLOWED_ORIGINS=https://ai.flexsolutions.ph
ENV
chmod 600 .env

docker compose up -d --build
```

First transcription downloads the model into the `whisper-models` volume (one-time).

## 4. Verify

```bash
curl -s https://stt.flexsolutions.ph/health
# {"status":"ok","model":"small.en"}

ffmpeg -f lavfi -i "sine=frequency=440:duration=2" /tmp/sample.wav
curl -s -X POST https://stt.flexsolutions.ph/transcribe \
  -H "X-API-Key: <key>" -F audio=@/tmp/sample.wav
# {"text":"...","duration_ms":2000-ish}

curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://stt.flexsolutions.ph/transcribe -F audio=@/tmp/sample.wav
# 401
```

## 5. Enable the fallback in agent-platform (optional, after PR #240 is live)

Add to `/root/agent-platform/.env` (frontend build args) and redeploy:

```
VITE_STT_FALLBACK_URL=https://stt.flexsolutions.ph
VITE_STT_FALLBACK_KEY=<key-agent-platform>
```

Unset = pure on-device (mic hidden on devices too slow to run Whisper).
The VITE key is baked into the served bundle — that's accepted: it's a
low-privilege, revocable, STT-only key.

## Ops notes

- No DB, no state: nothing to add to backup crons. The model volume re-downloads itself.
- Serial transcription by design (semaphore 1) — two concurrent jobs would OOM the box.
- Consider adding `mictext` to the ops-gate deploy list for future `ssh prod-ops deploy mictext`.
