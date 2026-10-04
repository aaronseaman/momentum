# Momentum: handoff to Xcode on a Mac

## Quick status

| Area | State |
|---|---|
| Core logic (`MomentumKit`) | **Done and tested.** It compiles in Swift 6 strict-concurrency mode. All 49 unit tests pass on Linux (Swift 6.0.3) and on macOS in CI (Xcode 26.3). |
| SwiftUI app (`Momentum/`) | **Feature-complete for v1.0. It compiles for iOS and macOS with no errors or deprecation warnings** (CI, Xcode 26.3). A separate review checked it line by line against the 26 SDK; the runtime bugs it found are fixed. It has not been launched on a device or simulator yet. |
| Xcode project | `Momentum.xcodeproj`: one multiplatform target (iOS 18+, macOS 15+). Sources are folder-synced, so adding files needs no project edits. It links the local package. The shared scheme builds the app and runs the package tests. |
| Signing | **Not set.** Pick a team and a bundle ID (default `com.aaronseaman.Momentum`). |
| App Store assets | The app icon (iOS and macOS sizes), accent color and privacy manifest are included. Screenshots and store listing are not done. |

### CI status
GitHub Actions (`.github/workflows/ci.yml`) runs three jobs on every push: package tests, an iOS Simulator build and a macOS build. All three are green on `claude/momentum-app`.

### Check by hand in Xcode (flagged by the review, believed fine)
- `FoundationModels` must be weak-linked, because the deployment target (iOS 18 / macOS 15) is lower than the framework's (26). Run `otool -L` on the built binary and check it appears as `LC_LOAD_WEAK_DYLIB`, then launch once on an iOS 18 or macOS 15 device.
- If a newer SDK flags the `Binding(get:set:)` closures in SettingsView and ProjectsView for actor isolation, wrap their bodies in `MainActor.assumeIsolated { … }`.
- Siri and Shortcuts should show the four App Shortcuts with their descriptions.

### What still needs a Mac (in order)
1. Open the project and set the signing team and bundle ID.
2. Run on an iPhone simulator and on *My Mac*. Walk through onboarding, then Today, Radar, Projects, Money, Review and Settings.
3. Connect real integrations and confirm syncing works: GitHub token, App Store Connect `.p8` key, and optionally RevenueCat, Stripe and Claude.
4. Check notification actions on a device (answer a question from the notification), iOS background refresh (Debug → Simulate Background Fetch), the macOS menu bar extra, and launch at login.
5. If you use Xcode 26, turn on "On-device (Apple Intelligence)" under Settings → AI and confirm the `FoundationModels` path works.
6. Archive for both platforms and upload to TestFlight.

### Known limits (by design for v1.0)
- iCloud sync, widgets, Android and other integrations (GitLab, Linear, Jira, Google Play, AdMob, Paddle, Gumroad, Sensor Tower, Google Trends) are planned, not built.
- Trend momentum is measured from Reddit and Hacker News mentions, plus App Store search hints and reviews. These are free, public sources. Google Trends and TikTok have no usable public API.
- Reddit sometimes rate-limits unauthenticated requests. When that happens, research still works using the other sources.

---

## New session prompt (paste into Claude Code on your Mac)

