# SolarTechy WhatsApp AI Assistant — Plan of Action

> Turns the existing WhatsApp bridge into an autonomous **AI Sales & Support Executive** for SolarTechy:
> answers product/pricing/tutorial questions from a knowledge base, builds a customer profile over time,
> knows when to stay silent, and escalates to a human when it should.

---

## 0. Where we are today (honest assessment)

| Component | State | Notes |
|---|---|---|
| `whatsapp-bridge/main.go` | Working | Connects to WhatsApp (whatsmeow), stores every message in `store/messages.db` (SQLite), exposes REST `/api/send` + `/api/download` on `:8080`. |
| Auto-reply (uncommitted) | Prototype | `generateReply()` (main.go:73–122) calls local **Ollama** (`gpt-oss:120b-cloud`) with a generic system prompt and falls back to `"Good morning"`. `handleMessage()` auto-replies to **every** inbound text (main.go:547–558). |
| `whatsapp-mcp-server/` (Python MCP) | Working | Stdio MCP for Claude Desktop — a *separate* consumer. Not the autonomous assistant. |
| Knowledge base | Missing | Only exists as text in the design chat. |
| CRM / customer DB | Missing | |
| Escalation store + handoff | Missing | |
| "Should I reply?" logic | Missing | Currently replies to everything, including "ok", "thanks", emojis. |

**The gap:** the current auto-reply is a stateless, always-on, generic responder. SolarTechy needs a stateful, context-aware, KB-grounded assistant that often chooses *not* to reply.

**Core architectural decision:** keep the **Go bridge thin**. It should only (1) receive & store messages and (2) send messages. All intelligence (KB retrieval, CRM, state machine, structured output, escalation) moves to a **new Python assistant service**. Rationale: retrieval, DB modeling, prompt orchestration, and JSON handling are far cheaper to build and iterate in Python, and the bridge already speaks HTTP.

---

## 1. Target architecture

```
Incoming WhatsApp message
        │  (whatsmeow event)
        ▼
Go bridge  ──── stores msg in messages.db
        │
        │  HTTP POST /assistant/incoming  { chat_jid, sender, text, message_id, timestamp }
        ▼
Python Assistant Service  (NEW — assistant/)
        │
        ├─ 1. Load customer profile (by phone)         ── crm.db
        ├─ 2. Load recent history (last ~20–30 msgs)   ── messages.db (read-only)
        ├─ 3. Load rolling summary                     ── crm.db
        ├─ 4. Route intent → select KB files           ── knowledge/*.md
        ├─ 5. Build prompt (always-on files + retrieved + profile + history)
        ├─ 6. Call LLM → STRUCTURED JSON
        │        { shouldReply, reply, conversationState,
        │          customerUpdates, internalNotes, escalation }
        ├─ 7. Persist customerUpdates, state, summary    ── crm.db
        ├─ 8. If escalation.required → insert escalation + notify team
        │
        ▼
   if shouldReply and reply != "":
        HTTP POST http://localhost:8080/api/send  { recipient: chat_jid, message: reply }
   else:
        do nothing (silence)
```

**Why a separate service, not the MCP server:** the MCP server (`main.py`) is a stdio tool provider for Claude Desktop — a human-in-the-loop consumer. The assistant is a headless daemon. Different lifecycle, different entry point. They can share the `whatsapp.py` helpers if useful.

---

## 2. Repository layout to add

```
whatsapp-mcp/
├─ assistant/                     # NEW autonomous brain
│  ├─ server.py                   # FastAPI/Flask: POST /assistant/incoming
│  ├─ pipeline.py                 # orchestration (steps 1–8 above)
│  ├─ llm.py                      # provider-agnostic LLM call → JSON (Ollama / Claude / OpenAI)
│  ├─ retrieval.py                # intent routing + file selection (+ optional semantic search)
│  ├─ crm.py                      # customer, conversation-summary, escalation DB access
│  ├─ prompts/
│  │  ├─ system.md                # master persona + rules (see §6)
│  │  └─ output_schema.json       # JSON schema the LLM must satisfy
│  ├─ knowledge/                  # the MD knowledge base (see §3)
│  ├─ config.py                   # provider keys, thresholds, feature flags
│  └─ tests/                      # replay transcripts, silence tests, escalation tests
├─ docs/solartechy-assistant-plan.md   # this file
```

Add `crm.db` to `.gitignore` (already ignores `*.db`). Never commit knowledge base secrets/PII.

---

## 3. Phase 1 — Knowledge base (`assistant/knowledge/*.md`)

Author these from the design chat. Keep each file focused; the router loads only what's relevant.

**Always loaded (small, every turn):**
- `company.md` — what SolarTechy is, founder (Atharva, ex-IITian), online-only, target users (installers/EPCs/consultants).
- `contact.md` — support contact, business number **7066711089**, support hours.
- `knowledge_index.md` — one-line map: "pricing → pricing.md", etc. (helps the model even with routing).

