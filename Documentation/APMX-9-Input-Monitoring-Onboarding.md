# APMX-9 / APMX-38: Input Monitoring permission and onboarding

## State model

`InputMonitoringPermissionService` is the only component that calls
`CGPreflightListenEventAccess()` and `CGRequestListenEventAccess()`. It combines
the current preflight result with two local history flags to expose six honest
states:

- **Not requested**: no request or prior grant is recorded.
- **Not allowed**: the one explicit request was declined or access remains off.
- **Allowed**: the passive preflight succeeds.
- **Access removed**: access succeeded previously and now fails preflight.
- **Relaunch required**: macOS accepted the request but preflight does not yet
  succeed in this process.
- **Unsigned build**: this copy has no stable Apple code identity and cannot
  request Input Monitoring.

Only **Enable Input Monitoring** in the welcome window and **Allow Input
Monitoring** in the menu or Settings can call the request API, and only while
the state is **Not requested**. Startup, lifecycle checks, and polling use
preflight only, so denial cannot create a prompt loop. Recovery polling runs
every 0.5 seconds for up to 12 checks, then uses the 15-second safety interval.
Unsigned builds do not invoke either protected API.

## User experience

After the first completed passive permission check and capture reconciliation,
the app delegate presents a native welcome window without requiring a menu-bar
click. Saved permission history is not a completed check: an already authorized
app skips the activity-permission window even if its saved history says otherwise.

The initial welcome says **Welcome to APM Explorer!** and explains that enabling
Input Monitoring turns keyboard, mouse-click, and scroll activity into analytics,
that typed content is never recorded, and that data stays on the Mac. Its
primary action is **Enable Input Monitoring**; **Not Now**, Escape, or the window
close control dismisses it. Dismissal never requests permission.

Denied or revoked access shows a recovery message with **Open Input Monitoring
Settings** and **Not Now**. An accepted request that requires a process restart
shows **Relaunch APMX**. An unsigned copy shows the existing signing explanation
and does not offer a permission request. The open window updates as permission
changes; after approval it shows the actual recording status and **Done**.

The controller consumes only the first completed check for its startup decision.
Closing or deferring the window does not reopen it on polling, focus changes,
or later revocation during the same launch. No dismissal preference is stored;
a later launch offers help again if permission is still missing. The welcome
window does not participate in macOS window restoration.

### Launch at login follow-up

After the activity-permission window is completed or dismissed, a separate
**Start at Login** window asks whether APM Explorer should open in the menu bar
when the user logs in. Already authorized launches go directly to this step.
**Enable** explicitly registers the login item through the same service used by
Settings. **Not Now**, Escape, or the close control skips it without registering.

The offer appears until a choice is made. The
`settings.hasCompletedLaunchAtLoginOnboarding` boolean remembers completion,
including a skipped offer, across refreshes and launches. Already enabled login
items complete this step silently. Quitting during setup does not record a
choice or advance to another window. Launch at login can always be changed in
Settings → Startup.

When a completed Input Monitoring check finds access missing, the
`settings.hasPendingPermissionRecovery` boolean remembers that recovery is
pending. Once access is restored, the login offer becomes eligible again even
if it was previously skipped. This survives the macOS permission restart and
also handles permission recovery while the app stays open. The offer still
waits until the activity-permission window is closed and is omitted when
launch at login is already enabled. A new dismissal is remembered until the
next permission recovery; ordinary launches and repeated denied checks do not
repeat the offer. Cached permission history and unsigned builds do not start
a recovery cycle.

The window preserves macOS's **Unavailable** status and shows registration
errors, allowing another attempt. **Needs approval in System Settings** offers
**Open Login Items Settings**; returning refreshes the status and closes the
offer if startup is enabled. Input Monitoring is still required for activity
analytics. No login-item registration occurs merely by opening either window.

The menu-bar panel and Settings stay usable in every state. Current metrics
remain **Unavailable** until permission, capture, and storage prerequisites are
met. Onboarding explicitly says activity is collected only while monitoring is
running and earlier activity cannot be recovered.

The recovery actions remain available from the menu and Settings:

- **Allow Input Monitoring** for the initial protected request.
- **Open Input Monitoring Settings** in the menu / **Open System Settings** in
  Settings, using the Input Monitoring pane link and a generic Privacy & Security
  fallback if opening fails.
- **Relaunch APMX** when the OS reports that a restart is required.
- **Quit** from the menu-bar panel.

The manual **Check Again** and **Check Permission Again** controls were removed
in APMX-38. Returning from System Settings or the next automatic check reconciles
permission and starts capture when the existing prerequisites allow it. Failed
Settings opening and relaunch attempts display recovery instructions.

Controls are native SwiftUI buttons and disclosure controls. The primary welcome
action supports Return, **Not Now** supports Escape, and the heading, recording
status, disclosure, and actions have readable accessibility text. The detailed
capture and retention disclosure is available directly in the welcome window.

## Privacy copy

The onboarding states that APMX observes only physical key downs, mouse-button
downs, and reduced scroll gestures or bursts. Pointer movement and dragging
are not counted. It also states that individual inputs,
typed content, pointer location, app/window identity, and clipboard data are
never recorded. It explains that privacy-safe session summaries remain locally
for 48 hours and hourly action and monitoring totals remain for 60 days.

