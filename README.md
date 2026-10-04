# Momentum

An ADHD-first command center for indie app developers, built as a native SwiftUI app for **iPhone, iPad and Mac**. You answer a few simple questions, and Momentum handles the rest.

- **Today** shows one next action with a 15-minute timer, one direct question, a revenue snapshot, one rising opportunity, a focus session button and an "I'm overwhelmed" button.
- **Radar** researches app ideas from App Store search, App Store reviews, Reddit and Hacker News. Each idea gets a momentum, competition, difficulty and personal-fit score.
- **Projects** reads GitHub and App Store Connect to work out each project's stage, notices when a project stalls, and keeps a queue of 5–25 minute steps.
- **Money** combines App Store Connect sales, RevenueCat and Stripe into one view: yesterday's income, MRR/ARR, forecasts and anomaly checks. You can ask questions in plain words, like "How much did I make this month?"
- **Review** gives weekly and monthly summaries with forgiving streaks.
- **Settings** covers integrations, AI choice, notifications, focus options, export and delete.

## Principles in code

| Principle | Where it lives |
|---|---|
| Infer first, ask only when needed | `MomentumKit/Engine/StageInference.swift`, `Reducers.swift` |
| 1–3 direct questions a day, a safe assumption when ignored, one tap to change it | `MomentumKit/Engine/QuestionEngine.swift`, `Engine.swift` |
| One next action that matches your energy | `MomentumKit/Engine/Planner.swift` |
| No shame: no red badges, partial sessions count, a "welcome back" instead of overdue items | `Briefs.swift`, `ReviewBuilder`, `NotificationService` (no badges) |
| Local-first and encrypted | `Momentum/Services/Storage.swift` (AES-GCM file plus a Keychain key) |
| Notifications you can answer without opening the app | `Momentum/Services/NotificationService.swift` |

## Project layout

```
Momentum.xcodeproj          Multiplatform app target (iOS 18+, macOS 15+); sources are folder-synced
Momentum/                   SwiftUI app: App/, Services/, Design/, Features/, Intents/, Assets
MomentumKit/                Pure-Swift core package (models, engines, API clients) with 49 unit tests
Config/                     Info.plist additions and macOS sandbox entitlements
scripts/make_icons.py       Regenerates the app icons
.github/workflows/ci.yml    Builds iOS and macOS and runs the core tests on every push
```

`MomentumKit` uses only Foundation, so the logic is tested on its own (`swift test --package-path MomentumKit`). The app layer is a thin SwiftUI shell around it.

## Running it

1. Open `Momentum.xcodeproj` in Xcode 16 or newer (Xcode 26 turns on on-device Apple Intelligence).
2. Select the **Momentum** target, then go to *Signing & Capabilities*. Pick your team and set your own bundle ID (the default is `com.aaronseaman.Momentum`).
3. Run on an iPhone simulator or on *My Mac*.

The app works with no setup: the Radar uses public sources. Connect integrations under **Settings → Integrations**:

| Integration | What you need |
|---|---|
| GitHub | A fine-grained token with read access to Contents, Metadata, Actions and Issues |
| App Store Connect | An API key (Issuer ID, Key ID, `.p8` file) and your vendor number for sales |
| RevenueCat | A v2 secret key with `charts_metrics:overview:read`, plus the project ID |
| Stripe | A restricted key with read access to Balance and Subscriptions |
| Claude (optional AI) | An Anthropic API key. Uses the `claude-opus-5-5` model at low effort |

Secrets are kept only in the Keychain. They are never stored in the database or included in exports.

## Privacy

- All data lives on the device in one AES-GCM-encrypted file. The key is in the Keychain.
- There are no accounts, no analytics and no tracking. The privacy manifest declares no data collection.
- Network calls go only to the services you connect, plus public research endpoints: iTunes Search/RSS, Reddit, Hacker News Algolia, and frankfurter.dev for exchange rates.
- You can export everything as JSON or CSV, or delete everything, from Settings.

## Scope of v1.0

**Included:** the integrations listed above, App Store and public-web research, local notifications with inline answers, background refresh on iOS, a menu bar extra and launch at login on macOS, write-only calendar blocking, Siri and Shortcuts intents, on-device or Claude AI with a rules-only fallback, and JSON/CSV export.

**Planned (not in v1.0):** end-to-end encrypted iCloud sync, widgets, Android, GitLab/Bitbucket/Linear/Jira, Google Play/AdMob/Paddle/Gumroad, paid keyword tools (Sensor Tower, Appfigures), Google Trends, TikTok/X, and live co-working rooms. These need either a backend or paid API contracts. The integration layer (`HTTPClient` + a client + a reducer) is built so each one can be added as a single file.
