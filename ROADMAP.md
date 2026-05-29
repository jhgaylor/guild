# Roadmap

The captain-picard orchestrator reads this every cycle and writes the conversation id of each dispatched slice into "Now." Keep this file under one screen — if it grows, kill or defer something.

## Orchestrator

- captain-picard — conv `a42b667b-260d-44f1-8779-7d33da89cd06` (kicked off 2026-05-19 for phase-0-framing). Resume with `fountain conv prompt a42b667b-260d-44f1-8779-7d33da89cd06 -p "..."` — never start a fresh `fountain run` while this is active.

## Now

- **g4-slices-4-5** — In progress. Slack adapter (`Guild.Adapters.Slack`) + Linear adapter (`Guild.Adapters.Linear`). Branch: `g4/slice-4-5-adapters`. Brief: [`plan/g4-slice-4-5/general-purpose-engineer-brief.md`](plan/g4-slice-4-5/general-purpose-engineer-brief.md).

## Done

- **g4-slice-3** — PR #30 merged (339b326). Retention (ADR 0009: keep recent 200 decisions/thread, null `context_snapshot` on older rows — `Guild.Retention`), summarization (ADR 0007: summarize via Fountain past 50-note threshold, archive superseded notes — `Guild.Summarization`), and LiveView socket auth (`GuildWeb.OperatorAuth` `on_mount` + `live_session` closes the `/live` WS bypass; BasicAuth now sets a session flag). 261 tests green. Driver dropped an env-specific rebar3 `mix.exs` hack the worker had injected (would break clean/fork builds) before merge.
- **g4-slice-2** — PR #29 merged (4934eac). Durable claim queue via Oban (ADR 0010): `ClaimWorker` on `:claims` queue, args-unique, retry-with-backoff; webhook now enqueues via `Oban.insert` and returns 200 immediately (replaced `Task.start`); Slice-1 advisory lock retained as second-layer guard. 251 tests green. Driver merged.
- **g4-adr-0010** — PR #28 merged (56062b7). Durable claim queue ADR: Oban accepted over Broadway (over-engineered for low volume) and hand-rolled (recreates solved problems). Operator-approved.
- **g4-slice-1** — PR #27 merged (e79c9c6). Race fix (advisory-lock `claim_issue`), UI BasicAuth on `/threads`,`/decisions`,`/threads/:id`, `SECRET_KEY_BASE` fail-fast. Follow-up fix (9a3b5e2) moved auth creds to a request-time function plug — original compile-time `Plug.BasicAuth` opts baked `nil` into the release router. 248 tests green. Driver merged.
- **g4-slice-plan** — PR #26 merged (4aaa848). Six slices covering all 8 G4 framing items; ADR stubs 0010–0013 (Draft). Driver approved plan as-is.

- **phase-0-framing** — PR #1 merged. G0 resolved: Wedge B selected.
- **g1-wedge-b-plan** — PR #2 merged (4d7cf34). Engineering plan locked.
- **g1-adrs** — PR #4 merged (73e4155). ADRs 0005–0009 locked.
- **g2-slice-plan** — PR #5 merged (b94d49d). G2 slice decomposition locked.
- **g2-slice-1** — PR #6 merged (404d8ee). Phoenix scaffold + Ecto + all five schemas.
- **g2-slice-2** — PR #7 merged (ac885d6). State machine + context assembly + worker contracts.
- **g2-slice-3** — PR #8 merged (5bcbdb0). Action primitives + Fountain adapter.
- **g2-slice-4** — PRs #9+#10 merged (da3f05a/9da21e3). ClaimSeed + implementer agent registered.
- **g2-slice-5** — PRs #11+#13 merged (88da670/ab6f576). HttpAdapter + E2E test with reconciliation.
- **g2-infra** — PR #12 merged (6be8635) + fixes 220a719/79b979c/64cbf43/8ad297b. Phoenix release Dockerfile + k8s wiring + SSL/assign/timeout patches.
- **g2-e2e** — **G2 success metric hit (2026-05-19).** PR #14 merged (e850809). Worker (Fountain conv `933fbc59`, terminated) claimed issue #3, implemented CONTRIBUTING.md, verified with `mix test` (227 passing), opened PR. Driver merged. Full claim → PR → merge cycle proved with thread continuity. `guild.inevitable.fyi` serves the Phoenix app.
- **g3-slice-1** — webhook ingestion, GitHub adapter, claiming pipeline wired end-to-end.
- **g3-slice-2** — reconcile loop: executing→pr_open, pr_open→done state transitions.
- **g3-slice-3** — self-hosting deploy: k8s manifests, live webhook endpoint, operator runbook.
- **g3-slice-4** — integration test: full webhook→claiming→pr_open→done cycle without live calls. ROADMAP closed 2026-05-24.

## Next

- **G4 — hardening + breadth for unattended operation.** Framed in [`plan/g4-framing/framing.md`](plan/g4-framing/framing.md). Eight items across correctness (duplicate-dispatch race), operability (auth, SECRET_KEY_BASE Secret, webhook retries), maturity (decisions_log retention, context summarization), and breadth (Linear/Slack adapters, multi-worker + multi-repo). Suggested execution order in the framing doc; first slice = race fix + auth + SECRET_KEY_BASE. Driver dispatches captain-picard to write `plan/g4/slice-plan.md`.

## Gated

- **G0** — resolved. Wedge B selected.
- **G1** — CLOSED. ADRs 0005–0009 merged (PR #4, 73e4155).
- **G2** — CLOSED. Worker shipped PR #14 against issue #3, merged 2026-05-19.
- **G3** — CLOSED 2026-05-24. Self-hosting cutover: integration test + live webhook pipeline merged. Live-fire verified 2026-05-24: issue #24 → PR #25 (LICENSE) shipped autonomously and merged.
- **G4** — hardening + breadth for unattended operation. See [`plan/g4-framing/framing.md`](plan/g4-framing/framing.md). Closes when a non-driver human can stand up their own Guild instance and watch it ship a PR autonomously, with operator UI behind auth and worker runtime durable across pod restarts.
