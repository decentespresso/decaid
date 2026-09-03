# REA Profiles API

## Overview

Decent espresso machines support loading dynamic profiles with either pressure or flow-based steps. The JSON profile format is based on [Jeff Kletsky's v2 specification](https://pyde1.readthedocs.io/en/latest/profile_json.html).

REA supports loading profiles to the espresso machine either directly through the `/machine/profile` endpoint or by updating the `/workflow` endpoint (recommended for updating the complete brewing setup).

The REA Profile data object definition lives in `lib/src/models/data/profile.dart`.

## Workflow Final Targets

`WorkflowContext.targetYield` is beverage output weight in grams and drives scale-based stop-at-weight. `WorkflowContext.targetWaterVolume` is DE1-integrated machine water volume in milliliters and overrides `Profile.targetVolume` only for the existing volumetric fallback when no usable scale stop is available. A null workflow water target inherits the profile target; `0` disables volumetric stopping for that workflow. These quantities are never converted or used as fallbacks for each other.

Step transitions can be owned by either the DE1 firmware or the app. Firmware
owns pressure/flow `exit` conditions because they are encoded into the profile
sent to the machine. The app owns per-step `weight` exits because only the
tablet sees the external scale.

If a step defines both `weight` and `exit`, either condition can trigger the
transition. To avoid a race where the tablet's `skipStep` command arrives after
firmware already advanced the frame (accidentally skipping the *next* step),
the app checks proximity to the firmware exit threshold before acting:

- **Far from threshold** — the app sends `skipStep` immediately (no race risk).
- **Near threshold** — the app defers for up to 3 snapshot frames, checking
  whether the sensor is trending toward the firmware exit. If firmware advances
  the frame during this window, the app does nothing. If the deferral cap is
  reached, the app fires `skipStep` regardless.
- **Exit value ≤ 0** — treated as weight-only (no meaningful firmware exit).

## Key Capabilities

- List, create, update, and delete profiles via REST API
- Import and export the entire profile library
- Content-based hash IDs for automatic deduplication across devices
- Version tracking through parent-child relationships
- Default profile protection (bundled profiles cannot be permanently deleted)
- Pluggable storage backend (currently Drift/SQLite, swappable behind the `ProfileStorageService` interface)

## Architecture

The implementation follows REA's standard layered architecture with clear separation of concerns:

```
┌─────────────────────────────────────┐
│      REST API (ProfileHandler)      │  ← 11 endpoints
├─────────────────────────────────────┤
│   Business Logic (ProfileController)│  ← Validation, versioning, defaults
├─────────────────────────────────────┤
│  Storage Interface                  │  ← Abstract interface
│  (ProfileStorageService)            │
├─────────────────────────────────────┤
│  Storage Implementation             │  ← Drift/SQLite implementation
│  (DriftProfileStorageService)       │
└─────────────────────────────────────┘
```

#### Key Components

**ProfileRecord** (`lib/src/models/data/profile_record.dart`)
- Envelope around `Profile` with metadata
- Fields: `id` (profile hash), `profile`, `metadataHash`, `compoundHash`, `parentId`, `visibility`, `isDefault`, `createdAt`, `updatedAt`, `metadata`
- Uses content-based hashing for ID (see "Content-Based Hash IDs" section below)
- Immutable with `copyWith` support
- Full JSON serialization
- Hash recalculation on profile changes

**Visibility States**
- `visible`: Normal state, shown in UI
- `hidden`: Hidden from UI but not deleted (default profiles can only be hidden, not deleted)
- `deleted`: Soft delete state (user profiles only, can be purged later)

**ProfileStorageService** (`lib/src/services/storage/profile_storage_service.dart`)
- Abstract interface defining all storage operations
- Allows swapping implementations (Drift/SQLite, or others)
- Methods: `store`, `get`, `getAll`, `update`, `replace`, `delete`, `getByParentId`, `storeAll`, `count`
- `replace` atomically stores an ID-changing replacement and removes the old record; an existing target ID rejects the update without changing either record

**DriftProfileStorageService** (`lib/src/services/storage/drift_profile_storage.dart`)
- Active implementation, backed by the shared Drift `AppDatabase` (SQLite)
- Delegates to `ProfileDao` (`lib/src/services/database/daos/profile_dao.dart`) over the `ProfileRecords` table (`lib/src/services/database/tables/profile_tables.dart`)
- Row shape via `ProfileMapper` (`lib/src/services/database/mappers/profile_mapper.dart`): `id`/`metadataHash`/`compoundHash`/`parentId`/`visibility`/`isDefault`/`createdAt`/`updatedAt` as columns, full profile stored in the `profileJson` column
- Supports visibility filtering and batch import/export

**ProfileController** (`lib/src/controllers/profile_controller.dart`)
- Business logic and validation layer
- Auto-loads default profiles from `assets/defaultProfiles/` on every startup (idempotent: seeds new ones, skips existing by content hash). Seeding **preserves the stored visibility** of an existing default, so a default the user hid stays hidden across restarts (re-show it with `POST /api/v1/profiles/restore/{filename}`)
- **Bundled provenance**: a default profile JSON may carry `"parent_id": "profile:…"` (the immutable content-hash id of the parent bundled profile); seeding then sets that record's `parentId` to the fixed id (after validating the parent exists, idempotent). `best_practice_v3.json` links back to `best_practice.json`'s exact content version, and both appear in the v3 lineage. A fixed id (not a filename) keeps lineage stable even if the parent file's content changes in a future release
- **Curation upkeep** (so edits to bundled defaults reach existing installs): refreshes a default's presentation fields (title/author/notes) when the bundled `metadataHash` changes but content is unchanged; and `_retireStaleDefaults` hides any default whose `metadata.filename` left the manifest, or whose stored id no longer matches the current bundled version (content changed). Retired defaults are hidden, never deleted
- Enforces default profile protection (cannot be deleted, only hidden; cannot modify execution fields)
- Validates parent profile existence before creating children
- **Automatic deduplication**: Identical profiles share the same hash-based ID
- **Smart updates**: When execution fields change, the new hash record replaces the old record in one Drift transaction. A target-ID collision rejects the update and preserves both existing records
- Profile lineage tracking via `getLineage()`
- Import/export with detailed results (imported/skipped/failed counts)
- Exposes `profileCount` stream for UI updates

**ProfileHandler** (`lib/src/services/webserver/profile_handler.dart`)
- REST API endpoints with comprehensive error handling
- Request validation and proper HTTP status codes
- Logging for all operations

### Content-Based Hash IDs

REA uses **content-based hashing** for profile identification instead of random UUIDs or custom IDs. This provides:
- **Automatic deduplication**: Identical profiles have identical IDs across all installations
- **Cloud sync support**: Same profile content = same ID everywhere
- **Conflict-free merging**: No manual conflict resolution needed
- **Provable identity**: ID proves the profile content hasn't changed

#### Hash Types

Profiles use three SHA-256 hashes:

**1. Profile Hash (Primary ID)**
- Calculated from execution-relevant fields:
  - `beverage_type`, `steps`, `tank_temperature`, `target_weight`, `target_volume`, `target_volume_count_start`, `version`
- Format: `profile:<first_20_chars_of_hash>`
- Example: `profile:a3f2c8b4d1e6f9a21c7d`
- Used as the profile record's unique ID

**2. Metadata Hash**
- Calculated from presentation fields:
  - `title`, `author`, `notes`
- Full 64-character SHA-256 hash
- Detects cosmetic changes (title translations, author attribution, etc.)

**3. Compound Hash**
- Hash of (profile_hash + metadata_hash)
- Detects ANY changes to the profile
- Useful for sync conflict detection

#### How It Works

```dart
// Two profiles with same execution but different metadata
Profile profile1 = Profile(
  title: "Espresso",
  author: "Alice",
  steps: [...],
  tankTemperature: 93.0,
  ...
);

Profile profile2 = Profile(
  title: "Espresso Classico",  // Different title
  author: "Bob",                // Different author
  steps: [...],                 // Same execution
  tankTemperature: 93.0,        // Same settings
  ...
);

// Both get the SAME profile hash (ID)
record1.id == record2.id  // true! 

// But different metadata hashes
record1.metadataHash != record2.metadataHash  // true

// And different compound hashes
record1.compoundHash != record2.compoundHash  // true
```

This enables REA to:
- Identify functionally identical profiles regardless of name/author
- Detect cosmetic changes without creating duplicate entries
- Merge profile libraries from multiple sources automatically

#### Default Profiles

Default profiles are bundled in `assets/defaultProfiles/`:
- `manifest.json`: Simple list of filenames
- Individual `.json` files for each profile
- Loaded automatically on first startup
- IDs calculated from content (same calculation everywhere)
- Marked with `isDefault: true`
- Cannot be permanently deleted (only hidden)
- Can be restored via `/api/v1/profiles/restore/{filename}` endpoint

Manifest structure:
```json
{
  "version": "1.0.0",
  "description": "Default espresso profiles bundled with Decaid",
  "profiles": [
    "best_practice.json",
    "cremina.json",
    "manual_flow.json"
  ]
}
```

#### Migration from Old Installations

**Clean slate approach**: Existing installations with UUID-based profiles should either:
1. **Reinstall** - Fresh install with hash-based IDs
2. **Database reset** - Clear profiles (shot history preserved separately)

No automatic migration is provided since hash-based IDs fundamentally change the identity model.

### Profile Versioning

Profiles support version tracking through parent-child relationships:

```
Original Profile (id: A, parentId: null)
  ├── Modified v1 (id: B, parentId: A)
  └── Modified v2 (id: C, parentId: A)
        └── Modified v2.1 (id: D, parentId: C)
```

Use the `/api/v1/profiles/{id}/lineage` endpoint to retrieve the full version tree (all parents and children).

### API Endpoints

All endpoints return JSON and use appropriate HTTP status codes.

#### List Profiles
```http
GET /api/v1/profiles
```

Query parameters:
- `visibility`: Filter by visibility state (`visible`, `hidden`, `deleted`)
- `includeHidden`: Include hidden profiles (boolean)
- `parentId`: Filter by parent ID (for version tracking)

Response: Array of `ProfileRecord` objects

#### Get Single Profile
```http
GET /api/v1/profiles/{id}
```

Response: Single `ProfileRecord` object or 404 if not found

#### Create Profile
```http
POST /api/v1/profiles
Content-Type: application/json

{
  "profile": { /* Profile object */ },
  "parentId": "optional-parent-uuid",
  "metadata": { /* optional metadata */ }
}
```

Response: Created `ProfileRecord` (201) or validation error (400)

#### Update Profile
```http
PUT /api/v1/profiles/{id}
Content-Type: application/json

{
  "profile": { /* Updated Profile object */ },
  "metadata": { /* optional metadata */ }
}
```

Omitted fields are preserved. Set `metadata` to `null` to clear stored metadata, or pass an object to replace it. The `profile` field is non-nullable; explicit `null` returns 400.

Cannot modify the `profile` field of default profiles (only metadata). If execution changes produce a new ID, replacement is atomic. If that ID already exists, the update is rejected and both profiles remain unchanged.

Response: Updated `ProfileRecord` (200) or error (400/404)

#### Delete Profile
```http
DELETE /api/v1/profiles/{id}
```

Behavior:
- Default profiles: Changes visibility to `hidden`
- User profiles: Changes visibility to `deleted` (soft delete)

Response: Success message with profile ID (200) or error (404)

#### Change Visibility
```http
PUT /api/v1/profiles/{id}/visibility
Content-Type: application/json

{
  "visibility": "visible" | "hidden" | "deleted"
}
```

Note: Cannot set default profiles to `deleted` state.

Response: Updated `ProfileRecord` (200) or error (400/404)

#### Get Profile Lineage
```http
GET /api/v1/profiles/{id}/lineage
```

Returns the full version history/tree (all parents and children).

Response: Array of `ProfileRecord` objects in lineage order

#### Permanently Delete Profile
```http
DELETE /api/v1/profiles/{id}/purge
```

**Warning**: Permanently removes profile from storage. Cannot purge default profiles.

Response: Success message (200) or error (400/404)

#### Import Profiles
```http
POST /api/v1/profiles/import
Content-Type: application/json

[
  { /* ProfileRecord */ },
  { /* ProfileRecord */ },
  ...
]
```

Batch import from backup. Skips profiles that already exist.

Response:
```json
{
  "imported": 10,
  "skipped": 2,
  "failed": 0,
  "errors": []
}
```

#### Export Profiles
```http
GET /api/v1/profiles/export?includeHidden=false&includeDeleted=false
```

Query parameters:
- `includeHidden`: Include hidden profiles (boolean, default: false)
- `includeDeleted`: Include deleted profiles (boolean, default: false)

Response: JSON array of all `ProfileRecord` objects

#### Restore Default Profile
```http
POST /api/v1/profiles/restore/{filename}
```

Restores a bundled default profile from assets by filename (e.g., `Default1.json`). Use `GET /api/v1/profiles/defaults` (below) to discover valid filenames.

Response: Restored `ProfileRecord` (200) or error (404)

#### List Bundled Defaults
```http
GET /api/v1/profiles/defaults
```

Lists every entry from the bundled defaults manifest with its metadata. Each element:

```json
{
  "filename": "Default1.json",
  "title": "Default 1",
  "author": "Decent",
  "notes": "...",
  "beverageType": "espresso"
}
```

Use the `filename` from any entry as the `{filename}` path parameter for `POST /api/v1/profiles/restore/{filename}`.

Returns an empty array if the manifest is missing or unreadable. Per-file parse failures are skipped server-side and logged.

Response: `200` with array of descriptors.

### Usage Examples

**Create a new profile:**
```bash
curl -X POST http://localhost:8080/api/v1/profiles \
  -H "Content-Type: application/json" \
  -d '{
    "profile": {
      "version": "2",
      "title": "My Custom Profile",
      "author": "Jane Doe",
      "beverage_type": "espresso",
      "steps": [...],
      "tank_temperature": 93
    }
  }'
```

**Create a modified version (child profile):**
```bash
curl -X POST http://localhost:8080/api/v1/profiles \
  -H "Content-Type: application/json" \
  -d '{
    "profile": {...},
    "parentId": "profile:a3f2c8b4d1e6f9a2"
  }'
```

**Hide a default profile:**
```bash
curl -X DELETE http://localhost:8080/api/v1/profiles/{id}
```

**Restore a hidden default profile:**
```bash
curl -X PUT http://localhost:8080/api/v1/profiles/{id}/visibility \
  -H "Content-Type: application/json" \
  -d '{"visibility": "visible"}'
```

**Export all profiles for backup:**
```bash
curl http://localhost:8080/api/v1/profiles/export > profiles_backup.json
```

**Import profiles from backup:**
```bash
curl -X POST http://localhost:8080/api/v1/profiles/import \
  -H "Content-Type: application/json" \
  -d @profiles_backup.json
```

**Discover and restore a bundled default:**
```bash
# 1. Discover available defaults
curl http://localhost:8080/api/v1/profiles/defaults | jq '.[].title'

# 2. Restore one by filename
filename=$(curl -s http://localhost:8080/api/v1/profiles/defaults | jq -r '.[0].filename')
curl -X POST "http://localhost:8080/api/v1/profiles/restore/${filename}"
```

### Testing

Unit tests are located in `test/profile_test.dart` with 21 comprehensive tests covering:

**Hash Mechanism Tests:**
- Consistent hash calculation from execution fields
- Different execution fields produce different hashes
- Metadata hash calculation and consistency
- All three hashes calculated together
- Hash stability across serialization

**ProfileRecord Tests:**
- Hash-based ID generation
- Identical profiles produce identical IDs (deduplication)
- Same execution + different metadata = same profile ID
- JSON serialization/deserialization with hashes
- Hash recalculation in copyWith()

**Storage Tests:**
- Store and retrieve by hash ID
- Automatic deduplication with hash-based IDs
- Visibility filtering

**Versioning Tests:**
- Version tree creation with parent ID references
- Profile lineage tracking

**Default Profile Protection:**
- isDefault flag persistence
- Soft delete vs hide behavior

**Hash Update Mechanics:**
- Metadata-only updates keep same profile ID
- Execution field updates change profile ID
- Combined updates change all hashes
- Cross-user/device deduplication
- Serialization stability
- Beverage type changes update profile hash

Run tests with:
```bash
flutter test test/profile_test.dart
```

### Storage Details

**Why Hive?**
- Already integrated in REA
- Native Dart/Flutter support
- Excellent for document-oriented JSON storage
- Fast key-value operations
- No SQL migration complexity
- Cross-platform support (all required platforms except web)

**Performance Characteristics:**
- Hive is fast for < 10,000 records
- Profile libraries unlikely to exceed 1,000 profiles
- No in-memory caching needed initially
- Filtering by visibility is efficient enough
- Batch operations optimize import/export

**Future Considerations:**
If storage needs change (e.g., complex queries, relationships), the abstract `ProfileStorageService` interface allows easy migration to SQLite or other systems without changing controller or API code.

### Integration with Workflow API

To use a profile with the DE1 machine, either:

1. **Direct upload to machine:**
```bash
curl -X POST http://localhost:8080/api/v1/machine/profile \
  -H "Content-Type: application/json" \
  -d '{...profile...}'
```

2. **Via Workflow API (recommended):**
```bash
# Get the profile
PROFILE=$(curl http://localhost:8080/api/v1/profiles/{id})

# Update workflow with the profile
curl -X PUT http://localhost:8080/api/v1/workflow \
  -H "Content-Type: application/json" \
  -d "{\"profile\": $(echo $PROFILE | jq '.profile')}"
```

The Workflow API approach updates the entire workflow context (profile + dose + grinder + coffee data).

### Error Handling

All endpoints follow consistent error handling:

**400 Bad Request:**
- Invalid visibility value
- Missing required fields
- Invalid parent ID
- Attempting to delete/modify default profile incorrectly

**404 Not Found:**
- Profile ID doesn't exist
- Default profile filename not found

**500 Internal Server Error:**
- Storage failures
- Unexpected exceptions
- Includes error message and stack trace in logs

Example error response:
```json
{
  "error": "Profile not found",
  "id": "profile-uuid"
}
```

### Simulated shot execution (MockDe1 / MockBengle)

Mock machines execute profiles in a simulated shot loop that follows profile step targets (flow, pressure, temperature) with simplified machine-response dynamics. Pressure steps model flow limiters and flow steps model pressure limiters with a progressive response across each limiter's range of action. This is a simulator approximation rather than firmware control-loop emulation. Each shot also samples bounded puck resistance so repeated pulls are not identical. Design decisions are recorded in archived plans — see `doc/plans/archive/mock-shot-simulator/mock-shot-fidelity.md` for the substate model, flow→pressure coupling, weight accumulation, transition shaping, and skipStep semantics.

### Profile Wire Format

Profile uploads encode flow and pressure values at a machine-specific resolution.
The app selects the format based on the connected device implementation.

| Field | DE1 (v1) | Bengle (v2) |
|-------|----------|-------------|
| Header version | 1 | 2 |
| Flow/pressure scale | 1/16 | 1/10 (U8D1) |
| Header max flow byte | 12 × 16 = 192 (`0xC0`) | 12 × 10 = 120 (`0x78`) |

Affected fields: header minimum pressure, header maximum flow, frame
target, frame trigger, extension limiter value, extension limiter range.
All other fields (temperature, duration, volume, flags, tail) are
identical across formats.

### Profile Synchronization with Hardware

#### Ownership

`WorkflowDeviceSync` owns profile uploads caused by workflow changes and
machine connect/reconnect. `De1Controller` no longer uploads the profile
as part of startup defaults — `POST /api/v1/machine/profile` remains a
direct machine operation outside workflow synchronization.

#### Two Cache Layers

| Cache | Location | Cleared on | Effect |
|-------|----------|------------|--------|
| `_lastPushedProfile` | `WorkflowDeviceSync` | Disconnect, upload failure | Prevents redundant uploads within one connection |
| `_currentProfile` | `UnifiedDe1` | Every `onConnect()`, every upload start | Prevents redundant uploads within one device session |

Both must be cleared on connection edges. The sync cache is cleared when
the machine disconnects; the device cache is cleared in `onConnect()`
before the `_info` guard so every connection edge forces a complete
physical upload.

#### Retry and Failure Behavior

- Failed workflow profile uploads retry with capped backoff (3s, 10s, 30s).
- Intermediate workflow changes coalesce — only the latest profile is
  pushed when the current upload finishes.
- `profileUploadFailed` is surfaced on `ConnectionManager.status` while
  retries are active. It persists across phase transitions and is cleared
  when a retry lands, the machine disconnects, or the sync is disposed.
- See `doc/plans/archive/profile-upload-recovery/design.md` for the full
  design rationale.

### Future Enhancements

- **Cloud Sync**:

  Hash-based IDs make conflict-free cloud sync straightforward
  - Same content = same ID everywhere (no merge conflicts)
  - Sync compound hashes to detect any changes
  - Implement three-way merge using parent IDs
- **Change Tracking**: Detailed diff between profile versions
  - Use metadata hash to detect cosmetic-only changes
  - Show execution vs presentation changes separately
- **Tags/Categories**: Organize profiles by category, beverage type, etc.
- **Search**: Full-text search in profile metadata and content
- **Sharing**: Share profiles with other users (export as shareable link)
  - Hash ID proves authenticity (content hasn't been tampered)
- **Auto-cleanup**: Configurable purge of old deleted profiles (e.g., 30 days)
- **Profile Templates**: Pre-configured templates for common brewing styles
- **Smart Import**: When importing, use compound hash to detect duplicates with different IDs from old UUID-based exports