```
You're picking up "Momentum", a native SwiftUI app for iOS 18+ and macOS 15+.
Repo: https://github.com/aaronseaman/momentum, branch claude/momentum-app.
Read README.md and docs/HANDOFF.md first.

Setup:
  git clone https://github.com/aaronseaman/momentum.git && cd momentum
  git checkout claude/momentum-app
  open Momentum.xcodeproj

Goal: get Momentum running on an iPhone simulator and on this Mac, with
no warnings that matter, then get it ready for TestFlight.

Do this in order and report back after each step:
1. Run `swift test --package-path MomentumKit`. All 49 tests must pass.
2. Build both platforms from the command line and fix any errors:
   xcodebuild -project Momentum.xcodeproj -scheme Momentum -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
   xcodebuild -project Momentum.xcodeproj -scheme Momentum -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
   Keep fixes small and local. Don't restructure the architecture: MomentumKit
   holds the logic, Momentum/ is a thin SwiftUI layer.
3. Ask me for my Apple Developer Team ID and the bundle ID I want. Set
   DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER on the Momentum target
   for both Debug and Release.
4. Boot an iPhone simulator, install the app and launch it. Take screenshots
   of onboarding, Today, Radar, Projects, Money, Review and Settings
   (xcrun simctl io booted screenshot). Look for layout problems (clipping,
   truncation, dark mode contrast, Dynamic Type at XL) and fix them.
5. Run the macOS build and check the main window (sidebar), the Settings
   window (⌘,), the menu bar extra, the keyboard shortcuts (⌘1–5, ⇧⌘F, ⇧⌘O)
   and that closing the window keeps the app running in the menu bar.
6. Ask me for a GitHub fine-grained token, then connect it in the app and
   confirm projects appear and get the right stages. Do the same for App
   Store Connect if I have a .p8 key handy.
7. Archive both platforms (Product → Archive, or xcodebuild archive) and
   fix any validation issues.
8. Commit with clear messages and push to claude/momentum-app.

Constraints: no new third-party dependencies. Keep it local-first: secrets
stay in the Keychain, the database stays AES-GCM encrypted. Keep the ADHD
rules: one next action, 1–3 direct questions a day, safe assumptions with
"tap to change", no red badges, no guilt copy.
```

---

## Architecture in one page

```
SwiftUI views (Momentum/Features)
   │ read AppModel state, call intent methods
AppModel (@MainActor @Observable, Momentum/App/AppModel.swift)
   │ update { data in … }    → debounced encrypted save + notification reschedule
   │ refresh()               → SyncService.run (network, off the main actor) → apply() via Reducers → Engine.tick
MomentumKit (pure Swift, Foundation only)
   Models        MomentumData (whole DB), Project, Opportunity, Question, Revenue…
   Engine        Engine.tick: assumptions → stage inference → step restock → stall/energy/research/
                 evening/weekly questions → revenue anomaly + investigation
                 QuestionEngine (budget, dedupe, answers, safe assumptions), Planner (next action),
                 Scoring (momentum/competition/difficulty/fit/opportunity), RevenueAnalytics,
                 Briefs/ReviewBuilder, MoneyQuery ("how much did I make…")
   Integrations  GitHub, App Store Connect (ES256 JWT on device, gzip sales TSV), RevenueCat v2,
                 Stripe, FX (frankfurter.dev), Research (iTunes Search/RSS/hints, HN Algolia, Reddit)
   AI            TextGenerator protocol: ClaudeClient (raw HTTP, claude-opus-5-5, effort low,
                 server-side refusal fallback), OnDeviceGenerator (FoundationModels) in the app
```

Key files:
- **Persistence:** `Momentum/Services/Storage.swift`. One sealed file in Application Support; the key lives in the Keychain (after-first-unlock). If the file can't be read, it's moved aside, never deleted. If the Keychain is locked, the app runs from memory and doesn't write.
- **Notifications:** `Momentum/Services/NotificationService.swift`. Briefs are rebuilt after each change. The current question becomes notification action buttons, and answers are handled in the background.
- **Background:** iOS uses `.backgroundTask(.appRefresh("app.momentum.refresh"))`. macOS runs a 30-minute loop while the app is open, and the menu bar extra plus launch at login keep it watching.

## Manual QA checklist
- [ ] First launch: onboarding has 3 screens and 2 questions, then Today shows a next action (Connect GitHub or Radar).
- [ ] Radar shows candidates within about 1 minute and fills in scores after research. "Research a keyword" works.
- [ ] Connect GitHub: up to 8 recently pushed repos become projects with inferred stages, and a notice offers removal.
- [ ] Next Action → Start 15-minute timer → full-screen timer → finish → "Did you finish it?" → Done → confetti (or a checkmark with Reduce Motion on).
- [ ] "I'm overwhelmed" hides everything except one tiny step and a 5-minute timer.
- [ ] An ignored question produces "I assumed … Tap to change", and Change reopens it.
- [ ] The Money "Ask" box answers "this month", "yesterday", "MRR" and "forecast".
- [ ] Export JSON and CSV opens the save dialog. Delete all data resets to onboarding.
- [ ] VoiceOver reads cards and buttons sensibly. Dynamic Type at XL doesn't clip. Dark mode looks right.
