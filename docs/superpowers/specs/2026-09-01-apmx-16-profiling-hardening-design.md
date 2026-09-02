# APMX-16 Profiling, Hardening, and Validation Design

## Goal

Validate and harden the completed macOS menu-bar application so that its
performance, durability, privacy, accessibility, release configuration, and
supported-hardware behavior are measured against the APMX-16 engineering gates.
The repository will contain repeatable checks and a concise evidence record;
large Instruments traces and machine-local application data will not be
committed.

## Scope and decisions

- The release product supports Apple Silicon only. The verified executable
  architecture is `arm64`; Intel and Universal 2 validation are out of scope.
- The deployment target remains macOS 13. Validation available in this
  workspace runs on the current Apple Silicon Mac and macOS 26. The macOS 13
  result remains an explicit hardware gap until the owner runs the documented
  procedure on suitable hardware.
- Protected permission changes, VoiceOver operation, signing-candidate checks,
  credentials, and additional physical-Mac configurations are owner-assisted.
  This implementation records exact procedures and marks those results pending
  instead of blocking repository work.
- No telemetry, analytics, updater, background networking, production
  performance counters, new app-added crash metadata, or new entitlement is
  introduced.
- Existing privacy-safe data boundaries remain unchanged: the callback and
  durable repository accept only aggregate activity models, never raw input
  payloads.

## Current-state findings

The repository already includes privacy allow-list tests, exact sandbox
entitlements, Hardened Runtime settings, lifecycle flushing, accessibility
labels and identifiers, and a 500 ms coalescing window for session-only saves.
Two implementation details need targeted hardening before profiling is treated
as release evidence:

1. Atomic session-plus-hourly saves currently bypass session coalescing and can
   commit one SQLite transaction per counted action.
2. The bounded ingestion mailbox removes the first element from a Swift array,
   which shifts the remaining elements for every drained signal.

In addition, every permission refresh currently checkpoints monitoring
coverage, causing recurring SQLite writes even when no input or lifecycle state
changes.

## Architecture

### Bounded ingestion mailbox

`ActivitySignalIngestionExecutor` retains one serial reduction queue and a
lock-protected, fixed-capacity mailbox. The mailbox becomes a circular buffer
with head, tail, and count state so dequeue is constant time. Its public
behavior does not change:

- accepted signals preserve FIFO order;
- capacity is bounded at initialization;
- when full, the newest incoming signal is rejected;
- each rejected signal increments the existing aggregate dropped-signal count;
- no individual signal or timestamp is retained after reduction.

The Core Graphics callback continues to classify an event into a
`RawActivitySignal`, enqueue it, and schedule the serial drain when necessary.
Ordinary event callbacks perform no disk I/O and no MainActor hop.

### Coalesced atomic persistence

`SQLiteActivitySessionRepository` extends its existing coalescing mechanism to
all session and hourly mutations. The actor stages:

- the latest `ActivitySession` snapshot for each session UUID; and
- the ordered `HourlyActivityUpdate` values received during the same batch.

The first staged mutation starts a non-sliding deadline using the existing
default of 500 ms. Later mutations join the batch without moving the deadline.
At the deadline, the repository writes the staged session snapshots and hourly
updates in one SQLite transaction. Session snapshots are keyed because only the
latest state is durable; hourly updates remain ordered so action and monitored
time increments are applied exactly once without adding a second aggregation
implementation.

`flush()` cancels the scheduled deadline, writes all pending mutations, and
surfaces any stored failure. Lifecycle termination continues to drain accepted
signals, close the live session, await ingestion persistence, and call the
repository flush. Queries that require durable current analytics force pending
mutations to flush before reading. `openSession()` may retain its existing
pending-session visibility as long as it returns the latest staged snapshot.

Pending data is cleared only after a successful database transaction. A failed
transaction enters the existing stored-failure state, is reported through the
app's persistence-failure handler, and prevents the UI from implying that data
is durable.

### Idle behavior and monitoring coverage

Permission checks continue to reconcile permission and event-tap state, but a
check that observes no aggregate or lifecycle change does not write monitoring
coverage. Monitoring produces one availability marker when capture starts;
coverage then advances with counted aggregate changes and clean suspension,
sleep, session-inactive, shutdown, or recovery boundaries. Daily maintenance
runs independently of the permission-refresh path and only when its existing
interval is due.

This design removes recurring idle SQLite writes after the initial monitoring
marker. It also makes a deliberate trade-off: after a force quit during a fully
input-idle stretch, the exact uncommitted coverage tail cannot be reconstructed
without a periodic durable heartbeat. The 500 ms abnormal-termination gate
therefore applies to staged action and session-summary mutations. The idle
coverage limitation is measured and recorded as an exception requiring owner
acceptance; it is not reported as a passing gate.

