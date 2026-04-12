---
title: "Enterprise control plane for managed deployments"
trigger_condition: "When standalone Wails GUI app is stable and automode works"
planted_date: 2026-04-12
---

## Idea

Centralized management control plane for enterprise deployment of go-mapi. The standalone app would phone home for policy, configuration, and managed updates.

## Why

Marc's main deployment target includes RDS environments with 30+ users. Enterprise customers need:
- Centralized policy enforcement (allowed senders, automode settings)
- Managed update rollout (staged, not all-at-once)
- Configuration distribution (OAuth client IDs, default settings)
- Usage visibility (not telemetry — admin-facing deployment health)

## Breadcrumbs

- Autoupdate mechanism in Wails app is the foundation
- OAuth flow already needs per-deployment client IDs
- Automode settings are the first "policy" candidates

## When to surface

During milestone planning after the Wails migration is complete and automode is working. Don't attempt before the base app is stable.
