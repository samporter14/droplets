# Science Status

A Droplet for [Droppy](https://getdroppy.app): Claude Science sessions in the
notch, modelled on Droppy's own Agents droplet.

Unofficial: made by Sam, not affiliated with or endorsed by Anthropic.
Claude is a trademark of Anthropic.

- A **live activity pill** while a Claude Science session runs (with a count
  when more than one runs).
- A **shelf widget** listing recent sessions with their state; tapping opens
  the session in Claude Science.
- An **activity graph** widget, GitHub-style: a square per day, shaded by how
  many sessions started that day, as many weeks as the shelf is wide.
- A **HUD card** when a session finishes or needs input, with an Open button.
- A **settings pane** for poll intervals, which states trigger a card, and a
  threshold that keeps short sessions quiet.

## How it knows

Like Agents, it only watches what Claude Science already writes to local disk.
It never talks to the agent, hooks the terminal, or contacts any service:

1. The documented `claude-science status` command for daemon health.
2. A read-only pass over the daemon's SQLite database for the sessions and
   their states, using the same rules as Claude Science's own dashboard.

No auth to manage, no network capability, no guessing: an unreadable state
shows as "can't read status" instead of something stale or invented. See
`DISCOVERY.md` for the full signal mapping (Claude Science 0.1.53).

## Developing

```bash
droppykit build      # produce ScienceStatus.droplet
droppykit validate   # the checks the Store repository runs
droppykit run        # open it in Droppy's Settings panel
```

`AGENTS.md` is the brief a coding agent reads first. `swift test` runs the
transition tests and the session query against a throwaway database.

The harness draws made-up sessions, so its shots can go straight into
`Assets/` as Store screenshots. `SCIENCE_STATUS_LIVE=1 droppykit run` reads
this Mac's Claude Science instead; keep those shots out of `Assets/`.

## Before submitting

- Fill in `creator` in `droplet.json` (name, url, gitlab).
- `droppykit submit`: the Store is a repository, one folder per droplet, and
  this opens the merge request that adds yours. See
  [Submitting](https://getdroppy.app/docs/droppykit/submitting).
