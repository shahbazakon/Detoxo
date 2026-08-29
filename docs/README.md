# Detoxo — Documentation

Documentation for **Detoxo**, an Android-first short-form-content (Reels / Shorts / infinite-feed)
**blocker + on-device reel counter** built in **Flutter (flutter_bloc + get_it + go_router,
feature-first Clean Architecture)** with a native **Android AccessibilityService** engine
(`com.errorxperts.detoxo`).

These docs are written **from the shipped source code**. Two audiences, two folders:

## 📘 [`code_docs/`](code_docs/) — engineering
How the app actually works: architecture, the native detection/block engine, config schema,
plans, blockers, persistence, the channel contract, and the build's status. Start at
[`code_docs/00-index.md`](code_docs/00-index.md).

## 📗 [`info_docs/`](info_docs/) — end-user & marketing
What Detoxo does, how to use each feature, why each permission is needed, and FAQs. Start at
[`info_docs/00-index.md`](info_docs/00-index.md).

## 📙 [`plan_docs/`](plan_docs/) — forward-looking feature plan
What Detoxo is going to do **next**, milestone by milestone (M0–M8). Shipped since: the category
catalog and usage-stats layer (M0), the block-screen overlay (M1), the rules engine (M3) and real
screen-time insights (M4). Still ahead: waiting-room friction and the emergency pass, notification
suppression, the onboarding step machine, the soft nudge, and locked rules with per-target unblock.
Start at [`plan_docs/00-index.md`](plan_docs/00-index.md).

> `code_docs/` describes Detoxo **as shipped**; `plan_docs/` describes what is planned. A milestone
> graduates by having its engineering doc written into `code_docs/` and its plan doc stamped
> `Status: shipped`.

## 📕 [`suggestion_docs/`](suggestion_docs/) — source material (reference only)
A port guide derived from a decompile of a different app. It is **input**, not a decision: what
Detoxo actually takes from it is decided in
[`plan_docs/00-index.md`](plan_docs/00-index.md#adoption-matrix--all-27-suggestion-docs).

---

### Keeping docs in sync
When code changes, the matching doc changes with it. The feature→doc mapping and update
checklist live in [`.claude/skills/docs-sync/SKILL.md`](../.claude/skills/docs-sync/SKILL.md)
(run `/docs-sync`); the rule is summarized in the project [`CLAUDE.md`](../CLAUDE.md).
