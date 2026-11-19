# Runtime log failures implementation plan

**Goal:** Recover the observed single-message named identity split, observe uncertain sends safely, diagnose V2 rejection, and bound chat-selection retries.
**Architecture:** Keep Swift/macOS AX adapters, durable receipts and hosted outboxes. Extend exact-message recovery, never nickname-only merging. Work in place to preserve the existing uncommitted hosted integration; baseline snapshots are in /tmp/pdd-logfix-before.
**Authorization:** User requested fixes after the five-step proposed repair/testing approach. Execute inline without another approval round.

## Constraints and review focus
- No live customer sends, automatic restart or speculative delivery receipts during verification.
- Single active readable chat and exact customer IDs required for identity repair; stable conflicts and hidden alias anchors stay blocked.
- Preserve commit-intent attempts; reconciliation only reads, including after a proven canonical alias.
- Reacquire AX row tokens for a single retry; never retry Send/transfer controls here.
- Report only response field names for API binding failures, never raw values, credentials or bodies.

## Tasks
- [x] Identity: add failing tests for a named singleton split into an older anchored customer, restart persistence, and rejection of hidden anchors/conflicting IDs. Extend reconcileVerifiedThread only for this evidence class; run identity/discovery suites.
- [x] Delivery: add a failing alias checkpoint reconciliation test and duplicate-candidate test. Resolve canonical identity only for observe-only reconciliation; require one outgoing candidate after target. Retain uncertainty without proof.
- [x] AX: add failed-row-press tests. Retry only stale/invalid element or cannotComplete once with freshly selected row by stable ID or unique label. Retain persistent failure/backoff.
- [x] API: add tests for terminal idempotent acceptance and safe binding diagnostics. Accept known terminal job states for polling the same job; emit field names for rejected bindings.
- [x] Run full Swift suite using a fresh scratch directory, review changes, build signed app artifact and document remaining runtime verification.

## Evidence
Baseline normal build blocked by sandbox cache permissions, then copied module caches referenced old project path. Fresh scratch baseline running.

Final evidence: baseline 869 tests/16 skipped/0 failures; final 880 tests/16 skipped/0 failures. Regression tests were observed failing before fixes. Review caught and corrected overlapping sent/uncertain work in timestamp repair. Actual API replay returned HTTP 202/status failed with valid bindings; read-only polling identified MESSAGE_ID_CONFLICT. Shared failed/successful frozen messages differed only by occurredAt. Added PinduoduoV2TimestampRepair and scheduler recovery for one proven correction; retained terminal tasks never advance answered cursors. Original runtime files and credentials were not manually edited. Signed release build uses AutoReplyInfo.plist v1.1+2.

Private-copy replay of the actual saved AX diagnostic and failed hosted outbox passed (1 test, no live AX actions or runtime writes); confirmed both named identity repair and construction of the timestamp-corrected replacement. Temporary replay test removed to avoid checking in machine-specific customer paths.
