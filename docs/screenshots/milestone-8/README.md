# Milestone 8 screenshots: stops from our own database

| File | What it shows |
|---|---|
| `01-home-partly-outside.png` | Home with the coverage message for a route partly outside the Netherlands (UI-test fixture). |
| `02-corridor-map-partly-outside.png` | The corridor map with the same message (UI-test fixture). |
| `03-home-largest-text.png` | Home at the largest accessibility text size, where the message, figures and buttons wrap and stack. |
| `04-real-data-enschede-gronau.png` | Real data: Enschede → Gronau imported against the local backend with the real Netherlands stops. 294 stops; about 3 km is in Germany. |
| `05-real-data-amsterdam-haarlem-dense.png` | Real data: Amsterdam → Haarlem, 3,094 stops. The pins form a solid wall, which is a known follow-up (clustering or filtering). |

The first three are produced by `CoverageAccessibilityTests`
(`TEST_RUNNER_SCREENSHOTS_DIR=… xcodebuild test -only-testing:CyclingCompanionUITests/CoverageAccessibilityTests`).
The real-data ones come from a simulator build pointed at a local backend
(`CC_BACKEND_BASE_URL=http://localhost:8080`), using the DEBUG `-e2eImportGPX <path>` launch hook.
