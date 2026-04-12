# Research Questions

Open questions that need investigation before planning.

---

## RQ-01: Wails WebView2 memory footprint in multi-user RDS

**Date:** 2026-04-12
**Context:** Architecture re-evaluation — extension → standalone Wails app
**Priority:** High — blocks architecture decision confidence

**Question:** What is the per-instance memory footprint of a Wails app using WebView2 on Windows, both idle and active? How does WebView2's shared runtime model work with 30 concurrent instances on an RDS server?

**Specifically:**
- Baseline idle memory of a minimal Wails tray app
- Memory with a simple queue view open
- How WebView2 shares the Edge runtime across instances (shared process vs per-instance)
- Comparison to current go-mapi-host.exe (~5-10MB)
- Any known issues with WebView2 on Windows Server / RDS

**Why it matters:** 30 users × 200MB = 6GB is unacceptable on shared RDS. 30 × 10-30MB is the target.
