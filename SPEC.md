# Lightweight iOS Memos Client — Product + Technical Spec

## Goal

Build a super lightweight iOS client for quick capture and reliable drafting, optimized for:
- persistent drafts that survive screen lock/app backgrounding
- a simple draft list with saved state
- a minimal plain-text editor (no formatting UI)
- a single Send button
- configurable REST endpoint to send notes to a self-hosted Memos server
- iCloud sync for drafts across the user's own devices

## Non-goals

- rich formatting toolbar (Markdown UI controls)
- full Memos feature parity (tags browser, search, comments, sharing, permissions management)
- multi-account support (v1)
- offline sync / bi-directional sync with Memos (v1)
- background “auto-send” (v1)
- syncing API token or endpoint settings via iCloud (v1)

## Primary use case

- User opens the app, starts typing a note.
- User locks the screen.
- Later, user unlocks and returns to the same in-progress draft.
- User taps Send to push the note to Memos via REST API.
- On successful send, the draft moves to Archive and is marked Sent.

---

## UX requirements

### Draft list screen
- Shows two lists (Active, Archive), each sorted by most recently updated.
- Each row shows:
  - Title: first non-empty line (fallback “Untitled”)
  - Timestamp: updatedAt
  - Status badge: Unsent / Sending / Sent / Failed
- Interactions:
  - Tap row → open Draft editor
  - Swipe actions (Active):
    - Delete
    - Duplicate
    - Send (if unsent/failed)
  - Swipe actions (Archive):
    - Delete
    - Duplicate
- Toolbar actions:
  - New draft
  - Settings

### Draft editor screen
- Minimal plain-text TextEditor (no formatting controls)
- Autosave (debounced) while typing
- Send button
  - Disabled when text is empty or whitespace-only
  - Shows progress state when sending
- Error UX
  - Non-blocking error display (alert or inline banner)
  - “Retry send” available

### Settings screen
- Memos API base URL (string)
- API token (stored securely; see Security)
- Optional toggles (v1):
  - Keep text after successful send (default: ON)
  - Mark as “Sent” on success (default: ON)
  - Clear error state on edit (default: ON)
- Validation:
  - Require https:// by default
  - Allow http:// only if user explicitly enables “Allow insecure HTTP” (OFF by default)

---

## Functional requirements

### Draft persistence
- Draft text and metadata must persist across:
  - app termination
  - screen lock/unlock
  - backgrounding/foregrounding
  - OS memory pressure
- Autosave should:
  - update updatedAt
  - never block typing
  - avoid excessive writes (debounce)

### Draft list state
- The list must reflect:
  - saved draft content
  - last updated time
  - send state (idle/sending/sent/failed)
  - last error (for failed)
  - archive state (active vs archived)

### Sending
- Send creates a memo on the server via REST API.
- On success:
  - set lastSentAt
  - set sendState = sent
  - set isArchived = true
  - optionally keep text as-is
- On failure:
  - set sendState = failed
  - store lastError message
  - allow retry without losing text

### iCloud sync (drafts only)
- Draft records sync across the user's own devices signed into the same Apple ID.
- Sync uses the app's private CloudKit database via SwiftData.
- If iCloud is unavailable, local persistence still works and sync resumes when available.
- API token and endpoint/settings do not sync via iCloud in v1.
- Conflict handling in v1: last-write-wins is acceptable.

---

## Technical architecture

### Platform baseline
- Target: iOS 17+ using SwiftUI + SwiftData
  - Rationale: simplest persistence and list queries for “recent drafts”

### Layers
- UI: SwiftUI views (DraftListView, DraftEditorView, SettingsView)
- Persistence: SwiftData model for drafts + lightweight settings storage
- Cloud sync: SwiftData + CloudKit (private database) for Draft records
- Secrets: Keychain for API token
- Networking: URLSession-based client

---

## Data model

### Draft entity
Fields:
- id: UUID (unique)
- text: String
- createdAt: Date
- updatedAt: Date
- lastSentAt: Date? (nil if never sent)
- sendState: enum { idle, sending, sent, failed }
- lastError: String?
- isArchived: Bool (default false)

Derived fields:
- titleLine: first line of text (trimmed), fallback “Untitled”

### Settings
- endpointBaseURL: String (UserDefaults)
- token: String (Keychain)
- allowInsecureHTTP: Bool (UserDefaults; default false)
- keepTextAfterSend: Bool (default true)

---

## API contract (Memos)

### Endpoint
- POST {baseURL}/api/v1/memos

### Auth
- Authorization: Bearer <token>

### Content type
- application/json

### Request body
```json
{ "content": "plain text draft" }
```

### Success criteria
- HTTP 2xx indicates memo created.

### Failure criteria
- Non-2xx status code → treat as failure and store status + message if available.

---

## Networking behavior

### Request rules
- Base URL must be valid and include scheme.
- If baseURLString ends with a trailing slash, normalize before appending path.
- Timeout: 10–20 seconds default.
- Never log token.

### Error handling
- Map to user-facing messages:
  - Not configured (missing URL or token)
  - Bad URL
  - Network error (offline, DNS)
  - HTTP error (status code)
  - Server response parse error (if parsing is added later)

---

## Security and privacy