**Loaded on intent:**
- `services.md` — 3D rooftop design, quotations, CAD-like precision mode, calculations (inverter sizing, strings, DC/AC, generation, savings, cable/voltage, shadow analysis), CRM/leads/tasks/documents.
- `pricing.md` — **Currently FREE for early users. Never invent or estimate future prices.**
- `tutorials.md` — the 3 tutorial videos + "recommended when user asks…" triggers (URLs from chat).
- `faq.md` — ~20–30 *core* FAQs (not 120). Let the LLM generalize variations.
- `support.md` — supported devices (Chrome on desktop/laptop; mobile & tablet **not** supported), login/troubleshooting.
- `sales.md` + `demo.md` — outreach flow, onboarding sessions, what to collect for a demo → then escalate.
- `escalation.md` — the triggers list (demo, enterprise, partnership, payment, refund, bug, feature request, legal/media/gov, "talk to human", anything not in KB).
- `policies.md` / `uploads.md` — data security, no upload limits (for now).

**Rule baked into content:** every file that could go stale (pricing, upload limits, device support) carries a "if unknown, do not guess" note.

**Deliverable:** ~10 short MD files. Start with `company`, `contact`, `services`, `pricing`, `faq`, `tutorials`, `escalation` — enough to go live.

---

## 4. Phase 2 — Local databases

Reuse existing `store/messages.db` **read-only** for history. Create a new `store/crm.db`:

```sql
CREATE TABLE customers (
  phone_number   TEXT PRIMARY KEY,   -- normalized, digits only
  name           TEXT,
  company_name   TEXT,
  designation    TEXT,
  email          TEXT,
  city           TEXT,
  state          TEXT,
  business_type  TEXT,
  current_software TEXT,
  monthly_projects TEXT,
  interested_services TEXT,
  lead_status    TEXT,               -- NEW / INTERESTED / QUALIFIED / DEMO / CUSTOMER / COLD
  lead_score     INTEGER DEFAULT 0,
  conversation_state TEXT,           -- see §6 state list
  rolling_summary TEXT,              -- long-term memory
  assigned_to    TEXT,
  notes          TEXT,
  last_contact_time TIMESTAMP,
  created_at     TIMESTAMP,
  updated_at     TIMESTAMP
);

CREATE TABLE escalations (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  phone_number   TEXT,
  customer_name  TEXT,
  company_name   TEXT,
  category       TEXT,               -- DEMO / ENTERPRISE / PAYMENT / BUG / ...
  priority       TEXT,               -- LOW / MEDIUM / HIGH
  summary        TEXT,
  conversation_snapshot TEXT,        -- last N messages as text
  status         TEXT DEFAULT 'PENDING',  -- PENDING / IN_PROGRESS / RESOLVED
  assigned_to    TEXT,
  internal_notes TEXT,
  created_at     TIMESTAMP
);
```

Conversation history already lives in `messages.db` — no need to duplicate. The assistant reads it for short-term memory.

---

## 5. Phase 3 — Retrieval router (`retrieval.py`)

The chat's key correction: **don't rely on `message.includes("price")`** — synonyms break it. Three-layer strategy:

1. **Intent classification** via the LLM (or a cheap classifier call): map message → one/few intents (`pricing`, `features`, `support`, `tutorial`, `sales/demo`, `greeting`, `bug`, `unknown`).
2. **File selection** from intent → load the matching MD files + the always-on set.
3. **(Optional, later) semantic search** *within* the selected files to trim tokens. Skip for v1 — the files are small; send them whole.

Fallback: intent `unknown` or answer-not-in-context → **do not guess** → set `escalation.required=true` (category `KB_GAP`) and reply with the "noted, team will get back" line.

---

## 6. Phase 4 — The brain: persona, state, and structured output

### Master system prompt (`prompts/system.md`) — enforce these rules
- You are a SolarTechy **Sales & Support Executive**, not a generic chatbot. Friendly, professional, honest, concise. Sound like an experienced solar engineer.
- **Never invent information.** If the answer isn't in the provided context → reply: *"I'm not certain about that. I've noted your question and our SolarTechy team will get back to you shortly."* and flag escalation.
- **Silence rule:** if the message is only an acknowledgement ("ok", "thanks", 👍), if the conversation has naturally ended, or if replying adds no value → return `shouldReply=false`, `reply=""`. (Describe the *intent* — do not hard-code a phrase blocklist.)
- **Gradual info collection:** never interrogate. Answer first. Ask for **one** missing detail only when it fits the flow (and generally not in the first 1–2 messages, unless required for a demo/troubleshooting). Never re-ask for known fields.
- **Escalation:** on any trigger in `escalation.md`, collect what's needed, set `escalation.required=true`, tell the user a human will follow up. Do **not** promise to schedule/act yourself.

