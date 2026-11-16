# Apple Watch Phase A screenshots

Evidence for #8863–#8866: the four-page dashboard, request details and quick answers in the
ring language and hold to confirm (`docs/design/DESIGN_SYSTEM.md`, section 3.13). The owner chose
this direction from three 41 mm proposals (ring, full-screen colour, boarding card) and approved
the ring and hold to confirm before it was applied to every Phase A page.

The gallery holds 150 screenshots on contact sheets at their original pixel size, the file name
under each. The sheet background and labels are not part of the app.

- Apple Watch Series 9, 41 mm; Apple Watch Ultra 4, 49 mm.
- Default text and `.accessibility5` (the `-showLargeText YES` DEBUG override).
- 134 matrix captures in Simplified Chinese: Glance, Needs You, Running and Recordings in the
  waiting, calm, stale and offline states; unpaired and partial failure; Glance with a plan or a
  question next; every request kind's detail, several questions, a session, an Inbox item and the
  recorder; at the largest text, the lower scroll anchor of every scrolling detail.
- 12 English and Japanese captures (41 mm, both text sizes): Glance, permission and plan, for the
  length of the hold labels.
- 4 extra captures at the default text size, lower scroll anchor: the plan's Show all and the
  several-question paging under the text, both sizes.
- Synthetic English sample messages and example sessions; no live account data.
- The agent inspected every final image. This is a **large UI change**: independent human
  screenshot review is still required before merging.

**Native dark appearance only, as #8864 specifies and the owner reconfirmed.** watchOS has no
separate light appearance for this matrix. Both `simctl ui <watch> appearance light` and
`appearance dark` return code 45, `Runtime does not support userInterfaceStyle`. No duplicate or
recoloured images stand in for a light theme.

## What to look for

- Glance with fresh data and an answerable permission or plan next is one fixed screen: the ring,
  the request and the decision, nothing hidden under the decision. Its words shorten to fit on
  41 mm. Stale or offline data, questions and accessibility text scroll instead.
- The ring's middle is Needs You (sessions); the arcs and legend are approvals, questions and
  messages (requests and Inbox items). They are not a breakdown of the middle figure.
- Allow and Approve are held, never tapped. Details keep the decision and question paging under
  the scrolling text, which fades out above them; nothing overlays an option.
- The stale/offline toolbar mark is white on its solid button; calm pages sit on the black system
  background. Short permission and terminal text has no Show all; the long plan has it.

## Reproduce a capture

Generate the project with XcodeGen and build `PersonaWatch` for an arm64 watchOS Simulator with
signing disabled. Boot the watch profile through `scripts/app/sim-boot.sh --profile watch`, then
install the built app on the chosen 41 mm or 49 mm simulator. Use your configured bundle
identifier:

```sh
xcrun simctl launch "$WATCH_UDID" "$WATCH_BUNDLE" \
  -showWatchDashboard waiting -openWatchPage glance \
  -showLargeText YES -showWatchScrollBottom NO \
  -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
xcrun simctl io "$WATCH_UDID" screenshot glance.png
```

Terminate before each launch so the next fixture is applied. Fixture states are `waiting`, `calm`,
`stale`, `offline`, `partial`, `unpaired`, `permission`, `plan`, `question`, `screen`,
`elicitation` and `multiple`. Pages are `glance`, `queue`, `running` and `recordings`.
`-openWatchItem permission|plan|question|screen|elicitation|session` opens a detail;
`-openInboxFirst YES` opens the synthetic Inbox item; `-openRecording YES` opens the recorder.
`-showWatchScrollBottom YES` selects the bottom scroll anchor. These DEBUG fixtures bypass live
account configuration and use `example.invalid`; they do not prove a successful live-hub action.

## Verification and boundaries

- `PersonaWatch` simulator build: passed with Xcode 27.2, watchOS deployment target 10.0.
- Eleven relevant Swift suites passed, including dashboard counts, navigation, optimistic
  answers, quick questions, pet counts, group refresh, credentials, muting, token ratchets, the
  icon vocabulary and the type scale.
- No tap, hold, Crown, dictation, haptic or double-tap claim is made from these deterministic
  captures: they show resting states. Native Simulator gesture control was unavailable.
- #8866 real iPhone/Watch mirrored notifications with two hubs: **pending hardware**.
- #8865 real-hub Watch/phone/web answer convergence and end-to-end latency: **not run**, no
  approved live test fixture was available.

## Gallery

| Sheets | Contents |
| --- | --- |
| [01](sheet-01.png) [02](sheet-02.png) [03](sheet-03.png) [04](sheet-04.png) | 41 mm, default text |
| [05](sheet-05.png) [06](sheet-06.png) [07](sheet-07.png) [08](sheet-08.png) [09](sheet-09.png) | 41 mm, `.accessibility5` |
| [10](sheet-10.png) [11](sheet-11.png) [12](sheet-12.png) [13](sheet-13.png) | 49 mm, default text |
| [14](sheet-14.png) [15](sheet-15.png) [16](sheet-16.png) [17](sheet-17.png) [18](sheet-18.png) | 49 mm, `.accessibility5` |
| [English](locales-1.png) [Japanese](locales-2.png) | 41 mm, both text sizes |
| [Lower anchors](extras.png) | Plan Show all and question paging, default text, both sizes |