## Automated coverage

Application tests cover startup waiting for a real check, suspension before that
check, stale history with an authorized startup, a check completing before the
window controller exists, every missing-permission state, and dismissal during
polling/focus changes followed by a later launch. Existing tests cover passive
checking, explicit one-shot requests, denial without repeated prompting, grant
followed by runtime revocation, relaunch-required state, and Settings-link
fallback. The UI scenario verifies visible startup and dismissal without
reopening after activation; unsigned builds also verify the signing explanation.
A signed UI run skips the dismissal scenario when the welcome is absent, since
permission may already be granted. The deterministic adapter tests verify the
startup decision for every permission state with an injected provider without
changing the owner's TCC permissions.

## Owner-assisted validation

The protected prompt and System Settings toggle require owner interaction.
Validate these cases with the exact stable signed build under test:

| Scenario | Expected result |
| --- | --- |
| Fresh launch, access never requested | Welcome appears without a menu click after the passive check; no protected prompt appears until **Enable Input Monitoring** is selected. |
| Not Now / Escape / close control | Activity window closes and the pending login-startup step follows; menu and Settings remain usable; polling and focus changes do not reopen the activity window. A later launch offers permission help again if needed. |
| Initial request | One click invokes the system flow once; later checks do not repeat it. |
| Denial, then relaunch | Recovery window explains the need for permission and offers **Open Input Monitoring Settings** and **Not Now**. |
| Previously skipped login offer, then Input Monitoring is removed and restored | After the app observes missing access, restoring access and allowing the macOS restart presents **Start at Login** again if startup is off. **Not Now** suppresses it on subsequent normal launches. |
| Later grant through System Settings | Returning updates status automatically; capture starts when storage and event-tap prerequisites permit. No manual recheck is needed. |
| Relaunch required | The window explains why and offers **Relaunch APMX**; after relaunch, an authorized startup skips activity setup and can offer the pending login-startup step. |
| Already authorized launch | No activity welcome or recovery window; the pending login-startup step may still appear. |
| Runtime revocation | Capture stops and current metrics become **Unavailable** within 15 seconds or when APMX becomes active; no new automatic window this launch. The next launch offers recovery. |
| Unsigned build | Visible signing explanation, no enabled permission request, menu and Settings usable after dismissal. |
| Keyboard and VoiceOver | Reach the primary action, Not Now, privacy disclosure, and close control; spoken heading, status, and action labels are clear. |
| Analytics | No implied collection before monitoring; failed capture/storage prerequisites remain visible after permission is allowed. |

For the login follow-up, verify **Enable** with a stable signed installation,
including any macOS approval request. **Not Now**, Escape, and the close control
should dismiss it permanently; reopening the app should still offer permission
recovery when needed but should not repeat the login offer. Returning from Login
Items after approval should close the second window. Tests use an injected login
service for success, approval, and failure paths without changing real login items.

### APMX-38 validation status

Validated on 2026-09-02 with Xcode 26.6 / macOS 26.6.2:

- Core package: **81 tests passed** with `swift test --package-path APMXCore`.
- Signed macOS application suite: **49 tests passed**. The launch UI smoke test
  passed, and the focused startup/dismissal UI test passed against the signed
  app with missing permission. The latter verified startup presentation,
  **Not Now**, no reopening on activation, and the remaining menu bar item.
- `Scripts/verify-input-monitoring-signature.sh` verified the development build
  as `ca.horatiu.apmx` with team `87M55M486F`.
- Visual and accessibility-tree inspection of the unsigned welcome confirmed
  readable signing guidance, an expandable privacy disclosure without clipping,
  and a native dismissal button.
- The unsigned command passed all 49 application tests, but its UI runner was
  killed before bootstrapping on this machine. An ad hoc attempt stalled in
  sandbox initialization; development signing allowed the UI tests to run.

The signed test command was:

```sh
xcodebuild test -project APMExplorer.xcodeproj -scheme APMExplorer \
  -destination 'platform=macOS' -derivedDataPath /tmp/apmx-38-signed
```

The historical APMX-9 results below do not validate the new startup presentation.
Fresh installation, protected denial/grant/revocation/relaunch controls, and
spoken VoiceOver navigation remain pending owner-assisted validation of this
change. No protected permission controls were operated during automated or
visual verification.

### Validation result — 2026-08-02

Owner-assisted testing confirmed:

- The privacy explanation, unavailable-metrics state, and required actions were
  visible before permission was granted.
- Granting permission started counting immediately.
- Revoking permission stopped counting immediately.
- VoiceOver labels and navigation worked.

Historical behavior (superseded by APMX-38): the first pass found that
**Check Again** disappeared after permission was
granted. The action layout was made explicit and the control now has a stable
accessibility identifier so its presence can be regression-tested in every
permission state. The owner rechecked the updated build and confirmed that
**Check Again** remains present after permission is granted and that the menu
shows its Metrics summary. The focused correction therefore passes.

If macOS has cached an earlier development decision, reset only this bundle
before repeating the first-request case:

```sh
tccutil reset ListenEvent ca.horatiu.apmx
```

The owner must still approve or deny the next protected request personally.
