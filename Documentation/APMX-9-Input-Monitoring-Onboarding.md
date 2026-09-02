# APMX-9: Input Monitoring permission and onboarding

## State model

`InputMonitoringPermissionService` is the only component that calls
`CGPreflightListenEventAccess()` and `CGRequestListenEventAccess()`. It combines
the current preflight result with two local history flags to expose five honest
states:

- **Not requested**: no request or prior grant is recorded.
- **Not allowed**: the one explicit request was declined or access remains off.
- **Allowed**: the passive preflight succeeds.
- **Access removed**: access succeeded previously and now fails preflight.
- **Relaunch required**: macOS accepted the request but preflight does not yet
  succeed in this process.

Only **Allow Input Monitoring** can call the request API, and only while the
state is **Not requested**. **Check Again**, lifecycle checks, and the 15-second
safety check use preflight only, so denial cannot create a prompt loop.

## User experience

The menu-bar panel stays usable in every state. When permission is unavailable,
it shows the privacy explanation and marks metrics **Unavailable** rather than
presenting zero as captured data. Settings provides the same state and copy,
plus capture diagnostics.

The recovery actions are:

- **Allow Input Monitoring** for the initial protected request.
- **Open System Settings** using the validated Input Monitoring pane link, with
  an automatic generic Privacy & Security fallback when opening fails.
- **Check Again** for a non-prompting preflight.
- **Relaunch APMX** when the OS reports that a restart is required.
- **Quit** from the menu-bar panel.

All controls are native SwiftUI buttons with keyboard focus behavior and
explicit accessibility labels or hints for the permission-specific actions.

## Privacy copy

The onboarding states that APMX observes only the occurrence of a keyboard,
pointer, mouse-button, or scroll action. It also states that individual inputs,
typed content, pointer location, app/window identity, and clipboard data are
never recorded. It explains that privacy-safe session summaries remain locally
for 48 hours and hourly action and monitoring totals remain for 60 days.

## Automated coverage

Application tests cover the initial state, passive checking, one-shot request,
denial without repeated prompting, grant followed by runtime revocation,
relaunch-required state, and the direct-link fallback. The existing capture
tests continue to cover stopping ingestion and closing a live session at a
recovery boundary.

## Owner-assisted validation

The protected prompt and System Settings toggle require owner interaction.
Validate these cases with the exact signed build under test:

| Scenario | Expected result |
| --- | --- |
| First launch | Privacy copy and all recovery actions are keyboard reachable; metrics say **Unavailable**. |
| Initial request | One click invokes the system flow once; later checks do not repeat it. |
| Denial | Menu and Settings remain usable and explain System Settings recovery. |
| Later grant | Capture starts immediately when supported; otherwise **Relaunch APMX** appears. |
| Runtime revocation | Capture stops and metrics become **Unavailable** within 15 seconds or when APMX becomes active. |
| Deep link | **Open System Settings** opens Privacy & Security → Input Monitoring. |
| VoiceOver | Permission status and each action have an understandable spoken label/hint. |

### Validation result — 2026-08-02

Owner-assisted testing confirmed:

- The privacy explanation, unavailable-metrics state, and required actions were
  visible before permission was granted.
- Granting permission started counting immediately.
- Revoking permission stopped counting immediately.
- VoiceOver labels and navigation worked.

The first pass found that **Check Again** disappeared after permission was
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
