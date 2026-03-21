# PRD: Key-Vending Service for Meeting Recorder

**Status:** Draft
**Author:** Michael Zaro / Claude
**Date:** 2026-03-20

---

## Problem

Meeting Recorder requires an AssemblyAI API key for transcription. Currently, users must obtain and paste their own key during onboarding. For a small group of users (5-10 friends/colleagues), Michael wants to provide transcription access using his own AssemblyAI account without sharing the raw API key directly.

Sharing the key directly has issues:
- Can't revoke one person's access without rotating the key for everyone
- No visibility into who's using it or how much
- Key could leak if someone's machine is compromised

## Solution

A lightweight **key-vending service** — a Cloudflare Worker that validates a user token and returns the AssemblyAI API key. The audio never touches the server; users upload directly to AssemblyAI.

## How It Works

```
┌─────────────┐         ┌──────────────────┐         ┌──────────────┐
│  Meeting     │  POST   │  Cloudflare      │         │  AssemblyAI  │
│  Recorder    │────────▶│  Worker          │         │              │
│  App         │  token  │                  │         │              │
│              │◀────────│  validates token  │         │              │
│              │  API key│  returns API key  │         │              │
│              │         └──────────────────┘         │              │
│              │                                      │              │
│              │  upload audio + transcribe            │              │
│              │─────────────────────────────────────▶│              │
│              │◀─────────────────────────────────────│              │
│              │  transcript                          │              │
└─────────────┘                                      └──────────────┘
```

### Request/Response

**Request:**
```
POST https://keys.lightswitchlabs.ai/api/key
Authorization: Bearer <user-token>
```

**Response (success):**
```json
{
  "key": "sk-assembly-...",
  "expires_in": 3600
}
```

**Response (invalid token):**
```json
{
  "error": "unauthorized"
}
```
Status: 401

**Response (revoked token):**
```json
{
  "error": "token_revoked"
}
```
Status: 403

## Architecture

### Platform: Cloudflare Workers

| Factor | Detail |
|--------|--------|
| **Cost** | Free tier: 100k requests/day. More than enough for 10 users doing ~5 meetings/day each. |
| **Latency** | Edge-deployed globally, <50ms response times |
| **Cold start** | None (Workers are always warm) |
| **Storage** | Cloudflare KV for token registry |
| **Custom domain** | `keys.lightswitchlabs.ai` (or similar subdomain) |
| **HTTPS** | Automatic via Cloudflare |

### Token Registry (Cloudflare KV)

Each token is a KV entry:

**Key:** the token string (a UUID or random 32-char hex)
**Value:**
```json
{
  "name": "Jon Zaro",
  "created": "2026-03-20",
  "active": true
}
```

### API Key Storage

The AssemblyAI API key is stored as a **Cloudflare Worker secret** (encrypted environment variable, never visible in code or logs).

### Admin Operations

Managed via `wrangler` CLI (Cloudflare's tool):

| Operation | Command |
|-----------|---------|
| Create token | `wrangler kv:key put --binding=TOKENS "<token>" '{"name":"Jon","created":"2026-03-20","active":true}'` |
| Revoke token | `wrangler kv:key put --binding=TOKENS "<token>" '{"name":"Jon","created":"2026-03-20","active":false}'` |
| Delete token | `wrangler kv:key delete --binding=TOKENS "<token>"` |
| List tokens | `wrangler kv:key list --binding=TOKENS` |
| Rotate API key | `wrangler secret put ASSEMBLYAI_API_KEY` (type new key) |

**Future:** If the user count grows beyond what CLI management is comfortable for, build a simple admin web page. Not needed for 5-10 users.

## App Changes

### Onboarding Update

Step 3 ("Paste your AssemblyAI API key") is replaced with:

**"Paste your access token"**
- User pastes the token Michael gives them → stored in Keychain as `MEETING_RECORDER_TOKEN`
- App calls key-vending service at transcription time
- No option for direct API key — single path, simple UX

### Transcription Flow Update

In `PipelineHandoff.swift`, before invoking `call-analyzer.py`:

```
1. Load MEETING_RECORDER_TOKEN from Keychain
2. POST to key-vending service with token
3. Receive API key
4. Pass to call-analyzer.py via ASSEMBLYAI_API_KEY env var
5. If no token or service unavailable: skip transcription, notify user
```

The fetched API key is used for that single transcription — it's not cached or persisted. Fresh fetch each time (latency is negligible at <50ms).

### call-analyzer.py

No changes needed. It already reads `ASSEMBLYAI_API_KEY` from the environment. The Swift app sets this env var before invoking the script, regardless of whether the key came from the vending service or direct Keychain storage.

## Security Considerations

| Concern | Mitigation |
|---------|------------|
| Token brute-force | Tokens are 32+ char random hex — practically unguessable. Add rate limiting (Cloudflare built-in). |
| API key exposure to client | The key is briefly in memory on the client. Unavoidable without a full proxy. Acceptable risk for a trusted user group. |
| Token leak | Individual tokens can be revoked without affecting other users. |
| API key rotation | Change the Worker secret — all users get the new key automatically on next request. No client update needed. |
| Man-in-the-middle | HTTPS enforced by Cloudflare. |
| Worker logs | Cloudflare Workers don't log request/response bodies by default. API key never appears in logs. |

## Scope & Estimates

### In Scope

- [ ] Cloudflare Worker with token validation + key return
- [ ] Cloudflare KV namespace for token registry
- [ ] Custom domain setup (`keys.lightswitchlabs.ai` or similar)
- [ ] App onboarding update (token-only flow)
- [ ] PipelineHandoff update (fetch key from service)
- [ ] Generate initial tokens for Michael + coworker

### Out of Scope (for now)

- Admin web UI for token management
- Usage tracking/analytics per token
- Rate limiting per token (Cloudflare global rate limiting is sufficient)
- Multiple API key support (e.g., different keys per user)

### Effort

| Component | Estimate |
|-----------|----------|
| Cloudflare account + Worker + KV setup | 30 min |
| Worker code (token validation + key return) | 30 min |
| Domain/DNS configuration | 15 min |
| App changes (onboarding + PipelineHandoff) | 30 min |
| Token generation for initial users | 10 min |
| Testing end-to-end | 30 min |
| **Total** | **~2.5 hours** |

## Prerequisites

Before starting implementation, Michael needs to:

1. **Create a Cloudflare account** at [dash.cloudflare.com](https://dash.cloudflare.com) (free tier)
2. **Add lightswitchlabs.ai domain** to Cloudflare (or confirm where DNS is currently managed — we need to add a CNAME or move nameservers)
3. **Install wrangler CLI:** `npm install -g wrangler` then `wrangler login`

## Decisions Made

- **Single auth path:** Token only — no option for direct API key. Keeps onboarding simple.
- **Token expiry:** None. Tokens are valid until manually revoked.
- **Domain:** `keys.lightswitchlabs.ai`
- **Token format:** UUIDs
- **Revocation UX:** App shows a clear message if token is revoked, telling user to contact Michael.