### Token storage
- Store API token in Keychain.
- Token is never persisted in SwiftData or UserDefaults.

### Transport security
- Default requires https://
- Optional “Allow insecure HTTP” is opt-in and clearly labeled.
- Consider App Transport Security exceptions only if explicitly needed and user enabled insecure mode.

### Local data
- Drafts stored locally (SwiftData) are sensitive.
- v1: no biometric lock; optional “App Lock” can be a future enhancement.

### iCloud data scope
- Only Draft data syncs via iCloud.
- Token remains in device Keychain only and is never synced by app data storage.
- Endpoint URL and toggles remain device-local in v1.

---

## Implementation plan

### Milestone 1 — Local drafts (no networking)
- SwiftUI navigation + two screens:
  - DraftListView
  - DraftEditorView
- SwiftData model Draft
- Autosave debounce that updates updatedAt
- Create/delete/duplicate drafts
- Draft titleLine derivation
- Basic status display (all idle)

Acceptance:
- Create draft, type, lock screen, unlock, return to same draft text.
- Kill app and reopen → drafts intact.

### Milestone 2 — iCloud sync for drafts
- Enable iCloud + CloudKit capability for app target.
- Configure SwiftData container to use CloudKit private database for Draft model.
- Validate sync behavior on two devices/simulators signed into same Apple ID.

Acceptance:
- Draft created/edited on device A appears on device B.
- Deletion on one device propagates to other device.
- App remains usable with local drafts when iCloud is temporarily unavailable.

### Milestone 3 — Settings + Keychain
- Settings screen
- Endpoint stored in UserDefaults
- Token stored in Keychain with simple wrapper:
  - setToken(), getToken(), deleteToken()

Acceptance:
- Token persists across app restarts.
- Token never appears in logs.

### Milestone 4 — Send flow
- MemosClient with URLSession POST
- Send button calls client
- Update sendState and timestamps
- Auto-archive on successful send
- Retry support for failed drafts
- Error message surfaced to user

Acceptance:
- Successful send marks as Sent and records lastSentAt.
- Successful send moves draft from Active to Archive.
- Failed send preserves draft and displays error.

### Milestone 5 — UX polish (still minimal)
- Swipe actions (Delete, Duplicate, Send)
- Sending progress indicator
- Optional “Keep text after send” toggle
- Active/Archive list switch
- Inline error banner (optional)

Acceptance:
- One-handed, quick capture workflow feels smooth and predictable.

---

## Edge cases and decisions

### Drafts that were already sent
- Keep in Archive with Sent status.
- Allow sending again (duplicate memo) only via explicit action:
  - “Send again” (future) or keep Send enabled but confirm (v1 decision: disable Send for Sent unless edited after send).

Suggested v1 logic:
- If lastSentAt != nil and updatedAt <= lastSentAt → treat as Sent, disable Send, and keep isArchived = true.
- If user edits after send (updatedAt > lastSentAt) → status becomes Unsent and set isArchived = false.

### Editor autosave strategy
- Debounce 250–500ms; update updatedAt only after debounce.
- Avoid writing on every keystroke.

### Backgrounding
- Ensure draft.updatedAt is updated when app goes to background if there are pending debounced saves.
- Option: flush save on scenePhase change to .background.

### iCloud conflict behavior
- v1 accepts last-write-wins if the same draft is edited on multiple devices at nearly the same time.
- No custom merge UI in v1.

---

## Minimal code skeleton (reference)

### SwiftData model
```swift
import Foundation
import SwiftData

@Model
final class Draft {
    @Attribute(.unique) var id: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var lastSentAt: Date?
    var sendStateRaw: Int
    var lastError: String?
    var isArchived: Bool

    init(text: String = "") {
        self.id = UUID()
        self.text = text
        self.createdAt = Date()
        self.updatedAt = Date()
        self.lastSentAt = nil
        self.sendStateRaw = 0
        self.lastError = nil
        self.isArchived = false
    }

    enum SendState: Int { case idle = 0, sending, sent, failed }
    var sendState: SendState {
        get { SendState(rawValue: sendStateRaw) ?? .idle }
        set { sendStateRaw = newValue.rawValue }
    }

    var titleLine: String {
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
        return first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? "Untitled"
    }
}
```

### Networking client (Bearer token)
```swift
import Foundation

enum MemosError: Error {
    case notConfigured
    case badURL
    case badResponse(Int)
}

final class MemosClient {
    static let shared = MemosClient()
    private init() {}

    var baseURLString: String = ""
    var token: String = "" // inject from Keychain at runtime

    func createMemo(content: String) async throws {
        guard !baseURLString.isEmpty, !token.isEmpty else { throw MemosError.notConfigured }
        guard let base = URL(string: baseURLString) else { throw MemosError.badURL }
        let url = base.appendingPathComponent("api/v1/memos")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["content": content]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MemosError.badURL }
        guard (200..<300).contains(http.statusCode) else { throw MemosError.badResponse(http.statusCode) }
    }
}
```

---

## Open items (v1 decisions to finalize)
- “Send disabled after send” rule (recommended logic above)
- Whether to support http:// at all (recommended: only with explicit toggle)
- Whether iCloud sync is required by default or can be disabled by a user-facing toggle (recommended: required by default, no toggle in v1)
