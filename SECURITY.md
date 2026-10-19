# Security Policy

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
pull requests, or discussions.** Public reports expose users to the very
weakness being reported before a fix is available.

hotshot types screenshot paths into a live terminal and rewrites the system
clipboard, so a bug here can become command execution in the user's AI
session. Report it privately so a fix can ship before the details are public.

Use **private vulnerability reporting**:

1. Go to this repository's **Security** tab.
2. Click **Report a vulnerability** (GitHub's private security advisory flow).
3. Provide a description of the issue and how to reproduce it.

If private reporting is unavailable to you for any reason, email
`security@hivecommons.dev` (the Hive Commons security contact published at
<https://hivecommons.dev/.well-known/security.txt>) rather than opening a
public issue.

Include the platform (macOS app, `linux/hotshot-capture.sh`, or
`windows/hotshot-capture.ps1`), the version or commit, steps to reproduce,
and what a successful exploit achieves. A proof-of-concept filename or
clipboard payload is welcome.

You should hear back within 7 days. We will keep you informed while the
report is triaged and credit you in the fix unless you prefer otherwise.

## Supported versions

Fixes land on `main` and ship in the next release. Only the latest release
and `main` receive security fixes.

## Scope

In scope: anything in this repository — the Swift app under `Sources/`, the
Linux and Windows helper scripts, the installers, and the CI workflows.

Out of scope: vulnerabilities in the AI CLIs hotshot injects into (Claude
Code, Copilot CLI, Aider, OpenCode, …) or in the operating-system capture
tools it drives; please report those upstream.