## Validation infrastructure

### Automated tests

Test-first changes cover these observable behaviors:

- mailbox FIFO ordering, constant-capacity behavior, and drop-newest semantics;
- several session/hourly mutations remain outside SQLite until the batch is
  flushed, then appear exactly once in one logical atomic result;
- the first mutation's flush deadline is not extended by later mutations;
- the default durability window remains 500 ms;
- explicit flush makes pending session and hourly data durable immediately;
- read behavior exposes current results according to the repository contract;
- persistence failures remain visible and pending work is not reported as
  successfully durable;
- repeated unchanged permission refreshes do not call hourly persistence;
- lifecycle flushing, privacy allow-lists, event masks, and aggregate counts
  continue to pass.

Tests assert real repository and ingestion behavior. Time-sensitive tests use a
short injected coalescing interval with a bounded wait; most coalescing tests
use explicit flushes so they are deterministic.

### Release-safety script

A repository script runs the existing release tests and inspects an arm64 app
product. It fails when any of these conditions is false:

- the executable contains `arm64` and no Intel slice;
- Hardened Runtime is enabled;
- the signed product's only app entitlement is
  `com.apple.security.app-sandbox`;
- no client or server network entitlement is present;
- no analytics SDK, updater framework, or app-linked networking framework is
  introduced;
- the existing core privacy regression, macOS adapter, and UI smoke tests pass.

Source checks use narrow prohibited integration signatures rather than banning
ordinary user-initiated website links. Entitlement inspection remains the
authoritative runtime network-capability check.

### Profiling and evidence record

`Documentation/APMX-16-Profiling-and-Manual-Validation.md` records:

- Mac model, chip, memory, macOS, Xcode, and Swift versions;
- commands and app configuration used for each result;
- startup and menu-item availability;
- steady-state resident memory;
- idle CPU and wakeup observations;
- allocations and event-tap responsiveness under available workloads;
- SQLite write behavior at idle and during synthetic or accessible input;
- entitlement, linked-dependency, privacy, and release-safety findings;
- accessibility results;
- the manual OS, permission, input-device, lifecycle, appearance, launch-at-
  login, and signing-candidate matrix.

Each matrix row has one of four explicit outcomes: Pass, Fail,
Owner-assisted pending, or Hardware unavailable. A result names its evidence;
an unexecuted row is never inferred to pass. The initial engineering targets
remain:

- idle CPU effectively 0%, with no continuous fast polling;
- zero recurring idle SQLite writes;
- no one-second UI timer while inactive or the menu is closed;
- no I/O or MainActor hop per ordinary raw input movement;
- steady-state resident memory below 50 MB;
- menu item available within 500 ms;
- staged action/session-summary loss bounded by the 500 ms coalescing window.

Measurements that miss a target are recorded as failures or explicit
exceptions. Target changes require the measured evidence and owner acceptance.

## Manual validation boundaries

The implementation agent runs all non-interactive checks available on the
current Apple Silicon/macOS 26 host. The evidence document gives exact steps
for the owner to complete:

- macOS 13 validation on Apple Silicon;
- fresh, denied, later-granted, and revoked Input Monitoring states;
- mouse, trackpad, external keyboard, dragging, held-key repeat, and inertial
  scrolling;
- sleep/wake, lock/unlock, user switching, logout/login, clock change, force
  quit, and upgrade;
- launch-at-login enabled, disabled, and denied states;
- light, dark, high-contrast, keyboard-navigation, and VoiceOver checks;
- App Store-signed sandbox and Developer ID signed/notarized candidates.

## Expected repository changes

- Modify `APMExplorer/PassiveInputCapture.swift` for the circular mailbox and
  no-op idle refresh behavior.
- Modify `APMXCore/Sources/APMXCore/SQLiteActivitySessionRepository.swift` for
  coalesced atomic session/hourly persistence.
- Extend `APMExplorerTests/AppDependenciesTests.swift` and
  `APMXCore/Tests/APMXCoreTests/SQLiteActivitySessionRepositoryTests.swift`.
- Add the release-safety/profiling script under `Scripts/` and connect it to the
  existing release gate where appropriate.
- Add `Documentation/APMX-16-Profiling-and-Manual-Validation.md` and update the
  README with the supported architecture and validation entry point.

## Acceptance

The implementation is ready for owner review when automated tests and
release-safety checks pass, accessible current-Mac measurements are recorded,
privacy and network-capability checks pass, and every unavailable manual matrix
row is explicitly labeled with its owner action. APMX-16 is not represented as
fully accepted until the owner accepts documented exceptions and completes or
waives the pending hardware/protected checks.