### Conversation states
`GREETING · PRODUCT_INQUIRY · FEATURE_DISCUSSION · PRICING · TUTORIAL · LEAD_QUALIFICATION · DEMO_REQUEST · SUPPORT · WAITING_FOR_CUSTOMER · ESCALATED · CLOSED`

### Required LLM output contract (`output_schema.json`)
```json
{
  "shouldReply": true,
  "reply": "Yes — SolarTechy lets you create 3D rooftop proposals in minutes.",
  "conversationState": "FEATURE_DISCUSSION",
  "customerUpdates": { "company_name": "ABC Solar" },
  "internalNotes": { "lead_score": 7, "interest": "Proposal generation" },
  "escalation": { "required": false, "category": null, "priority": null, "summary": null }
}
```
Backend is responsible for acting on this (send / persist / escalate). Use the provider's **structured-output / JSON mode** so parsing is reliable (a big reason to consider Claude or OpenAI over raw Ollama for v1).

---

## 7. Phase 5 — Wire the Go bridge to the assistant

Replace the current always-reply block. In `handleMessage()` (main.go:547–558):

- **Remove** the direct `generateReply()` + unconditional `sendWhatsAppMessage()`.
- **Instead** POST the inbound message to the assistant: `POST http://localhost:8080-style → assistant :8000 /assistant/incoming`.
- The **assistant** decides and calls back the existing `/api/send`. The bridge no longer decides whether/what to reply.
- Keep `generateReply()`/Ollama code path behind a feature flag as a fallback for now; delete once the assistant is trusted.

Guards to add in the bridge before forwarding:
- Skip group messages (`chat_jid` ends `@g.us`) unless explicitly enabled — the assistant is for 1:1 sales chats.
- Skip `IsFromMe`.
- Skip media-only messages for v1 (log them; optionally escalate "customer sent an image").

---

## 8. Phase 6 — Memory

- **Short-term:** read last ~20–30 messages from `messages.db` for this `chat_jid`, pass as history.
- **Long-term:** maintain `customers.rolling_summary`. After each turn (or every N turns) ask the LLM to update a compact summary (name, company, city, interests, demo status, open issues). Include it in every prompt so the assistant never re-asks and stays coherent across days. Avoid resending full history.

---

## 9. Phase 7 — Human handoff

When `escalation.required=true`:
1. Insert row into `escalations`.
2. Notify the team — options (pick one for v1): (a) forward a formatted card to an internal WhatsApp group / the team's number via `/api/send`; (b) Slack webhook; (c) email. Simplest given the stack: **send to an internal WhatsApp number**.
3. Set `customers.conversation_state = ESCALATED`; assistant should go quiet on that thread (only acknowledge) until a human takes over. Consider a manual `/resume` toggle.

---

## 10. Phase 8 — Safety, anti-spam, testing, rollout

- **Anti-spam / account safety:** the assistant is **inbound-reply only** (never mass-initiates). This is exactly the safe pattern the chat recommended vs. blasting 800 contacts. Add per-chat rate limiting and a max-messages-per-conversation guard.
- **Kill switch / dry-run mode:** config flag to log the intended reply *without sending* — essential for the first days.
- **Business-hours behavior:** optionally hold or soften replies outside hours (state `WAITING_FOR_CUSTOMER`).
- **Testing:** build `assistant/tests/` with recorded transcripts asserting: (1) correct silence on "ok/thanks/👍", (2) no hallucinated pricing, (3) escalation fires on demo/payment/bug, (4) info collected gradually, not up front, (5) known fields never re-asked.
- **Rollout:** dry-run → enable for a whitelist of 2–3 test numbers → widen. Keep Ollama fallback until confident.
- **Provider choice (decide in Phase 0):** Ollama (already wired, cheap, but weaker JSON adherence) vs Claude API vs OpenAI (better structured output). Keep `llm.py` provider-agnostic so this is a one-file swap.

---

## Build order (fastest path to a safe live pilot)

1. **Phase 1 (partial):** author `company/contact/services/pricing/faq/tutorials/escalation` MD files.
2. **Phase 2:** create `crm.db` schema.
3. **Phase 3–4:** `assistant/` service — retrieval router + system prompt + structured LLM call, returning the JSON contract. Start with `shouldReply` + `reply` + `escalation` only; add profile/summary next.
4. **Phase 5:** point the Go bridge at the assistant (behind a flag), in **dry-run**.
5. **Silence + escalation** correctness pass (Phase 5 rules, Phase 7 handoff).
6. **Phase 6 memory** (profile + rolling summary), gradual info collection.
7. Widen rollout; delete the Ollama fallback.

**Minimum viable pilot = steps 1–5:** grounded answers, correct silence, and human escalation. CRM enrichment and long-term memory can follow once the core loop is trusted.
