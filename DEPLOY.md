# Deploying the SolarTechy WhatsApp Assistant

This is a **stateful, always-on service** (it holds a live connection to WhatsApp and
keeps a paired-device session on disk). It **cannot** run on serverless platforms like
Vercel/Netlify/Lambda. Deploy it as a long-running container with a **persistent volume**.

Two supported paths, both using the same `Dockerfile`:
- **PaaS with volumes** (Railway / Fly.io / Render) — GitHub-connected, minimal ops.
- **Docker on a VM** (Hetzner / DigitalOcean / EC2) — full control.

---

## What must persist
- **`/app/store`** — the WhatsApp session (`whatsapp.db`) + message SQLite. If this is lost,
  you must re-scan the QR code. Always back this volume.
- **Postgres data** — conversations + customer context.

## The LLM
`OLLAMA_MODEL=gpt-oss:120b-cloud` is a **cloud** model: Ollama forwards inference to Ollama's
hosted service, so the instance stays small. The instance's Ollama must be **signed in**
(`ollama signin`, or set an Ollama API key). Alternatively, swap `OLLAMA_URL`/`OLLAMA_MODEL`
for another endpoint.

---

## Option A — Docker Compose on a VM (recommended to start)

1. **Provision** a small Linux VM (1–2 vCPU, 1–2 GB RAM). Open only **SSH (22)** inbound.
   Nothing else needs a public port.

2. **Install** Docker + Compose, and (for the cloud model) Ollama on the host:
   ```bash
   curl -fsSL https://get.docker.com | sh
   curl -fsSL https://ollama.com/install.sh | sh
   ollama signin          # authenticate for the -cloud model
   ```

3. **Clone** the repo and create a `.env` next to `docker-compose.yml`:
   ```env
   POSTGRES_PASSWORD=change-me-to-a-strong-secret
   OLLAMA_URL=http://host.docker.internal:11434/api/chat
   OLLAMA_MODEL=gpt-oss:120b-cloud
   ```

4. **First run — pair the phone (interactive):**
   ```bash
   docker compose up --build
   ```
   Watch the logs for the QR code, scan it in WhatsApp (Linked devices → Link a device).
   Once you see `Connected to WhatsApp`, press `Ctrl+C`. The session is now saved in the
   `wa_store` volume.

5. **Run detached:**
   ```bash
   docker compose up -d --build
   docker compose logs -f bridge
   ```
   `restart: unless-stopped` reconnects automatically after crashes/reboots.

6. **Verify Postgres is filling up:**
   ```bash
   docker compose exec postgres psql -U solartechy -d solartechy \
     -c "select role, left(content,40) from conversations order by id desc limit 10;"
   ```

### Updating after a code change
```bash
git pull && docker compose up -d --build
```
The `wa_store` and `pgdata` volumes survive rebuilds — no re-pairing.

---

## Option B — Railway / Fly.io / Render (GitHub-connected)

Same `Dockerfile`. Key settings on any of them:
- Deploy as a **long-running service / background worker** (NOT a serverless function).
- Attach a **persistent volume mounted at `/app/store`**.
- Use the platform's **managed Postgres** and set `DATABASE_URL` from it (schema in
  `assistant/db/schema.sql` — run it once against the managed DB).
- Set env: `OLLAMA_URL`, `OLLAMA_MODEL`, `SOLARTECHY_KB_DIR=/app/assistant/knowledge`.
- **First run:** open the live logs, scan the QR once. The mounted volume keeps the session.
- Do **not** expose port 8080 publicly.

---

## Accessing the Postgres DB remotely (via SSH)

Postgres is bound to the VM's loopback (`127.0.0.1:5432`) — not reachable from the
internet. Reach it from your laptop through an **SSH tunnel** (no extra ports opened):

```bash
# On your laptop — forward local 5433 to the VM's 127.0.0.1:5432. Leave this running.
ssh -N -L 5433:localhost:5432 <user>@<VM_IP>
```

Then, in another terminal / your GUI client, connect to `localhost:5433`:

```bash
psql "postgres://solartechy:<POSTGRES_PASSWORD>@localhost:5433/solartechy?sslmode=disable"
```

(`sslmode=disable` is fine — the connection is already encrypted by SSH.) For a GUI
tool (TablePlus / DBeaver / pgAdmin): host `localhost`, port `5433`, db `solartechy`,
user `solartechy`.

**Quick one-off queries without a tunnel** — just SSH in and use the container:

```bash
ssh <user>@<VM_IP>
docker compose exec postgres psql -U solartechy -d solartechy
```

## Security & operational notes
- **Never expose port 8080** to the internet — the REST API has no authentication.
- Keep **Postgres private** (compose network only) unless you need remote admin; if you do,
  require TLS + strong credentials + IP allow-listing.
- **Back up** the `wa_store` volume (session) and `pgdata` regularly.
- **WhatsApp ToS / ban risk:** this uses an unofficial client (whatsmeow). For outreach/sales,
  use a dedicated number, ramp volume slowly, and prefer inbound replies. Account bans are a
  real risk with high-volume unsolicited messaging.
- Before going wide, add the **dry-run flag + number allowlist** (plan Phase 8) so a bad prompt
  can't message every customer.
