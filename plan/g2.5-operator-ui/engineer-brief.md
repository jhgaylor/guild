# G2.5 — Operator UI: Thread Index, Thread Detail (LiveView), Decisions Feed

## Context
Repo: jhgaylor/guild. Branch off main: g2.5/operator-ui.
Schemas: lib/guild/schema/{thread,event,artifact,context_note,decisions_log}.ex.
GuildWeb: router.ex, layouts, core_components.ex, page_controller.ex already exist.

## Routes (add inside existing browser scope in router.ex)
  get "/threads", ThreadController, :index
  get "/decisions", DecisionController, :index
  live "/threads/:id", ThreadLive, :show

## Files to create
- lib/guild_web/controllers/thread_controller.ex — :index, threads ordered by updated_at desc
- lib/guild_web/controllers/thread_html/index.html.heex — table: anchor_type/anchor_id, state, owner, inserted_at, updated_at
- lib/guild_web/controllers/decision_controller.ex — :index, decisions_log recent-first
- lib/guild_web/controllers/decision_html/index.html.heex — table: thread link, decision_type, reasoning (120-char truncate), inserted_at
- lib/guild_web/live/thread_live.ex — mount loads thread + preloads events/context_notes/decisions_log/artifacts; 5s auto-refresh via :timer.send_interval; events in time-asc order; fountain_conversation artifacts render link to #{fountain_base_url}/conversations/#{external_id}

## Tests
- test/guild_web/controllers/thread_controller_test.exs — GET /threads → 200, row present
- test/guild_web/controllers/decision_controller_test.exs — GET /decisions → 200
- test/guild_web/live/thread_live_test.exs — GET /threads/:id → 200, key fields present

## Constraints
No auth. No dispatch buttons. Plain tables, minimal tailwind. No N+1 beyond preloads.
mix test --exclude e2e must stay green (227 tests).

## Done-when
All three routes → 200. LiveView auto-refreshes every 5s. PR open on g2.5/operator-ui.
