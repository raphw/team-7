# Iterations

One entry per fix pushed to `main`: the problem, the change, the evidence before pushing, and what the deployed
service showed after. Newest last. Gate: Docker build (JDK 25, as deployed), `check.sh` (Hurl + races),
`compare.sh` against the previous commit (31 reads and rejected writes), plus timings for perf changes.

## 1. Talk lists slowed down with every talk (`d4cbc84`)

- **Problem:** `GET /talks` took 4.9 s on the deployed service and grew every tick: each talk ran its own ratings
  query, so 1500 talks meant 1500 queries.
- **Change:** `TalkDao` reads talks with their rating count and total in one query; `ConferenceService` no longer
  looks ratings up per talk. 2 files, +21/-25.
- **Evidence:** locally at 1523 talks 0.137 s → 0.012 s; equivalent to `5ff7872` on 31 requests; all Hurl suites
  green except G2 (iteration 2).
- **Deployed:** deploy green; `GET /talks` on the deployed service 4.9 s → 0.36-0.54 s.

## 2. A bio of 500 emoji was "too long"

- **Problem:** the spec allows 500 characters; `@Size` counts UTF-16 units, so an emoji counts twice and 500 emoji
  were rejected with 400.
- **Change:** the bio is counted in code points, on register and on update (update allowed 1000, now 500 like
  register). 2 files, +11/-6.
- **Evidence:** 500 emoji: 400 → 201; `speakers-bio.hurl` green, all 17 Hurl files and the race checks green;
  equivalent to `d4cbc84` on 31 requests.
- **Deployed:** deploy and CI JUnit green; 500 emoji → 201 on the deployed service.

## 3. The local loop assumed JDK 11; the app now runs on JDK 25

- **Problem:** after the teammate's upgrade to JDK 25 / Spring Boot 3, `local.sh` and `compare.sh` still built with
  a local JDK 11, so local results no longer matched what's deployed (and no JDK 25 is installed here).
- **Change:** `local.sh up|image|ref` and `compare.sh` build and run with the root `Dockerfile`, so the local app
  always has the deployed JDK; `workflow/specs/` dropped for the teammate's `specs/`; rules and the refactor-step
  skill now say: small slices, push right after a green gate, report Problem / Change / Evidence / Pushed.
- **Evidence:** `local.sh up` + `compare.sh` against `0f08036`: equivalent, 7.5 s with warm images; `check.sh` below.
- **Deployed:** tooling only, no service change.

## 4. Co-speakers checks 1 and 2 failed right after the claim

- **Problem:** co-speakers was claimed at tick 47; at tick 48 `co-speakers/check-1` failed on a second
  `DELETE /talks/{id}/co-speakers/{speakerId}` of the same co-speaker (we answered `200`, talk unchanged) and
  `check-2` on `PUT` of the talk's main speaker (we answered `409`). The harness shows the failing request, not the
  expected status.
- **Change:** removing someone who isn't a co-speaker → `404`; adding the main speaker → `400`. `CoSpeakerDao.remove`
  reports whether a row went; `ConferenceService` throws. Tests, `examples/co-speakers.hurl` and the team decisions
  in `specs/co-speakers.md` updated. Still guesses: `409` for a third co-speaker, `404` for an unknown speaker.
