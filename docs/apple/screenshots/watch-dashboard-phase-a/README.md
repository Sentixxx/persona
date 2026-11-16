# Apple Watch dashboard: Phase A evidence

Refs #8863, #8864, #8865 and #8866. Captured on November 16, 2026 with Xcode 27.2,
watchOS 27.2 simulators, Debug, arm64 and signing disabled. Deployment target:
watchOS 10.0. Xcode 26.0 and a watchOS 10 runtime were not available for verification.

## Matrix and inspection

The gallery contains 126 screenshots, arranged four per contact sheet at their
original pixel size, with filenames beneath each image. The last sheet has two
images. The contact-sheet background and labels are not part of the app.
Four additional English/Japanese plan-action captures check default and maximum
text on 41 mm: [localized actions](locales.png). Total inspected: 130 screenshots.

- Apple Watch Series 9, 41 mm; Apple Watch Ultra 4, 49 mm.
- Default text and `.accessibility5` (the `-showLargeText YES` DEBUG override).
- All four pages in waiting, calm, stale and offline states; unpaired and partial
  hub-failure states; permission, plan, question, terminal, form and multi-question
  details; session, Inbox reply and recorder views.
- Accessibility-size lower-anchor captures also show the actions below long
  content. A viewport ending within scrollable content is not a clipped control.
- Interface copy is Simplified Chinese; synthetic sample messages are English.
- The agent inspected every final image. This is a **large UI change**: independent
  human screenshot review is still required before merging.

**Native dark appearance only.** Both `simctl ui <watch> appearance light` and
`appearance dark` return code 45, `Runtime does not support userInterfaceStyle`.
The watch has no separate light-theme matrix; the requested light variant cannot
be tested by that override. No duplicate or recolored images stand in for it.

## Reproduce a capture

Generate the project with XcodeGen and build `PersonaWatch` for an arm64 watchOS
Simulator with signing disabled. Boot the watch profile through
`scripts/app/sim-boot.sh --profile watch`, then install the built app on the chosen
41 mm or 49 mm simulator. Use your configured bundle identifier:

```sh
xcrun simctl launch "$WATCH_UDID" "$WATCH_BUNDLE" \
  -showWatchDashboard waiting -openWatchPage glance \
  -showLargeText YES -watchScrollBottom NO \
  -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
xcrun simctl io "$WATCH_UDID" screenshot glance.png
```

Terminate before each launch so the next fixture is applied. Fixture states are
`waiting`, `calm`, `stale`, `offline`, `partial`, `unpaired`, `permission`, `plan`,
`question`, `screen`, `elicitation` and `multiple`. Pages are `glance`, `queue`,
`running` and `recordings`. `-openWatchItem permission|plan|question|screen|elicitation|session`
opens a detail; `-openInboxFirst YES` opens the synthetic Inbox item;
`-openRecording YES` opens the recorder. `-watchScrollBottom YES` selects the bottom
scroll anchor. These DEBUG fixtures bypass live account configuration and use
`example.invalid`; they do not prove a successful live-hub action.

## Verification and boundaries

- `PersonaWatch` simulator build: passed with Xcode 27.2, watchOS deployment target 10.0.
- Nine relevant Swift suites: **102 tests passed**, including dashboard counts,
  navigation, optimistic answers, quick questions, pet counts, group refresh,
  credentials, muting and token ratchets.
- No full end-to-end tap, Crown, dictation, haptic or double-tap claim is made from
  these deterministic captures. Native Simulator UI control was unavailable.
- #8866 real iPhone/Watch mirrored notifications with two hubs: **pending hardware**.
- #8865 real-hub Watch/phone/web answer convergence and end-to-end latency:
  **not run**, no approved live test fixture was available.
- Simulator capture cannot replace those hardware and real-hub checks. The PR
  remains a draft for those checks and human review.

## Gallery

The labels beneath each screenshot identify its original filename.

| Sheet | Sheet | Sheet | Sheet |
| --- | --- | --- | --- |
| [01](sheet-01.png) | [02](sheet-02.png) | [03](sheet-03.png) | [04](sheet-04.png) |
| [05](sheet-05.png) | [06](sheet-06.png) | [07](sheet-07.png) | [08](sheet-08.png) |
| [09](sheet-09.png) | [10](sheet-10.png) | [11](sheet-11.png) | [12](sheet-12.png) |
| [13](sheet-13.png) | [14](sheet-14.png) | [15](sheet-15.png) | [16](sheet-16.png) |
| [17](sheet-17.png) | [18](sheet-18.png) | [19](sheet-19.png) | [20](sheet-20.png) |
| [21](sheet-21.png) | [22](sheet-22.png) | [23](sheet-23.png) | [24](sheet-24.png) |
| [25](sheet-25.png) | [26](sheet-26.png) | [27](sheet-27.png) | [28](sheet-28.png) |
| [29](sheet-29.png) | [30](sheet-30.png) | [31](sheet-31.png) | [32](sheet-32.png) |
