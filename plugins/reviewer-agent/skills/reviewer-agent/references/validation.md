# Validation

`detect-validation.sh` resolves *how* to validate a checkout; `validate.sh`
*executes* it — always in an **isolated compose project** so it can never touch
the developer's running stack. The verdict is the **test-runner exit code**, not
the (lenient) bring-up exit.

## Resolution ladder (first match wins)
1. **Override** — `validation_cmd` from the trusted base-branch config / `--validate`.
2. **Platform staged** — `scripts/up.sh` + `docker-compose.test.yml` + an `e2e-runner`
   service present. Slim by default (smoke project), full when `validation_level: full`
   (journey project + hatchet/workers/observability profiles).
3. **Makefile** — first of `test` / `ci` / `check` targets.
4. **Generic compose** — `docker-compose.yml` (+ test overlay) with an `e2e-runner`.
5. **Unit fallback** — language default (`uv run pytest …` / `npm test` / `cargo test`
   / `go test ./...`). Marked `partial:true` (no full-stack signal).
6. **none** — nothing detected; `partial`.

`validation_level: unit` forces the unit rung (fast, no docker).

## Isolation (why this matters)
On the platform repo, `mise run up` / `up:slim` / `e2e:up` / `e2e:run` / `e2e:down`
operate on the **default compose project** — running them would collide with, or
`down -v` the developer's dev stack volumes. **Never call those tasks.** `validate.sh`
instead:
- generates a unique project name `ra-pr<N>-<epoch>`;
- injects `-p <project>` into every compose call (including `scripts/up.sh`, via
  `UP_COMPOSE_FILES="-p <project> -f docker-compose.yml -f docker-compose.test.yml"` —
  `up.sh`'s `docker compose $FILES` splats the `-p`);
- sets `COMPOSE_PROFILES=""` for slim (or the full set for `full`);
- on EXIT, tears down **only that project** (`docker compose -p <project> … down -v
  --remove-orphans`).

This yields **slim + isolated**, which neither stock mise task gives (the slim tasks
aren't isolated; `mise run e2e` is isolated but pulls the full ~32-container stack).

## Lenient bring-up exit
`scripts/up.sh` deliberately exits 0 when only Hatchet/workers warn (a non-fatal,
slim-irrelevant tier). So `validate.sh` does **not** infer pass/fail from bring-up —
it asserts the `e2e-runner` test exit and records any `unhealthy` services for the
evidence trail.

## Failure → fix loop
A `fail` result becomes a synthetic blocking issue fed back to the fixer; loop
fix↔validate up to `validation_cap` (default 2), then escalate. `partial` (unit-only
or docker unavailable) is **not** "green" — the merge gate will not merge on partial
unless the operator explicitly accepts it for a unit-only repo. Heavy validations can
exceed the Bash 10-minute cap → run `validate.sh` with `run_in_background`.