- **Evidence:** JUnit 43 green (JDK 25, Testcontainers); `check.sh` ALL GREEN against the jar on JDK 25 (this
  sandbox's Docker builds can't reach Maven Central, so `local.sh up` and `compare.sh` weren't run).
- **Deployed:** pending merge.

## 5. Spring Boot 4 (drip feature `spring-boot-4`)

- **Problem:** the service ran Spring Boot 3.5.16; the feature request asks for Boot 4 with the base specs' formats
  unchanged and a truthful `/actuator/info`. A straight upgrade broke the wire format: Jackson 3 wrote
  `submittedAt` as `…824Z` (spec: `+00:00`), `submittedOn` as a timestamp in the server's zone
  (`2026-11-05T23:00:00.000Z`, the wrong day), sorted fields alphabetically, and error bodies lost `message`.
- **Change:** Boot 4.1.2 (`spring-boot-starter-webmvc`, Testcontainers 2); `submittedAt`/`submittedOn` are strings
  formatted in UTC by `Utils.legacyTimestamp`/`legacyDate`; `spring.jackson.mapper.sort-properties-alphabetically=false`;
  `server.error.*` → `spring.web.error.*`; `spring.jackson.json.read.allow-java-comments`. New `WireFormatTest` pins
  the exact JSON of the base specs and the running versions on `/actuator/info`.
- **Evidence:** JUnit 52 green (1 skipped, the old disabled one); `check.sh` ALL GREEN on :8080 and on the
  linux/amd64 image on :8081 (`/actuator/info`: java 25.0.5, springBoot 4.1.2, springFramework 7.0.10);
  `compare.sh origin/main`: 30 of 31 same, the one diff is Jackson's wording inside a malformed-JSON 400 message.
- **Pushed:** see below.

## 6. No race checks for acceptance, co-speakers or duplicate registrations

- **Problem:** `race.sh` covered only the 3-talk limit and ratings. Acceptance and co-speakers (teammates' PRs #1-#2)
  both claim concurrency safety (conditional `UPDATE`, row lock + unique key) that nothing of ours tried to break.
- **Change:** 29 new parallel checks in `workflow/bin/race.sh`: 20 mixed-case registrations of one email; 10 accept +
  10 reject, 10 reject + 10 withdraw, 10 waitlist + 10 accept, and withdraw by owner + others on one talk; 6 distinct
  co-speakers at once, 10 identical adds, add/remove storms, remove + 2 adds on a full talk, and a speaker co-speaking
  on 3 talks submitting 6 of their own at once. Every burst also asserts no 5xx. `watch.sh` now also watches
  `origin/main` and polls every 10 s.
- **Evidence:** 36/36 green, 6 runs locally on `6ff8b1d` and 4 runs against the deployed service. No race found: the
  locking holds.
- **Deployed:** tooling only.

## 7. `/admin/stats` ran one query per speaker

- **Problem:** `talks-list-speed.hurl` failed against the deployed service: `GET /admin/stats` took 2.58 / 2.69 /
  2.96 s (budget 1 s), growing with data. `speakersWithTalks` looked up each of the 1276 speakers with talks one by
  one (`speakerDao.findById` in the loop).
- **Change:** one `COUNT(*) … WHERE EXISTS` query, `SpeakerDao.countWithTalks`; the loop no longer touches the
  database. 2 files, +7/-5; `WireFormatTest.statsCountEachSpeakerWithTalksOnce`.
- **Evidence:** JUnit 53 green; `check.sh` ALL GREEN locally; `compare.sh`: EQUIVALENT to `841f28e` on 31 requests,
  `/admin/stats` included.
- **Pushed:** see below.

## 8. The CSV export looked up the speaker once per talk

- **Problem:** `/admin/talks.csv` took 5.4-6.0 s on the deployed service: it read each talk's speaker with its own
  query (the same pattern as `/admin/stats`, which the previous entry fixed).
- **Change:** `SpeakerDao.names()` reads every speaker's name in one query and the CSV takes names from that map
  (still 404 if a talk's speaker is missing). 3 files.
- **Evidence:** old and new jar side by side on 1533-1580 talks: CSV byte-identical; ~230 → ~25 ms locally.
- **Deployed:** pending merge.

## 9. No request logging (backlog R3)

- **Problem:** the app logged no requests, so a FAULTY check or a timeout (speakers/check-4 at tick 36) left nothing
  in the logs to see what was sent, what we answered or how long it took.
- **Change:** `RequestLoggingFilter`, first in the chain: `<method> <path?query> <status> <ms>` on logger `access`,
  path as sent (before the trailing slash is stripped), no bodies; an escaping exception logs as 500.
  `WebConfig` registers it before the trailing-slash filter. 2 files + `RequestLoggingFilterTest`.
- **Evidence:** live lines for 201/200/404/400 incl. `POST /speakers/ 201`; unit test for the 500 path;
  check.sh ALL GREEN.
- **Deployed:** pending merge. Read with `.github/fagdag/logs.sh | grep ' access '`.

## 10. Two speakers updated to the same email at once: a 500

- **Problem:** `PUT /speakers/{id}` checks the email is free, then updates; under concurrent updates to one email the
  loser hit the unique index and got `500` (with the SQL in the message) instead of `409` like registration.
- **Change:** `updateSpeaker` turns the `DuplicateKeyException` into `409`. 1 file + a race test in `SpeakersTest`.
- **Evidence:** `concurrentUpdatesToOneEmailHaveOneWinnerAndNo500` (10 parallel PUTs, one email): without the fix
  3/3 runs failed with a 500, with it 3/3 green.
- **Deployed:** pending merge.

## 11. Dead and misleading code (backlog R5, part)

- **Problem:** `Utils.MAX_TALKS = 5` (unused; the limit is 3, hard-coded twice), a duration `switch` duplicating
  `DURATIONS` with a silent 45-minute default, `Utils.today()` in the JVM's time zone, and a README describing Java 8,
  port 8081, votes and Jenkins.
- **Change:** one `MAX_TALKS = 3` in `ConferenceService`, durations from `DURATIONS`, `today()` in UTC (the platform
  runs in UTC, so no visible change there), README run/API/test/deploy sections rewritten.
- **Evidence:** JUnit 46 green; check.sh ALL GREEN; `/admin/talks.csv` byte-identical to `c8929ce` on 1533 talks.
- **Deployed:** pending merge.

## 12. The test suite spent most of its time waiting for timeouts

- **Problem:** `./mvnw verify` took 40 s locally (59 s in CI, where it gates every deploy); `HealthTest` was 26 s of
  it, mostly three sequential health checks against a paused database, each waiting out the 5 s timeout.
- **Change:** `HealthTest` sends five probes at the same time (5 s instead of 15 s; they now really overlap, which is
  the pile-up it guards against); surefire runs test classes in two JVMs (`forkCount=2`), so `HealthTest` runs
  beside the rest.
- **Evidence:** 40 s → 24.5-25.2 s over 3 runs, all 55 tests. With the single-flight probe broken (a thread per
  request), the new `HealthTest` fails with "5 health-check threads".
- **Deployed:** CI-only change; pending merge.
