# Knowledge Index

This index maps customer topics to the knowledge files where the answer lives.
The assistant should load the relevant file(s) based on the customer's intent,
plus the always-loaded core files.

## Always loaded (every conversation)
- `company.md` — what SolarTechy is, who it's for, founder
- `contact.md` — website, tutorials link, business number
- `knowledge_index.md` — this file

## Loaded based on intent
| Customer is asking about… | Load these files |
|---|---|
| What SolarTechy is / getting started / registration / dashboard | `company.md`, `services.md`, `tutorials.md` |
| Features, design, engineering, reports | `services.md`, `faq.md` |
| Price, plans, is it free, subscriptions | `pricing.md` |
| Tutorials / how-to / videos | `tutorials.md`, `services.md` |
| Login issues, password, supported devices, bugs | `support.md`, `faq.md` |
| Demo request / onboarding | `demo.md`, `sales.md` |
| Sales / partnership / enterprise / reseller | `sales.md`, `escalation.md` |
| Data security, privacy, uploads, refunds, policies | `policies.md`, `escalation.md` |
| Anything requiring a human | `escalation.md` |

## Golden rule
If the answer is **not** present in the loaded files, do **not** guess.
Acknowledge the question, tell the customer the team will follow up, and raise an escalation
(see `escalation.md`).
