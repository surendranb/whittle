# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Use GitHub's private reporting: **Security tab → "Report a vulnerability"** on this repository. You will get a first response within 7 days.

## Scope

Whittle is a local macOS app. It has no server and no account system.
The app talks only to:

- a local model server you run (LM Studio or Ollama, loopback only),
- Google's Gemini API, only if you add your own key,
- nothing else.

Reports we care about most: anything that lets photos leave the Mac without clear user intent, anything that exposes the user's API key, and anything that deletes photos without the user's explicit confirmation.

## Supported versions

Only the latest release is supported. Fixes ship as a new release.
