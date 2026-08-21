# Skins.md

## WebUI Development Guide for Decaid

This guide covers how to develop custom web-based user interfaces (skins) for the Decaid gateway. Skins connect to the Decaid API to control espresso machines, read sensor data, and create custom user experiences.

### What is a Skin?

A **skin** is a web application that communicates with Decaid via REST and WebSocket APIs. Skins can:
- Display real-time machine state (temperatures, pressures, flow rates)
- Control espresso shot execution and machine state
- Manage profiles and workflows
- Manage coffee beans, grinder equipment, and link them to workflows
- Visualize shot data in real-time
- Browse and filter shot history
- Control screen brightness and wake-lock behavior
- Manage machine sleep schedules and presence-based auto-sleep
- Customize the user experience with different UI/UX paradigms

### Example Skin

The **Streamline Project** is a reference implementation:
- Repository: https://github.com/allofmeng/streamline_project
- Demonstrates all core API interactions
- Shows best practices for WebSocket handling
- Provides real-time shot visualization

---

## Architecture Overview

### Connection Model

```
┌─────────────────┐
│   Web Browser   │
│   (Your Skin)   │
└────────┬────────┘
         │ HTTP/WS
         │ (REST & WebSocket)
         ▼
┌─────────────────┐
│ Decaid          │
│   :8080         │
└────────┬────────┘
         │ BLE/Serial
         ▼
┌─────────────────┐
│  DE1 Machine    │
│  Scales/Sensors │
└─────────────────┘
```

### API Structure

- **REST API**: Port 8080 - Control commands, configuration, data retrieval
- **WebSocket API**: Port 8080 - Real-time state updates, shot telemetry
- **API Documentation**: Port 4001 - Interactive API docs (when enabled)

### Embedded Skin Lifecycle

On Android and iOS, Decaid pauses the embedded WebView while the app is
backgrounded. After ten minutes in the background, it unloads the page and
reloads the selected skin when the app returns. Skin state that must survive
this reload should be persisted through the Decaid API or browser storage.

---

## Getting Started

### 1. Basic Connection

Connect to the Decaid gateway at `http://<gateway-ip>:8080`

```javascript
const GATEWAY_URL = 'http://192.168.1.100:8080';
const WS_URL = 'ws://192.168.1.100:8080';

// Test connection
fetch(`${GATEWAY_URL}/api/v1/machine/state`)
  .then(res => res.json())
  .then(data => console.log('Machine state:', data))
  .catch(err => console.error('Connection failed:', err));
```

### 2. WebSocket Connection for Real-Time Updates

The primary way to receive real-time machine updates is via the **snapshot WebSocket**:

```javascript
const ws = new WebSocket(`${WS_URL}/ws/v1/machine/snapshot`);

ws.onopen = () => {
  console.log('Connected to machine snapshot stream');
};

ws.onmessage = (event) => {
  const snapshot = JSON.parse(event.data);
  updateUI(snapshot);
};

ws.onerror = (error) => {
  console.error('WebSocket error:', error);
};

ws.onclose = () => {
  console.log('WebSocket closed, attempting reconnect...');
  setTimeout(connectWebSocket, 1000);
};
```

### 3. Snapshot Data Structure

The snapshot WebSocket sends complete machine state at regular intervals:

```json
{
  "timestamp": "2026-02-06T10:30:45.123Z",
  "state": {
    "state": "espresso",
    "substate": "pouring"
  },
  "flow": 2.5,
  "pressure": 9.1,
  "targetFlow": 2.5,
  "targetPressure": 9.0,
  "mixTemperature": 93.2,
  "groupTemperature": 93.0,
  "targetMixTemperature": 93.0,
  "targetGroupTemperature": 93.0,
  "profileFrame": 2,
  "steamTemperature": 135.5
}
```

---

## Core API Endpoints

### Device Management

#### Get Available Devices
```http
GET /api/v1/devices
```

Returns all discovered devices with their connection states.

**Response:**
```json
[
  {
    "name": "DE1",
    "id": "F4:12:FA:5C:3D:8E",
    "state": "connected",
    "type": "machine"
  },
  {
    "name": "Decent Scale",
    "id": "AA:BB:CC:DD:EE:FF",
    "state": "connected",
    "type": "scale"
  }
]
```

#### Scan for Devices
```http
GET /api/v1/devices/scan
```

Triggers a scan-first connection cycle. With the default `connect=true`, Decaid preserves connected devices and automatically fills only missing machine and scale slots. Preferred devices connect without prompting when found; missing preferred devices or multiple candidates produce machine-first, then scale ambiguity on `ws/v1/devices`. Set `connect=false` for discovery only. Use `quick=true` to return immediately without waiting for scan results.

#### Connect to Device
```http
PUT /api/v1/devices/connect?deviceId=F4:12:FA:5C:3D:8E
```

Connects to a specific device by ID.

---

### Machine Control

#### Get Machine Info
```http
GET /api/v1/machine/info
```

Returns machine hardware information.

**Response:**
```json
{
  "version": "1.5.0",
  "model": "DE1+",
  "serialNumber": "DE1XL-12345",
  "GHC": true,
  "extra": {}
}
```

#### Get Machine State
```http
GET /api/v1/machine/state
```

Returns current machine state snapshot.

**Response:**
```json
{
  "timestamp": "2026-02-06T10:30:45.123Z",
  "state": {
    "state": "idle",
    "substate": "idle"
  },
  "flow": 0.0,
  "pressure": 0.0,
  "targetFlow": 0.0,
  "targetPressure": 0.0,
  "mixTemperature": 92.5,
  "groupTemperature": 92.3,
  "targetMixTemperature": 93.0,
  "targetGroupTemperature": 93.0,
  "profileFrame": 0,
  "steamTemperature": 135.0
}
```

**Machine States:**
- `idle` - Machine ready
- `booting` - Starting up
- `sleeping` - Power saving mode
- `heating` - Warming up
- `preheating` - Preparing for shot
- `espresso` - Brewing espresso
- `hotWater` - Dispensing hot water
- `flush` - Flushing group
- `steam` - Steaming mode
- `steamRinse` - Cleaning steam wand
- `cleaning` - Cleaning cycle
- `descaling` - Descaling cycle
- `needsWater` - Water tank empty
- `error` - Error state

**Machine Substates:**
- `idle` - Idle
- `preparingForShot` - Pre-shot preparation
- `preinfusion` - Pre-infusion phase
- `pouring` - Extracting espresso
- `pouringDone` - Shot complete
- `cleaningStart` - Starting cleaning
- `cleaingGroup` - Cleaning group head
- `cleanSoaking` - Soaking during clean
- `cleaningSteam` - Steam cleaning

#### Request State Change
```http
PUT /api/v1/machine/state/{newState}
```

Request a machine state change. Valid states: `idle`, `sleeping`, `espresso`, `steam`, `hotWater`, `flush`.

**Example:**
```javascript
// Put machine into espresso mode
await fetch(`${GATEWAY_URL}/api/v1/machine/state/espresso`, {
  method: 'PUT'
});
```

#### Upload Profile to Machine
```http
POST /api/v1/machine/profile
Content-Type: application/json

{
  "version": "2",
  "title": "My Profile",
  "author": "MySkin",
  "notes": "Custom profile",
  "beverage_type": "espresso",
  "steps": [...],
  "target_volume": 0,
  "target_weight": 36,
  "tank_temperature": 0
}
```

Uploads a complete profile to the machine.

#### Update Shot Settings
```http
POST /api/v1/machine/shotSettings
Content-Type: application/json

{
  "steamSetting": 2,
  "targetSteamTemp": 140,
  "targetSteamDuration": 60,
  "targetHotWaterTemp": 95,
  "targetHotWaterVolume": 200,
  "targetHotWaterDuration": 30,
  "targetShotVolume": 36,
  "groupTemp": 93.0
}
```

#### Get Machine Settings
```http
GET /api/v1/machine/settings
```

**Response:**
```json
{
  "usb": false,
  "fan": 50,
  "flushTemp": 88,
  "flushFlow": 4.0,
  "flushTimeout": 5,
  "hotWaterFlow": 4.0,
  "steamFlow": 1.5,
  "tankTemp": 85
}
```

#### Update Machine Settings
```http
POST /api/v1/machine/settings
Content-Type: application/json

{
  "usb": true,
  "fan": 60,
  "tankTemp": 88
}
```

You can update individual settings - only include the fields you want to change.

#### Toggle USB Charger

The USB charger is toggled through the machine settings endpoint:

```http
POST /api/v1/machine/settings
Content-Type: application/json

{"usb": "enable"}
```

Set `"usb"` to `"enable"` to turn the charger on, or `"disable"` to turn it off.

The DE1 firmware re-enables the charger on its own, so the app re-applies the desired state periodically.

#### Update Water Level Threshold
```http
POST /api/v1/machine/waterLevels
Content-Type: application/json

{
  "warningThresholdPercentage": 20
}
```

---

### Scale Integration

#### Tare Scale
```http
PUT /api/v1/scale/tare
```

Zeros the connected scale.

**Response:** 200 OK if successful, 404 if scale not connected, 400 (`type: "block_tare_during_shot"`) if the `blockTareDuringShot` setting is enabled and an app-tracked espresso shot is actively brewing. Skins should surface this as a non-fatal notice rather than retrying — the block is intentional. **Full gateway mode is an explicit policy exemption**: the skin owns the shot there, so this 400 is never returned in that mode, regardless of any app-tracked shot state.

---

### Workflow Management

Workflows combine profiles, dose settings, coffee data, grinder settings, and all machine operation parameters (steam, hot water, rinse) into a complete brewing recipe. **This is the recommended API** for managing all brewing parameters in one cohesive operation.

#### Why Use Workflow API?

Instead of uploading profiles and updating settings separately:
- **Atomic updates**: All settings applied together as a complete recipe
- **Simpler code**: One API call instead of multiple endpoint calls
- **Consistency**: Settings are guaranteed to be uploaded to the machine as a complete set
- **Better organization**: Natural grouping of all brewing parameters

#### Get Current Workflow
```http
GET /api/v1/workflow
```

Retrieves the complete current workflow including profile, context (dose, grinder, coffee metadata), and all machine settings (steam, hot water, rinse).

**Response:**
```json
{
  "id": "workflow-uuid",
  "name": "Morning Espresso",
  "description": "My daily shot",
  "profile": {
    "version": "2",
    "title": "Classic Profile",
    "author": "Me",
    "notes": "Balanced extraction",
    "beverage_type": "espresso",
    "steps": [...],
    "target_volume": 0,
    "target_weight": 36,
    "tank_temperature": 0
  },
  "context": {
    "targetDoseWeight": 18.0,
    "targetYield": 36.0,
    "grinderId": "550e8400-...",
    "grinderModel": "Niche Zero",
    "grinderSetting": "2.5",
    "beanBatchId": "660e8400-...",
    "coffeeName": "Ethiopia Yirgacheffe",
    "coffeeRoaster": "Square Mile",
    "finalBeverageType": "espresso"
  },
  "steamSettings": {
    "targetTemperature": 150,
    "duration": 50,
    "flow": 0.8
  },
  "hotWaterData": {
    "targetTemperature": 75,
    "duration": 30,
    "volume": 50,
    "flow": 10.0
  },
  "rinseData": {
    "targetTemperature": 90,
    "duration": 10,
    "flow": 6.0
  }
}
```

> **Note:** The response also includes legacy fields (`doseData`, `grinderData`, `coffeeData`) for backward compatibility. New code should read from `context`.
```

#### Update Workflow
```http
PUT /api/v1/workflow
Content-Type: application/json
```

You can update the complete workflow or just specific fields. Any fields provided will be updated and automatically uploaded to the machine. Use `context` for dose, grinder, and coffee parameters.

**Complete Workflow Update:**
```json
{
  "name": "Evening Decaf",
  "description": "Gentle evening shot",
  "profile": {
    "version": "2",
    "title": "Gentle Profile",
    "steps": [...]
  },
  "context": {
    "targetDoseWeight": 18.5,
    "targetYield": 37.0,
    "grinderModel": "Niche Zero",
    "grinderSetting": "2.8",
    "coffeeName": "Colombia Decaf",
    "coffeeRoaster": "Local Roaster",
    "finalBeverageType": "espresso"
  },
  "steamSettings": {
    "targetTemperature": 155,
    "duration": 60,
    "flow": 0.9
  },
  "hotWaterData": {
    "targetTemperature": 80,
    "duration": 35,
    "volume": 60,
    "flow": 12.0
  },
  "rinseData": {
    "targetTemperature": 92,
    "duration": 12,
    "flow": 6.5
  }
}
```

**Partial Update Examples:**

Update dose and grinder via context:
```json
{
  "context": {
    "targetDoseWeight": 18.5,
    "targetYield": 37.0,
    "grinderModel": "Niche Zero",
    "grinderSetting": "2.8"
  }
}
```

Link to managed entities (grinder and bean batch):
```json
{
  "context": {
    "grinderId": "550e8400-...",
    "grinderModel": "Niche Zero",
    "grinderSetting": "5.2",
    "beanBatchId": "660e8400-...",
    "coffeeName": "Red Brick",
    "coffeeRoaster": "Square Mile"
  }
}
```

Update just steam settings:
```json
{
  "steamSettings": {
    "targetTemperature": 155,
    "duration": 60,
    "flow": 0.9
  }
}
```

Update just the profile:
```json
{
  "profile": {
    "version": "2",
    "title": "New Profile",
    "steps": [...]
  }
}
```

**Response:** Returns the complete updated workflow object.

#### Workflow Data Structure Reference

**WorkflowContext** (recommended — all fields nullable):
- `targetDoseWeight` (number): Input dose in grams (dry coffee)
- `targetYield` (number): Target output in grams (beverage)
- `grinderId` (string): ID of a managed Grinder entity (see Grinders API)
- `grinderModel` (string): Grinder model name (display string)
- `grinderSetting` (string): Current grinder setting
- `beanBatchId` (string): ID of a managed BeanBatch entity (see Beans API)
- `coffeeName` (string): Coffee bean name (display string)
- `coffeeRoaster` (string): Coffee roaster name (display string)
- `finalBeverageType` (string): Beverage classification (e.g., "espresso", "filter")
- `baristaName` (string): Person pulling the shot
- `drinkerName` (string): Person drinking
- `extras` (object): Arbitrary key-value pairs for custom data

> **Backward compatibility:** Legacy fields `doseData`, `grinderData`, and `coffeeData` are still accepted for writes. When `context` is not provided, the system backfills it from legacy fields automatically.

**SteamSettings:**
- `targetTemperature` (integer): Target steam temperature in Celsius
- `duration` (integer): Steam duration in seconds
- `flow` (number): Steam flow rate

Steam-heater enablement is encoded through `targetTemperature` alone. Set it to `0` to disable steam-heater preheating; Decaid writes `0` °C to the machine when steam is disabled and treats temperatures below the supported range as disabled. Supported enabled ranges are 135–160 °C for DE1 and 135–165 °C for Bengle. `duration` controls the maximum duration of a steaming operation and does not control steam-heater preheating.

**HotWaterData:**
- `targetTemperature` (integer): Target hot water temperature in Celsius
- `duration` (integer): Hot water dispensing duration in seconds
- `volume` (integer): Target hot water volume in milliliters
- `flow` (number): Hot water flow rate

**RinseData:**
- `targetTemperature` (integer): Target rinse water temperature in Celsius
- `duration` (integer): Rinse duration in seconds
- `flow` (number): Rinse flow rate

---

### Shot History

#### List Shots (Paginated)
```http
GET /api/v1/shots?limit=20&offset=0
```

Returns a paginated list of shots. Measurements are **excluded** from the list response for performance — use `GET /api/v1/shots/{id}` to get full data including measurements.

**Query Parameters:**
- `limit` (integer, default 20): Page size (1-100)
- `offset` (integer, default 0): Number of shots to skip

**Filter Parameters** (all optional):
- `grinderId`: Filter by grinder entity ID
- `grinderModel`: Filter by grinder model name
- `beanBatchId`: Filter by bean batch entity ID
- `coffeeName`: Filter by coffee name
- `coffeeRoaster`: Filter by coffee roaster
- `profileTitle`: Filter by profile title

**Examples:**
```http
GET /api/v1/shots?limit=10&coffeeRoaster=Square%20Mile
GET /api/v1/shots?limit=5&grinderId=550e8400-...
GET /api/v1/shots?limit=20&offset=40&profileTitle=Blooming
```

**Response:**
```json
{
  "items": [
    {
      "id": "shot-2026-02-06-103045",
      "timestamp": "2026-02-06T10:30:45Z",
      "workflow": {
        "name": "Morning Shot",
        "context": {
          "targetDoseWeight": 18.0,
          "targetYield": 36.0,
          "coffeeName": "Red Brick",
          "coffeeRoaster": "Square Mile"
        }
      }
    }
  ],
  "total": 142,
  "limit": 20,
  "offset": 0
}
```

#### Get All Shot IDs
```http
GET /api/v1/shots/ids?order=desc
```

Returns array of all shot identifiers. Useful for lightweight syncing.

**Response:**
```json
[
  "shot-2026-02-06-103045",
  "shot-2026-02-06-094521",
  "shot-2026-02-05-173042"
]
```

#### Get Latest Shot
```http
GET /api/v1/shots/latest
```

Returns the most recent shot record without measurements. Use `GET /api/v1/shots/{id}` for the full record.

#### Get Specific Shot
```http
GET /api/v1/shots/{id}
```

Returns a single shot record by ID, **including full measurements**.

**Response:**
```json
{
  "id": "shot-2026-02-06-103045",
  "timestamp": "2026-02-06T10:30:45Z",
  "measurements": [
    {
      "machine": {
        "timestamp": "2026-02-06T10:30:45.100Z",
        "state": { "state": "espresso", "substate": "pouring" },
        "flow": 2.5,
        "pressure": 9.1,
        "mixTemperature": 93.2
      },
      "scale": {
        "timestamp": "2026-02-06T10:30:45.100Z",
        "weight": 18.5,
        "weightFlow": 2.1,
        "batteryLevel": 85
      },
      "volume": 15.3
    }
  ],
  "workflow": {
    "name": "Morning Shot",
    "context": {
      "targetDoseWeight": 18.0,
      "targetYield": 36.0,
      "grinderModel": "Niche Zero",
      "grinderSetting": "2.5",
      "coffeeName": "Red Brick",
      "coffeeRoaster": "Square Mile"
    }
  },
  "annotations": {
    "actualDoseWeight": 18.0,
    "actualYield": 36.2,
    "enjoyment": 4.5,
    "espressoNotes": "Excellent extraction!",
    "extras": { "tags": ["morning", "sweet"] }
  }
}
```

#### Update Shot
```http
PUT /api/v1/shots/{id}
Content-Type: application/json

{
  "annotations": {
    "enjoyment": 4.5,
    "espressoNotes": "Excellent extraction! Bright acidity with chocolate notes.",
    "extras": {
      "tags": ["morning", "sweet"],
      "favorite": true
    }
  }
}
```

Supports partial updates via deep merge — only include the fields you want to change. Use `annotations` for post-shot data:
- `actualDoseWeight`: Actual coffee dose in grams
- `actualYield`: Actual beverage yield in grams
- `drinkTds`: Measured total dissolved solids percentage
- `drinkEy`: Calculated extraction yield percentage
- `enjoyment`: Numeric rating
- `espressoNotes`: Tasting notes and observations
- `extras`: Flexible dictionary for tags, flags, plugin data, or other custom fields

`shotNotes` and `metadata` are deprecated compatibility fields for older clients, but remain accepted in PUT requests and map to `annotations.espressoNotes` and `annotations.extras`. If a request supplies both forms, the canonical annotation field wins, including when it is explicitly `null`. Setting either canonical field or its legacy alias to `null` clears that value. Setting `annotations` itself to `null` clears all post-shot annotations and ignores legacy values in the same request.

In responses, `shotNotes` and `metadata` mirror their canonical annotation values. Cleared canonical values never leave stale legacy aliases. New integrations should read and update `annotations` directly.

**Response:** Returns the updated shot record.

#### Delete Shot
```http
DELETE /api/v1/shots/{id}
```

Permanently deletes a shot record.

**Response:**
```json
{
  "success": true,
  "id": "shot-2026-02-06-103045"
}
```

---

### Coffee Beans, Grinders & Workflows

Decaid manages coffee beans, bean batches, and grinders as first-class entities that can be linked to workflows and shot records.

#### How It Fits Together

```
┌──────────────┐     ┌──────────────┐
│   Bean       │     │   Grinder    │
│ (origin,     │     │ (model,      │
│  roaster)    │     │  burrs,      │
│              │     │  settings)   │
└──────┬───────┘     └──────┬───────┘
       │ has many           │
       ▼                    │
┌──────────────┐            │
│  BeanBatch   │            │
│ (roast date, │            │
│  weight,     │            │
│  price)      │            │
└──────┬───────┘            │
       │                    │
       ▼ beanBatchId        ▼ grinderId
┌─────────────────────────────────────┐
│         WorkflowContext             │
│  (links entities + display strings  │
│   + dose targets + people)          │
└──────────────────┬──────────────────┘
                   │
                   ▼ saved with each shot
            ┌──────────────┐
            │  ShotRecord  │
            └──────────────┘
```

- **Bean** represents a coffee origin (roaster + name + metadata). A bean can have multiple **BeanBatches** — each batch tracks a specific purchase with roast date, weight remaining, price, and frozen state.
- **Grinder** represents grinder equipment with its burr info and setting type (numeric dial or named presets).
- **WorkflowContext** ties everything together in a workflow. Set `grinderId` and `beanBatchId` to link to managed entities. Also include display strings (`grinderModel`, `coffeeName`, etc.) so UIs can show the info without extra lookups.
- When a shot is pulled, the current workflow context is saved with the shot record, creating a permanent record of which beans, grinder, and settings were used.

#### Typical Workflow

1. Create a grinder: `POST /api/v1/grinders`
2. Create a bean: `POST /api/v1/beans`
3. Add a batch to the bean: `POST /api/v1/beans/{beanId}/batches`
4. Set up the workflow with entity IDs:
   ```json
   PUT /api/v1/workflow
   {
     "context": {
       "targetDoseWeight": 18.0,
       "targetYield": 36.0,
       "grinderId": "<grinder-uuid>",
       "grinderModel": "Niche Zero",
       "grinderSetting": "15",
       "beanBatchId": "<batch-uuid>",
       "coffeeName": "Red Brick",
       "coffeeRoaster": "Square Mile"
     }
   }
   ```
5. Pull a shot — the context is saved with the shot record
6. Later, filter shot history: `GET /api/v1/shots?coffeeRoaster=Square%20Mile`

---

### Beans API

Manage coffee beans and their batches (purchases/roasts).

#### List Beans
```http
GET /api/v1/beans?includeArchived=false
```

**Response:**
```json
[
  {
    "id": "550e8400-...",
    "roaster": "Square Mile",
    "name": "Red Brick",
    "country": "Brazil",
    "processing": "natural",
    "variety": ["Yellow Bourbon"],
    "archived": false,
    "createdAt": "2026-02-15T12:00:00Z",
    "updatedAt": "2026-02-15T12:00:00Z"
  }
]
```

#### Create Bean
```http
POST /api/v1/beans
Content-Type: application/json

{
  "roaster": "Square Mile",
  "name": "Red Brick",
  "country": "Brazil",
  "processing": "natural",
  "variety": ["Yellow Bourbon"],
  "altitude": [1100, 1300]
}
```

Only `roaster` and `name` are required. **Response:** 201 Created with the full bean object.

#### Get, Update, Delete Bean
```http
GET /api/v1/beans/{id}
PUT /api/v1/beans/{id}       # partial update — only include fields to change
DELETE /api/v1/beans/{id}    # permanently deletes bean and all its batches
```

#### List Batches for a Bean
```http
GET /api/v1/beans/{beanId}/batches?includeArchived=false
```

Returns all batches for the bean. A batch represents a specific purchase or roast — use it to track roast dates, weight consumption, and pricing.

#### Create Batch
```http
POST /api/v1/beans/{beanId}/batches
Content-Type: application/json

{
  "roastDate": "2026-02-28T00:00:00Z",
  "roastLevel": "medium-light",
  "weight": 250,
  "price": 18.50,
  "currency": "EUR"
}
```

All fields are optional. When `weight` is provided, `weightRemaining` is auto-initialized to the same value.

**Key batch use cases:**
- **Freshness tracking:** Use `roastDate` and `openDate` to calculate days since roast
- **Inventory:** Track `weight` / `weightRemaining` as you use the coffee
- **Cost:** Record `price` and `currency` per batch
- **Freezing:** Set `frozen: true` when you freeze a batch for later use

**Response:** 201 Created with the full batch object.

#### Get, Update, Delete Batch
```http
GET /api/v1/bean-batches/{id}
PUT /api/v1/bean-batches/{id}       # partial update
DELETE /api/v1/bean-batches/{id}
```

---

### Grinders API

Manage grinder equipment. Supports two setting types: **numeric** (continuous dial) and **preset** (named positions).

#### List Grinders
```http
GET /api/v1/grinders?includeArchived=false
```

**Response:**
```json
[
  {
    "id": "770e8400-...",
    "model": "Niche Zero",
    "burrs": "Stock 63mm",
    "burrSize": 63.0,
    "burrType": "conical",
    "settingType": "numeric",
    "settingSmallStep": 0.5,
    "settingBigStep": 5.0,
    "archived": false,
    "createdAt": "2026-02-15T12:00:00Z",
    "updatedAt": "2026-02-15T12:00:00Z"
  }
]
```

#### Create Grinder
```http
POST /api/v1/grinders
Content-Type: application/json

{
  "model": "Niche Zero",
  "burrs": "Stock 63mm",
  "burrSize": 63.0,
  "burrType": "conical",
  "settingType": "numeric",
  "settingSmallStep": 0.5,
  "settingBigStep": 5.0
}
```

Only `model` is required.

**Setting types:**
- `numeric` (default): Continuous dial — use `settingSmallStep` / `settingBigStep` for increment hints
- `preset`: Named positions — provide `settingValues` array (e.g., `["Fine", "Medium", "Coarse"]`)

**Response:** 201 Created with the full grinder object.

#### Get, Update, Delete Grinder
```http
GET /api/v1/grinders/{id}
PUT /api/v1/grinders/{id}       # partial update
DELETE /api/v1/grinders/{id}
```

---

### Profiles API

Decaid uses content-based hashing for profile IDs. Profile IDs are calculated from execution-relevant fields, meaning identical profiles have the same ID across all devices.

#### List All Profiles
```http
GET /api/v1/profiles?visibility=visible&includeHidden=false
```

**Query parameters:**
- `visibility`: Filter by `visible`, `hidden`, or `deleted`
- `includeHidden`: Include hidden profiles (default: false)
- `parentId`: Filter profiles by parent ID (version tracking)

**Response:**
```json
[
  {
    "id": "profile:a1b2c3d4e5f6g7h8",
    "profile": {
      "version": "2",
      "title": "Classic Blooming",
      "author": "Decent",
      "notes": "Gentle pre-infusion profile",
      "beverage_type": "espresso",
      "steps": [...],
      "target_volume": 0,
      "target_weight": 36,
      "tank_temperature": 0
    },
    "metadataHash": "3f4e5d6c7b8a9...",
    "compoundHash": "9a8b7c6d5e4f3...",
    "parentId": null,
    "visibility": "visible",
    "isDefault": true,
    "createdAt": "2026-01-15T12:00:00Z",
    "updatedAt": "2026-01-15T12:00:00Z",
    "metadata": {}
  }
]
```

#### Get Profile by ID
```http
GET /api/v1/profiles/{id}
```

Returns a single profile record.

#### Create New Profile
```http
POST /api/v1/profiles
Content-Type: application/json

{
  "profile": {
    "version": "2",
    "title": "My Custom Profile",
    "author": "Me",
    "notes": "Testing new recipe",
    "beverage_type": "espresso",
    "steps": [...],
    "target_volume": 0,
    "target_weight": 36,
    "tank_temperature": 0
  },
  "parentId": null,
  "metadata": {
    "tags": ["experimental"]
  }
}
```

**Response:** 201 Created with full profile record including auto-generated ID.

#### Update Profile
```http
PUT /api/v1/profiles/{id}
Content-Type: application/json

{
  "profile": {
    "version": "2",
    "title": "Updated Title",
    ...
  },
  "metadata": {
    "tags": ["updated"]
  }
}
```

**Note:** Cannot modify default profiles' content, only metadata.

#### Delete Profile (Soft Delete)
```http
DELETE /api/v1/profiles/{id}
```

Soft deletes user profiles or hides default profiles.

#### Change Profile Visibility
```http
PUT /api/v1/profiles/{id}/visibility
Content-Type: application/json

{
  "visibility": "hidden"
}
```

Valid values: `visible`, `hidden`, `deleted`

#### Get Profile Lineage
```http
GET /api/v1/profiles/{id}/lineage
```

Returns the full version history tree (parents and children) for a profile.

#### Permanently Delete Profile
```http
DELETE /api/v1/profiles/{id}/purge
```

**Warning:** Permanently removes profile. Cannot purge default profiles. Use with caution.

#### Export All Profiles
```http
GET /api/v1/profiles/export?includeHidden=false&includeDeleted=false
```

Exports all profiles as JSON array for backup purposes.

#### Import Profiles
```http
POST /api/v1/profiles/import
Content-Type: application/json

[
  { "id": "profile:...", "profile": {...}, ... },
  { "id": "profile:...", "profile": {...}, ... }
]
```

Batch import profiles from backup.

**Response:**
```json
{
  "imported": 5,
  "skipped": 2,
  "failed": 0,
  "errors": []
}
```

#### Restore Default Profile
```http
POST /api/v1/profiles/restore/{filename}
```

Restores a bundled default profile from assets by filename.

---

### Sensors API

Decaid supports extensible sensor devices that can provide custom data streams.

#### List Connected Sensors
```http
GET /api/v1/sensors
```

**Response:**
```json
[
  {
    "name": "Basket Sensor",
    "info": {
      "id": "sensor:basket:001",
      "name": "Acme Basket Sensor",
      "vendor": "Acme",
      "dataChannels": [
        {
          "key": "temperature",
          "type": "number",
          "unit": "°C"
        }
      ],
      "commands": []
    }
  }
]
```

#### Get Sensor Manifest
```http
GET /api/v1/sensors/{id}
```

Returns full manifest for a specific sensor, including available commands.

#### Execute Sensor Command
```http
POST /api/v1/sensors/{id}/execute
Content-Type: application/json

{
  "commandId": "calibrate",
  "params": {
    "mode": "quick"
  }
}
```

**Response:**
```json
{
  "timestamp": "2026-02-06T10:30:45Z",
  "result": {
    "success": true,
    "message": "Calibration complete"
  }
}
```

---

### REA Settings

Configure Decaid gateway behavior.

#### Get REA Settings
```http
GET /api/v1/settings
```

**Response:**
```json
{
  "gatewayMode": "full",
  "webUiPath": "/path/to/webui",
  "logLevel": "INFO",
  "weightFlowMultiplier": 1.0,
  "volumeFlowMultiplier": 0.3,
  "hotWaterFlowMultiplier": 0.3,
  "scalePowerMode": "disabled",
  "blockOnNoScale": false,
  "blockTareDuringShot": false,
  "stopHotWaterAtWeight": true,
  "preferredMachineId": "F4:12:FA:5C:3D:8E"
}
```

**Settings Fields:**
- `gatewayMode`: Gateway operation mode (`disabled`, `full`, `tracking`)
- `webUiPath`: Path to custom WebUI folder on filesystem
- `logLevel`: Log verbosity level
- `weightFlowMultiplier`: Multiplier for projected weight calculation (default: 1.0)
- `volumeFlowMultiplier`: Multiplier for projected volume calculation (default: 0.3)
- `hotWaterFlowMultiplier`: Look-ahead seconds for projected weight when stopping hot water at weight (default: 0.3). Separate from `weightFlowMultiplier` because hot water dispenses with a different pump/flow profile
- `scalePowerMode`: Automatic scale power management (`disabled`, `displayOff`, `disconnect`)
- `blockOnNoScale`: When true, shots are blocked from starting if no scale is connected (default: false)
- `blockTareDuringShot`: When true, `PUT /api/v1/scale/tare` is rejected (400, `type: "block_tare_during_shot"`) while an app-tracked espresso shot is actively brewing, so a stray programmatic tare can't wreck stop-at-weight mid-pour (default: false). Manual tare via the scale's physical button is unaffected. `full` gateway mode is an explicit policy exemption — the skin owns the shot there, so the lockout never engages in that mode, regardless of any app-tracked shot state.
- `stopHotWaterAtWeight`: When true and a scale is connected, hot water dispensing tares the scale and stops at the configured hot-water volume target treated as grams (default: true). Ignored in full gateway mode
- `preferredMachineId`: Device ID for auto-connect on startup
- `lowBatteryBrightnessLimit` (boolean): When enabled, caps brightness at 20 when battery drops below 30%

**Gateway Modes:**
- `disabled`: No gateway features
- `full`: Full gateway mode with UI
- `tracking`: Control shots (stop at weight) but no UI graphs

**Scale Power Modes:**
- `disabled`: No automatic power management
- `displayOff`: Turn off scale display when machine sleeps
- `disconnect`: Disconnect scale when machine sleeps

#### Update Decaid Settings
```http
POST /api/v1/settings
Content-Type: application/json

{
  "gatewayMode": "full",
  "logLevel": "WARNING",
  "preferredMachineId": "F4:12:FA:5C:3D:8E"
}
```

Only include fields you want to update. Changes take effect immediately.

---

### Key-Value Store

Decaid provides a simple key-value store for client applications to persist data.

#### List Keys in Namespace
```http
GET /api/v1/store/{namespace}
```

**Response:**
```json
["config", "preferences", "lastShot"]
```

#### Get Value
```http
GET /api/v1/store/{namespace}/{key}
```

Returns the JSON value stored under the key. Returns 404 if key doesn't exist.

#### Set Value
```http
POST /api/v1/store/{namespace}/{key}
Content-Type: application/json

{
  "setting1": "value1",
  "setting2": 42
}
```

Stores any JSON value under the key.

#### Delete Key
```http
DELETE /api/v1/store/{namespace}/{key}
```

**Response:**
```json
{
  "deleted": true
}
```

---

### Plugins API

Query loaded plugins and their settings.

#### List Loaded Plugins
```http
GET /api/v1/plugins
```

**Response:**
```json
[
  {
    "id": "example-plugin",
    "name": "Example Plugin",
    "author": "Decent",
    "description": "Example plugin for testing",
    "version": "1.0.0",
    "apiVersion": "1.0",
    "permissions": ["log", "emit"],
    "settings": {
      "enabled": { "type": "boolean", "default": true }
    },
    "api": [
      {
        "id": "customEvent",
        "type": "websocket"
      }
    ]
  }
]
```

#### Get Plugin Settings
```http
GET /api/v1/plugins/{id}/settings
```

Returns current settings for the plugin.

#### Update Plugin Settings
```http
POST /api/v1/plugins/{id}/settings
Content-Type: application/json

{
  "enabled": true,
  "customSetting": "value"
}
```

---

### Display Control

Control the tablet's screen brightness and wake-lock (keep-screen-on) behavior. Useful for skins that want to adjust brightness during idle periods or prevent the screen from turning off during active use.

#### Get Display State
```http
GET /api/v1/display
```

**Response:**
```json
{
  "wakeLockEnabled": true,
  "wakeLockOverride": false,
  "brightness": 75,
  "requestedBrightness": 75,
  "lowBatteryBrightnessActive": false,
  "platformSupported": {
    "brightness": true,
    "wakeLock": true
  }
}
```

**Fields:**
- `wakeLockEnabled` (boolean): Whether the screen is currently prevented from turning off
- `wakeLockOverride` (boolean): Whether a skin has manually requested wake-lock (overrides auto-management)
- `brightness` (integer, 0-100): Actual applied screen brightness. May differ from `requestedBrightness` if the low battery brightness cap is active.
- `requestedBrightness` (integer, 0-100): The brightness level that was requested by the skin. If no battery cap is active, this equals `brightness`.
- `lowBatteryBrightnessActive` (boolean): Whether the low battery brightness cap is currently limiting brightness (battery < 30% and setting enabled).
- `platformSupported.brightness` (boolean): Whether brightness control is available on this platform
- `platformSupported.wakeLock` (boolean): Whether wake-lock control is available on this platform

#### Set Brightness
```http
PUT /api/v1/display/brightness
Content-Type: application/json

{"brightness": 75}
```

Sets the screen brightness to a value between 0 and 100. Setting brightness to 100 returns to OS-managed brightness (respects auto-brightness settings on the device). Values 0-99 set an explicit brightness level.

Returns 400 if `brightness` is missing or outside the 0-100 range.

**Response:** Updated `DisplayState` JSON (same format as GET).

**Note:** If the low battery brightness limit setting is enabled and battery is below 30%, the actual applied brightness will be capped at 20 regardless of the requested value. The response will show the capped value in `brightness` and the original request in `requestedBrightness`.

#### Request Wake-Lock Override
```http
POST /api/v1/display/wakelock
```

Forces the screen to stay on regardless of machine state. Normally, wake-lock is auto-managed (on when machine is connected and awake, off when sleeping). This endpoint overrides that behavior.

**Response:** Updated `DisplayState` JSON.

#### Release Wake-Lock Override
```http
DELETE /api/v1/display/wakelock
```

Returns to auto-managed wake-lock behavior based on machine state.

**Response:** Updated `DisplayState` JSON.

**Wake-Lock Auto-Management:**
- When no override is active, wake-lock is automatically enabled when the machine is connected and not sleeping, and disabled when the machine sleeps or disconnects.
- Brightness is automatically restored to its pre-sleep value when the machine transitions from sleeping to idle.

**Low Battery Brightness Cap:**
- When the `lowBatteryBrightnessLimit` setting is enabled (via `POST /api/v1/settings`) and battery drops below 30%, screen brightness is capped at 20.
- When battery recovers above 30%, brightness is restored to the requested value.
- Battery level is polled every 60 seconds, so there may be up to a 60-second delay between charging state changes and brightness cap activation/deactivation.
- This feature is only available on platforms with battery monitoring (Android/iOS).

---

### Presence & Sleep Management

Manage user presence detection and scheduled wake times. Presence tracking lets the machine auto-sleep after a configurable timeout, and wake schedules let users pre-program the machine to warm up at specific times.

#### Signal User Presence (Heartbeat)
```http
POST /api/v1/machine/heartbeat
```

Call this endpoint periodically (e.g., on user interaction) to signal that a user is actively using the skin. This resets the auto-sleep timer.

**Response:**
```json
{
  "timeout": 1800
}
```

- `timeout` (number): Seconds remaining before auto-sleep, or `-1` if presence tracking is disabled or no machine is connected.

**Notes:**
- Heartbeats are throttled to the DE1 machine (minimum 30-second interval between actual commands), but the endpoint always responds immediately.
- Requires `userPresenceEnabled: true` in presence settings and a connected DE1.

#### Get Presence Settings
```http
GET /api/v1/presence/settings
```

**Response:**
```json
{
  "userPresenceEnabled": true,
  "sleepTimeoutMinutes": 30,
  "schedules": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "time": "06:30",
      "daysOfWeek": [1, 2, 3, 4, 5],
      "enabled": true
    }
  ]
}
```

#### Update Presence Settings
```http
POST /api/v1/presence/settings
Content-Type: application/json

{
  "userPresenceEnabled": true,
  "sleepTimeoutMinutes": 45
}
```

Supports partial updates — only include the fields you want to change.

**Response:** Updated settings (without schedules).

#### List Wake Schedules
```http
GET /api/v1/presence/schedules
```

**Response:**
```json
[
  {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "time": "06:30",
    "daysOfWeek": [1, 2, 3, 4, 5],
    "enabled": true
  }
]
```

#### Create Wake Schedule
```http
POST /api/v1/presence/schedules
Content-Type: application/json

{
  "time": "06:30",
  "daysOfWeek": [1, 2, 3, 4, 5],
  "enabled": true
}
```

Alternatively, you can specify time as separate fields:
```json
{
  "hour": 6,
  "minute": 30,
  "daysOfWeek": [1, 2, 3, 4, 5]
}
```

**Schedule Fields:**
- `time` (string): Time in 24-hour `"HH:MM"` format (e.g., `"06:30"`, `"14:00"`)
- `hour` / `minute` (integers): Alternative to `time` — specify hour and minute separately
- `daysOfWeek` (array of integers): ISO 8601 weekday numbers — 1=Monday through 7=Sunday. Empty array `[]` means every day.
- `enabled` (boolean): Defaults to `true` if omitted

**Response:** 201 Created with the new schedule including its generated `id`.

#### Update Wake Schedule
```http
PUT /api/v1/presence/schedules/{id}
Content-Type: application/json

{
  "time": "07:00",
  "daysOfWeek": [6, 7],
  "enabled": true
}
```

Supports partial updates. Returns 404 if the schedule ID doesn't exist.

**Response:** Updated schedule object.

#### Delete Wake Schedule
```http
DELETE /api/v1/presence/schedules/{id}
```

**Response:**
```json
{
  "deleted": "550e8400-e29b-41d4-a716-446655440000"
}
```

Returns 404 if the schedule ID doesn't exist.

### Build Info

Retrieve build-time metadata about the running Decaid instance. Useful for skins that want to display version information or check compatibility.

#### Get Build Info
```http
GET /api/v1/info
```

**Response:**
```json
{
  "commit": "a1b2c3d4e5f6...",
  "commitShort": "a1b2c3d",
  "branch": "main",
  "buildTime": "2026-03-22T10:30:00Z",
  "version": "1.2.3",
  "buildNumber": "456",
  "appStore": false,
  "fullVersion": "1.2.3+456"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `commit` | string | Full git commit SHA |
| `commitShort` | string | Short (7-char) git commit SHA |
| `branch` | string | Git branch name at build time |
| `buildTime` | string | ISO 8601 build timestamp |
| `version` | string | Semantic version (e.g. `1.2.3`) |
| `buildNumber` | string | Incremental build number |
| `appStore` | boolean | Whether this is an App Store (iOS) build |
| `fullVersion` | string | Version with build number (e.g. `1.2.3+456`) |

> **Note:** In debug/development builds, git-based fields (`commit`, `commitShort`, `branch`, `buildTime`) will return `"unknown"`.

---

## WebSocket Endpoints

All WebSocket endpoints are at `ws://<gateway-ip>:8080/ws/v1/...`

### 1. Machine Snapshot Stream

**Endpoint:** `ws/v1/machine/snapshot`

**Update Frequency:** ~10 Hz (100ms intervals)

**Purpose:** Primary real-time data feed for UI updates

**Message Format:**
```json
{
  "timestamp": "2026-02-06T10:30:45.123Z",
  "state": {
    "state": "espresso",
    "substate": "pouring"
  },
  "flow": 2.5,
  "pressure": 9.1,
  "targetFlow": 2.5,
  "targetPressure": 9.0,
  "mixTemperature": 93.2,
  "groupTemperature": 93.0,
  "targetMixTemperature": 93.0,
  "targetGroupTemperature": 93.0,
  "profileFrame": 2,
  "steamTemperature": 135.5
}
```

**Example:**
```javascript
const ws = new WebSocket('ws://192.168.1.100:8080/ws/v1/machine/snapshot');

ws.onmessage = (event) => {
  const snapshot = JSON.parse(event.data);
  
  // Update temperature displays
  document.getElementById('steam-temp').textContent = 
    snapshot.steamTemperature.toFixed(1);
  
  // Update pressure gauge
  updatePressureGauge(snapshot.pressure);
  
  // Update shot timer if brewing
  if (snapshot.state.state === 'espresso' && snapshot.state.substate === 'pouring') {
    updateShotTimer();
  }
};
```

### 2. Scale Snapshot Stream

**Endpoint:** `ws/v1/scale/snapshot`

**Update Frequency:** Variable (based on scale model, typically 5-10 Hz)

**Connection lifecycle:** The socket is held open across scale
connect/disconnect cycles. Do not reconnect the WebSocket when the scale
disconnects — the server will resume streaming automatically once a scale
connects. On open and on every scale connection-state transition the
server emits a status frame:

```json
{ "status": "connected" }
```
```json
{ "status": "disconnected" }
```

**Snapshot message format** (sent only while a scale is connected):
```json
{
  "timestamp": "2026-02-06T10:30:45.123Z",
  "weight": 18.5,
  "batteryLevel": 85
}
```

Client code should branch on the presence of a `status` field vs. a
`weight` field.

### Machine Telemetry Socket Lifecycle

All machine telemetry sockets (`/ws/v1/machine/snapshot`,
`/ws/v1/machine/shotSettings`, `/ws/v1/machine/waterLevels`,
`/ws/v1/machine/raw`) share the same lifecycle:

- **Sockets stay open across machine power cycles and reconnects.** When the
  machine disconnects (e.g. power-cycle, USB re-enumeration, BLE drop) the
  server detaches the socket from the old machine object. While no machine is
  connected the socket stops emitting frames but stays open.
- **Frames resume automatically.** When a new machine instance connects, the
  server re-attaches the socket and frames resume with no client-side action.
  Clients do not need to reconnect the socket on machine disconnect.
- **No connection-status frames are emitted.** Unlike the scale socket, each
  machine socket carries a single typed payload per frame. Adding a status
  frame would break existing parsers. Use `/ws/v1/devices` for machine
  connection state.
- **A telemetry gap alone does not prove the WebSocket connection is dead.**
  If your client needs a liveness signal, subscribe to `/ws/v1/devices` which
  reports machine link state independently of any socket lifecycle.
- **Reconnection is not required for a normal machine instance swap.** However,
  clients may still retain normal WebSocket reconnect logic for actual socket
  closure or network failure (e.g. a liveness timeout is a valid defensive
  fallback).

**Raw endpoint behavior during disconnected interval:**
`/ws/v1/machine/raw` is bidirectional — the server streams outbound data
and accepts inbound commands. If a command is sent while no machine is
connected, the server replies with `{"error": "No machine connected"}`
rather than silently dropping it. The socket stays open and resumes normal
operation when a machine reconnects. Raw commands are not queued for later
delivery.

### 3. Shot Settings Stream

**Endpoint:** `ws/v1/machine/shotSettings`

**Purpose:** Real-time updates when shot settings change

**Message Format:**
```json
{
  "steamSetting": 2,
  "targetSteamTemp": 140,
  "targetSteamDuration": 60,
  "targetHotWaterTemp": 95,
  "targetHotWaterVolume": 200,
  "targetHotWaterDuration": 30,
  "targetShotVolume": 36,
  "groupTemp": 93.0
}
```

### 4. Water Levels Stream

**Endpoint:** `ws/v1/machine/waterLevels`

**Purpose:** Real-time water level updates

**Message Format:**
```json
{
  "currentLevel": 45,
  "refillLevel": 10
}
```

### 5. Machine Raw BLE Data

**Endpoint:** `ws/v1/machine/raw`

**Purpose:** Raw BLE messages for debugging and advanced integrations

**Message Format:**
```json
{
  "type": "response",
  "operation": "notify",
  "characteristicUUID": "a00e",
  "payload": "0102030405060708"
}
```

**Types:** `request`, `response`  
**Operations:** `read`, `write`, `notify`

### 6. Sensor Snapshot Stream

**Endpoint:** `ws/v1/sensors/{id}/snapshot`

**Purpose:** Real-time sensor data for specific sensor

**Message Format:**
```json
{
  "timestamp": "2026-02-06T10:30:45.123Z",
  "id": "sensor:basket:001",
  "values": {
    "temperature": 92.5,
    "pressure": 9.1
  }
}
```

### 7. Plugin Event Streams

**Endpoint:** `ws/v1/plugins/{pluginId}/{endpoint}`

**Purpose:** Custom events emitted by plugins

**Message Format:** Defined by plugin (any JSON)

**Example:**
```javascript
const pluginWs = new WebSocket('ws://192.168.1.100:8080/ws/v1/plugins/custom-logger/shotComplete');

pluginWs.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('Plugin event:', data);
};
```

### 8. Logs Stream

**Endpoint:** `ws/v1/logs`

**Purpose:** Subscribe to REA log messages

**Message Format:**
```json
{
  "timestamp": "2026-02-06T10:30:45.123Z",
  "level": "INFO",
  "message": "Machine state changed to espresso"
}
```

### 9. Display State Stream

**Endpoint:** `ws/v1/display`

**Purpose:** Real-time display state updates with bidirectional command support. Preferred over polling `GET /api/v1/display` for reactive UIs.

**Outgoing Messages (server → client):**

Sent whenever display state changes (brightness, wake-lock):

```json
{
  "wakeLockEnabled": true,
  "wakeLockOverride": false,
  "brightness": 75,
  "requestedBrightness": 75,
  "lowBatteryBrightnessActive": false,
  "platformSupported": {
    "brightness": true,
    "wakeLock": true
  }
}
```

**Incoming Commands (client → server):**

Send JSON commands to control the display:

```json
{"command": "setBrightness", "brightness": 75}
{"command": "requestWakeLock"}
{"command": "releaseWakeLock"}
```

**Auto-Cleanup:** If a client sends `requestWakeLock`, the wake-lock override is automatically released when the WebSocket connection closes. This prevents orphaned wake-locks if a skin disconnects unexpectedly.

**Example:**
```javascript
const displayWs = new WebSocket('ws://192.168.1.100:8080/ws/v1/display');

displayWs.onopen = () => {
  // Keep screen on while skin is active
  displayWs.send(JSON.stringify({ command: 'requestWakeLock' }));
  // Set brightness to 80%
  displayWs.send(JSON.stringify({ command: 'setBrightness', brightness: 80 }));
};

displayWs.onmessage = (event) => {
  const state = JSON.parse(event.data);
  console.log('Brightness:', state.brightness);
  console.log('Requested:', state.requestedBrightness);
  console.log('Battery-capped:', state.lowBatteryBrightnessActive);

  // Adapt UI based on platform support
  if (!state.platformSupported.brightness) {
    hideBrightnessControls();
  }
};

// Wake-lock is automatically released when this WebSocket closes
```

### 10. Devices Stream & Connection Errors

**Endpoint:** `ws/v1/devices`

**Purpose:** Broadcasts the full `ConnectionManager` status (discovered devices, current phase, pending ambiguity, and the most recent BLE error) plus a snapshot of all known devices. Also accepts `scan`, `connect`, and `disconnect` commands — see [`assets/api/websocket_v1.yml`](../assets/api/websocket_v1.yml) for the command schema.

Each `connect` command receives a `DeviceConnectResult` after the attempt finishes. Use its `outcome` and `state` instead of inferring command success from later status updates. Failed sensor commands use `sensorConnectFailed` in the result's `connectionError`.

#### Handling connection errors

When a BLE operation fails, the stream emits an update with a structured `connectionStatus.error` object. The socket stays open across errors — do not reconnect the WebSocket when you see one.

Example payload:

```json
{
  "connectionStatus": {
    "phase": "idle",
    "error": {
      "kind": "scaleConnectFailed",
      "severity": "error",
      "timestamp": "2026-04-19T07:49:29.025Z",
      "deviceId": "50:78:7D:1F:AE:E1",
      "deviceName": "Decent Scale",
      "message": "Scale Decent Scale failed to connect.",
      "suggestion": "Wake the scale and try again.",
      "details": {"fbp_code": 1}
    }
  }
}
```

`connectionStatus.error` is `null` when no error is active.

**Kind taxonomy:**

| `kind` | When | Recommended action |
|---|---|---|
| `scaleConnectFailed` | Scale connect timeout / GATT 133 retries exhausted / etc. | Retry scan |
| `machineConnectFailed` | DE1 connect fails | Retry scan |
| `scaleDisconnected` | Scale drops mid-session (unexpected) | Retry scan |
| `machineDisconnected` | DE1 drops mid-session (unexpected) | Retry scan |
| `adapterOff` | Bluetooth adapter powered off | Instruct user to enable Bluetooth (no retry button) |
| `bluetoothPermissionDenied` | BLE runtime permission refused | Instruct user to grant permission |
| `scanFailed` | Scan failed to start | Retry scan |
| `profileUploadFailed` | A profile upload to the machine failed; the app is retrying with backoff | None — informational. Persists across phase transitions. Retracted when a retry lands, the machine disconnects, or the retry cycle ends. |

**Lifecycle rules:**

- **Transient kinds** (`scaleConnectFailed`, `machineConnectFailed`, `scaleDisconnected`, `machineDisconnected`) auto-clear when a new operation starts — i.e. the phase transitions to `scanning`, `connectingMachine`, `connectingScale`, or `ready`.
- **`profileUploadFailed`** survives phase transitions (like sticky kinds) but is retracted explicitly: when a retry succeeds, the machine disconnects (terminating the retry cycle), or the retry cycle is disposed. Treat it as "the machine may not be holding your selected profile yet", not as a dead end — no user action is required.
- **Sticky kinds** (`adapterOff`, `bluetoothPermissionDenied`, `scanFailed`) survive phase transitions. They clear only when the environment recovers (adapter on, permission granted, successful scan start).
- Emitting any new error overwrites the previous one. **Latest event wins.**

**Client pattern:** use `kind` as the primary lookup key for your own copy / action mapping; fall back to `message` + `suggestion` for unknown kinds. De-duplicate toasts by `timestamp`.

```javascript
const copyForKind = {
  scaleConnectFailed: 'Scale did not connect. Wake it and retry.',
  machineConnectFailed: 'DE1 did not connect. Retry scan.',
  scaleDisconnected: 'Scale dropped. Retry scan.',
  machineDisconnected: 'DE1 dropped. Retry scan.',
  adapterOff: 'Bluetooth is off. Turn it on to continue.',
  bluetoothPermissionDenied: 'Grant Bluetooth permission to continue.',
  scanFailed: 'Scan could not start. Retry.',
  profileUploadFailed: 'Profile did not reach the machine. Retrying…',
};

let lastSeen = null;

ws.addEventListener('message', (e) => {
  const msg = JSON.parse(e.data);
  const err = msg.connectionStatus?.error;

  if (!err) {
    hideBanner();
    return;
  }

  if (err.timestamp !== lastSeen) {
    lastSeen = err.timestamp;
    toast(copyForKind[err.kind] ?? `${err.message}\n${err.suggestion ?? ''}`);
  }

  showBanner(copyForKind[err.kind] ?? err.message);
});
```

**Do not reconnect the WebSocket on an error.** The socket stays open across errors; reconnecting will just miss the next status update.

---

## Best Practices

### 1. Connection Management

Always implement reconnection logic for WebSockets:

```javascript
class GatewayConnection {
  constructor(url) {
    this.url = url;
    this.ws = null;
    this.reconnectDelay = 1000;
    this.maxReconnectDelay = 30000;
  }
  
  connect() {
    this.ws = new WebSocket(this.url);
    
    this.ws.onopen = () => {
      console.log('Connected');
      this.reconnectDelay = 1000; // Reset delay on successful connection
    };
    
    this.ws.onclose = () => {
      console.log(`Reconnecting in ${this.reconnectDelay}ms`);
      setTimeout(() => this.connect(), this.reconnectDelay);
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.maxReconnectDelay);
    };
    
    this.ws.onerror = (error) => {
      console.error('WebSocket error:', error);
      this.ws.close();
    };
    
    this.ws.onmessage = (event) => {
      const data = JSON.parse(event.data);
      this.handleMessage(data);
    };
  }
  
  handleMessage(data) {
    // Override in subclass
  }
}
```

### 2. Data Buffering for Charts

For smooth chart updates, buffer incoming data points:

```javascript
class ShotChart {
  constructor(maxPoints = 500) {
    this.data = {
      time: [],
      pressure: [],
      flow: [],
      temperature: []
    };
    this.maxPoints = maxPoints;
    this.startTime = null;
  }
  
  addPoint(snapshot) {
    if (!this.startTime) {
      this.startTime = new Date(snapshot.timestamp);
    }
    
    const elapsed = (new Date(snapshot.timestamp) - this.startTime) / 1000;
    
    // Add new data point
    this.data.time.push(elapsed);
    this.data.pressure.push(snapshot.pressure);
    this.data.flow.push(snapshot.flow);
    this.data.temperature.push(snapshot.mixTemperature);
    
    // Trim if exceeds max points
    if (this.data.time.length > this.maxPoints) {
      Object.keys(this.data).forEach(key => {
        this.data[key].shift();
      });
    }
    
    this.render();
  }
  
  reset() {
    this.startTime = null;
    Object.keys(this.data).forEach(key => {
      this.data[key] = [];
    });
  }
}
```

### 3. Error Handling

Always handle API errors gracefully:

```javascript
async function sendCommand(endpoint, method = 'GET', body = null) {
  try {
    const options = {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : {},
    };
    
    if (body) {
      options.body = JSON.stringify(body);
    }
    
    const response = await fetch(`${GATEWAY_URL}${endpoint}`, options);
    
    if (!response.ok) {
      let errorMsg;
      try {
        const error = await response.json();
        errorMsg = error.message || error.e || `HTTP ${response.status}`;
      } catch {
        errorMsg = `HTTP ${response.status}`;
      }
      throw new Error(errorMsg);
    }
    
    // Some endpoints return 204 No Content
    if (response.status === 204) {
      return null;
    }
    
    return await response.json();
  } catch (error) {
    console.error(`Command failed: ${endpoint}`, error);
    showErrorToast(error.message);
    throw error;
  }
}
```

### 4. State Management

Maintain local state synchronized with machine state:

```javascript
class MachineState {
  constructor() {
    this.state = 'idle';
    this.substate = 'idle';
    this.pressure = 0;
    this.flow = 0;
    this.mixTemperature = 0;
    this.steamTemperature = 0;
    this.listeners = [];
  }
  
  update(snapshot) {
    const stateChanged = this.state !== snapshot.state.state;
    
    this.state = snapshot.state.state;
    this.substate = snapshot.state.substate;
    this.pressure = snapshot.pressure;
    this.flow = snapshot.flow;
    this.mixTemperature = snapshot.mixTemperature;
    this.steamTemperature = snapshot.steamTemperature;
    
    if (stateChanged) {
      this.notifyListeners('stateChange', this.state);
    }
    
    this.notifyListeners('update', snapshot);
  }
  
  on(event, callback) {
    this.listeners.push({ event, callback });
  }
  
  notifyListeners(event, data) {
    this.listeners
      .filter(l => l.event === event)
      .forEach(l => l.callback(data));
  }
}

// Usage
const machine = new MachineState();

machine.on('stateChange', (newState) => {
  console.log('Machine state changed to:', newState);
  if (newState === 'espresso') {
    startShotTimer();
  }
});

// In WebSocket handler
ws.onmessage = (event) => {
  const snapshot = JSON.parse(event.data);
  machine.update(snapshot);
};
```

### 5. Handling Machine State Transitions

Different machine states allow different operations:

```javascript
const ALLOWED_OPERATIONS = {
  idle: ['setState', 'uploadProfile', 'updateSettings'],
  sleeping: ['setState'],
  heating: ['setState'],
  preheating: ['setState'],
  espresso: ['stopShot'],
  steam: ['setState'],
  hotWater: ['setState']
};

function canExecute(operation, currentState) {
  return ALLOWED_OPERATIONS[currentState]?.includes(operation) ?? false;
}

async function startShot() {
  if (!canExecute('startShot', machine.state)) {
    showError(`Cannot start shot in ${machine.state} state`);
    return;
  }
  
  // First ensure machine is in espresso state
  await sendCommand('/api/v1/machine/state/espresso', 'PUT');
  
  // Wait for state transition (listen to WebSocket)
  await waitForState('espresso');
  
  // Now you could start the shot if you had a start shot endpoint
  // The actual shot start is triggered by the machine when ready
}
```

---

## Advanced Features

### 1. Custom Profile Creation

Create and upload custom profiles programmatically:

```javascript
async function createAndUploadProfile() {
  const customProfile = {
    version: "2",
    title: "My Custom Profile",
    author: "MySkin",
    notes: "Pressure ramping experiment",
    beverage_type: "espresso",
    steps: [
      {
        name: "preinfusion",
        temperature: 93.0,
        sensor: "water",
        pump: "pressure",
        transition: "fast",
        pressure: 4.0,
        flow: 2.0,
        seconds: 8.0,
        exit_type: 0, // exit on time
        exit_condition: 8.0,
        exit_flow_over: 0,
        exit_flow_under: 0,
        exit_pressure_over: 0,
        exit_pressure_under: 0,
        limiter_value: 0,
        limiter_range: 0
      },
      {
        name: "ramp_up",
        temperature: 93.0,
        sensor: "water",
        pump: "pressure",
        transition: "smooth",
        pressure: 9.0,
        flow: 2.5,
        seconds: 5.0,
        exit_type: 0,
        exit_condition: 5.0,
        exit_flow_over: 0,
        exit_flow_under: 0,
        exit_pressure_over: 0,
        exit_pressure_under: 0,
        limiter_value: 0,
        limiter_range: 0
      },
      {
        name: "hold",
        temperature: 93.0,
        sensor: "water",
        pump: "pressure",
        transition: "fast",
        pressure: 9.0,
        flow: 2.5,
        seconds: 20.0,
        exit_type: 0,
        exit_condition: 20.0,
        exit_flow_over: 0,
        exit_flow_under: 0,
        exit_pressure_over: 0,
        exit_pressure_under: 0,
        limiter_value: 0,
        limiter_range: 0
      }
    ],
    target_volume: 0,
    target_weight: 36,
    target_volume_count_start: 0,
    tank_temperature: 0
  };

  // Create profile in REA
  const created = await sendCommand('/api/v1/profiles', 'POST', {
    profile: customProfile,
    parentId: null,
    metadata: {
      tags: ["custom", "experimental"]
    }
  });

  console.log('Created profile:', created.id);

  // Upload to machine
  await sendCommand('/api/v1/machine/profile', 'POST', created.profile);
  
  console.log('Profile uploaded to machine');
  
  return created;
}
```

### 2. Workflow-Based Brewing

Use workflows to manage complete brewing recipes including all machine settings:

```javascript
async function setupCompleteWorkflow() {
  const workflow = {
    name: "Morning Shot",
    description: "My daily espresso routine",
    profile: await getProfileById('profile:a1b2c3d4e5f6'),
    doseData: {
      doseIn: 18.0,
      doseOut: 36.0
    },
    grinderData: {
      setting: "2.5",
      manufacturer: "Niche",
      model: "Zero"
    },
    coffeeData: {
      name: "Ethiopia Yirgacheffe",
      roaster: "Local Roaster"
    },
    steamSettings: {
      targetTemperature: 150,
      duration: 50,
      flow: 0.8
    },
    hotWaterData: {
      targetTemperature: 75,
      duration: 30,
      volume: 50,
      flow: 10.0
    },
    rinseData: {
      targetTemperature: 90,
      duration: 10,
      flow: 6.0
    }
  };
  
  await sendCommand('/api/v1/workflow', 'PUT', workflow);
  console.log('Complete workflow updated and uploaded to machine');
}

async function updateJustSteamSettings() {
  // You can also update just specific parts
  const partialWorkflow = {
    steamSettings: {
      targetTemperature: 155,
      duration: 60,
      flow: 0.9
    }
  };
  
  await sendCommand('/api/v1/workflow', 'PUT', partialWorkflow);
  console.log('Steam settings updated');
}

async function getProfileById(id) {
  const profile = await sendCommand(`/api/v1/profiles/${id}`);
  return profile.profile;
}
```

### 3. Real-Time Shot Recording

Combine machine and scale data for shot recording:

```javascript
class ShotRecorder {
  constructor() {
    this.recording = false;
    this.measurements = [];
    this.startTime = null;
    this.machineWs = null;
    this.scaleWs = null;
    this.latestMachine = null;
    this.latestScale = null;
  }
  
  start() {
    this.recording = true;
    this.measurements = [];
    this.startTime = Date.now();
    
    // Connect to both streams
    this.machineWs = new WebSocket('ws://192.168.1.100:8080/ws/v1/machine/snapshot');
    this.scaleWs = new WebSocket('ws://192.168.1.100:8080/ws/v1/scale/snapshot');
    
    this.machineWs.onmessage = (event) => {
      this.latestMachine = JSON.parse(event.data);
      this.recordMeasurement();
    };
    
    this.scaleWs.onmessage = (event) => {
      this.latestScale = JSON.parse(event.data);
    };
  }
  
  recordMeasurement() {
    if (!this.recording) return;
    
    this.measurements.push({
      machine: { ...this.latestMachine },
      scale: this.latestScale ? { ...this.latestScale } : null,
      volume: null // Volume calculation would need to be added
    });
  }
  
  async stop() {
    this.recording = false;
    this.machineWs?.close();
    this.scaleWs?.close();
    
    const workflow = await sendCommand('/api/v1/workflow');
    
    const shotRecord = {
      id: `shot-${Date.now()}`,
      timestamp: new Date(this.startTime).toISOString(),
      measurements: this.measurements,
      workflow: workflow
    };
    
    // Save to your own storage or send to custom backend
    console.log('Shot recorded:', shotRecord);
    
    return shotRecord;
  }
}

// Usage
const recorder = new ShotRecorder();

machine.on('stateChange', (newState) => {
  if (newState === 'espresso') {
    recorder.start();
  } else if (recorder.recording) {
    recorder.stop();
  }
});
```

### 4. Display & Presence Integration

Combine display control with user presence to build a polished idle experience:

```javascript
class IdleManager {
  constructor(gatewayUrl) {
    this.gatewayUrl = gatewayUrl;
    this.displayWs = null;
    this.idleTimer = null;
    this.dimAfterMs = 60000;  // Dim after 1 minute of inactivity
  }

  start() {
    // Connect to display WebSocket for real-time state + auto-cleanup
    this.displayWs = new WebSocket(
      `${this.gatewayUrl.replace('http', 'ws')}/ws/v1/display`
    );

    this.displayWs.onopen = () => {
      // Keep screen on while skin is active
      this.displayWs.send(JSON.stringify({ command: 'requestWakeLock' }));
    };

    this.displayWs.onmessage = (event) => {
      const state = JSON.parse(event.data);
      updateDisplayIndicator(state);
    };

    // Track user activity
    document.addEventListener('pointerdown', () => this.onUserActivity());
    document.addEventListener('keydown', () => this.onUserActivity());

    this.resetIdleTimer();
  }

  onUserActivity() {
    this.resetIdleTimer();

    // Restore brightness if dimmed
    this.displayWs?.send(JSON.stringify({ command: 'setBrightness', brightness: 100 }));

    // Signal presence to prevent machine auto-sleep
    fetch(`${this.gatewayUrl}/api/v1/machine/heartbeat`, { method: 'POST' });
  }

  resetIdleTimer() {
    clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => {
      // Dim screen when user is idle
      this.displayWs?.send(JSON.stringify({ command: 'setBrightness', brightness: 5 }));
    }, this.dimAfterMs);
  }

  stop() {
    clearTimeout(this.idleTimer);
    this.displayWs?.close();  // Auto-releases wake-lock
  }
}

// Usage
const idle = new IdleManager('http://192.168.1.100:8080');
idle.start();
```

### 5. Wake Schedule Management

Let users configure automatic machine wake times:

```javascript
async function setupMorningSchedule() {
  // Create a weekday morning schedule
  const schedule = await sendCommand('/api/v1/presence/schedules', 'POST', {
    time: '06:30',
    daysOfWeek: [1, 2, 3, 4, 5],  // Monday-Friday
    enabled: true
  });

  console.log('Created schedule:', schedule.id);
  return schedule;
}

async function renderScheduleUI() {
  const settings = await sendCommand('/api/v1/presence/settings');

  // Show all schedules
  for (const schedule of settings.schedules) {
    const days = schedule.daysOfWeek.length === 0
      ? 'Every day'
      : schedule.daysOfWeek.map(d =>
          ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d]
        ).join(', ');

    console.log(`${schedule.time} - ${days} (${schedule.enabled ? 'on' : 'off'})`);
  }

  // Show auto-sleep settings
  if (settings.userPresenceEnabled) {
    console.log(`Auto-sleep after ${settings.sleepTimeoutMinutes} minutes of inactivity`);
  }
}
```

### 6. Plugin Integration

Listen to plugin events for extended functionality:

```javascript
// Connect to plugin event stream
const pluginWs = new WebSocket('ws://192.168.1.100:8080/ws/v1/plugins/shot-logger/shotComplete');

pluginWs.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('Shot completed:', data);
  
  // Update UI with plugin data
  showNotification(`Shot logged: ${data.weight}g in ${data.time}s`);
};
```

---

## Example: Minimal Working Skin

Here's a complete minimal skin implementation:

```html
<!DOCTYPE html>
<html>
<head>
  <title>Minimal Decaid Skin</title>
  <style>
    body {
      font-family: 'Segoe UI', system-ui, sans-serif;
      padding: 20px;
      max-width: 800px;
      margin: 0 auto;
      background: #1a1a1a;
      color: #fff;
    }
    
    h1 { margin-bottom: 30px; }
    
    .status {
      background: #2a2a2a;
      padding: 20px;
      border-radius: 8px;
      margin-bottom: 20px;
    }
    
    .status-item {
      display: flex;
      justify-content: space-between;
      margin: 10px 0;
      padding: 5px 0;
      border-bottom: 1px solid #3a3a3a;
    }
    
    .status-label {
      color: #888;
    }
    
    .status-value {
      font-weight: bold;
      color: #4CAF50;
    }
    
    .controls {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
    }
    
    button {
      padding: 12px 24px;
      font-size: 14px;
      border: none;
      border-radius: 6px;
      background: #4CAF50;
      color: white;
      cursor: pointer;
      transition: background 0.3s;
    }
    
    button:hover {
      background: #45a049;
    }
    
    button:disabled {
      background: #555;
      cursor: not-allowed;
    }
    
    .error {
      background: #d32f2f;
      color: white;
      padding: 10px;
      border-radius: 4px;
      margin-top: 10px;
      display: none;
    }
    
    .connection-status {
      display: inline-block;
      width: 10px;
      height: 10px;
      border-radius: 50%;
      margin-right: 8px;
    }
    
    .connection-status.connected {
      background: #4CAF50;
    }
    
    .connection-status.disconnected {
      background: #d32f2f;
    }
  </style>
</head>
<body>
  <h1>
    <span class="connection-status disconnected" id="connection-indicator"></span>
    Decent Control
  </h1>
  
  <div class="status">
    <div class="status-item">
      <span class="status-label">Machine State:</span>
      <span class="status-value" id="state">-</span>
    </div>
    <div class="status-item">
      <span class="status-label">Substate:</span>
      <span class="status-value" id="substate">-</span>
    </div>
    <div class="status-item">
      <span class="status-label">Mix Temperature:</span>
      <span class="status-value" id="mix-temp">-</span>
    </div>
    <div class="status-item">
      <span class="status-label">Steam Temperature:</span>
      <span class="status-value" id="steam-temp">-</span>
    </div>
    <div class="status-item">
      <span class="status-label">Pressure:</span>
      <span class="status-value" id="pressure">-</span>
    </div>
    <div class="status-item">
      <span class="status-label">Flow:</span>
      <span class="status-value" id="flow">-</span>
    </div>
    <div class="status-item">
      <span class="status-label">Scale Weight:</span>
      <span class="status-value" id="weight">-</span>
    </div>
  </div>
  
  <div class="controls">
    <button onclick="setMachineState('espresso')">Espresso Mode</button>
    <button onclick="setMachineState('steam')">Steam Mode</button>
    <button onclick="setMachineState('idle')">Idle</button>
    <button onclick="setMachineState('sleeping')">Sleep</button>
    <button onclick="tareScale()">Tare Scale</button>
  </div>
  
  <div class="error" id="error"></div>
  
  <script>
    const GATEWAY = 'http://192.168.1.100:8080';
    let machineWs = null;
    let scaleWs = null;
    let reconnectDelay = 1000;
    const maxReconnectDelay = 30000;
    
    function connectWebSockets() {
      // Machine snapshot stream
      machineWs = new WebSocket(`ws://192.168.1.100:8080/ws/v1/machine/snapshot`);
      
      machineWs.onopen = () => {
        console.log('Machine WebSocket connected');
        document.getElementById('connection-indicator').className = 'connection-status connected';
        reconnectDelay = 1000;
      };
      
      machineWs.onmessage = (event) => {
        const data = JSON.parse(event.data);
        document.getElementById('state').textContent = data.state.state;
        document.getElementById('substate').textContent = data.state.substate;
        document.getElementById('mix-temp').textContent = data.mixTemperature.toFixed(1) + '°C';
        document.getElementById('steam-temp').textContent = data.steamTemperature.toFixed(1) + '°C';
        document.getElementById('pressure').textContent = data.pressure.toFixed(1) + ' bar';
        document.getElementById('flow').textContent = data.flow.toFixed(1) + ' ml/s';
      };
      
      machineWs.onerror = (error) => {
        console.error('Machine WebSocket error:', error);
      };
      
      machineWs.onclose = () => {
        console.log('Machine WebSocket closed, reconnecting...');
        document.getElementById('connection-indicator').className = 'connection-status disconnected';
        setTimeout(connectWebSockets, reconnectDelay);
        reconnectDelay = Math.min(reconnectDelay * 2, maxReconnectDelay);
      };
      
      // Scale snapshot stream
      scaleWs = new WebSocket(`ws://192.168.1.100:8080/ws/v1/scale/snapshot`);
      
      scaleWs.onmessage = (event) => {
        const data = JSON.parse(event.data);
        document.getElementById('weight').textContent = data.weight.toFixed(1) + ' g';
      };
      
      scaleWs.onerror = (error) => {
        console.error('Scale WebSocket error:', error);
      };
      
      scaleWs.onclose = () => {
        console.log('Scale WebSocket closed');
        document.getElementById('weight').textContent = '- g';
      };
    }
    
    async function setMachineState(state) {
      try {
        hideError();
        const response = await fetch(`${GATEWAY}/api/v1/machine/state/${state}`, {
          method: 'PUT'
        });
        
        if (!response.ok) {
          throw new Error(`Failed to set state: ${response.status}`);
        }
        
        console.log(`State changed to ${state}`);
      } catch (error) {
        showError(error.message);
      }
    }
    
    async function tareScale() {
      try {
        hideError();
        const response = await fetch(`${GATEWAY}/api/v1/scale/tare`, {
          method: 'PUT'
        });
        
        if (!response.ok) {
          if (response.status === 404) {
            throw new Error('Scale not connected');
          }
          throw new Error(`Failed to tare scale: ${response.status}`);
        }
        
        console.log('Scale tared');
      } catch (error) {
        showError(error.message);
      }
    }
    
    function showError(message) {
      const errorDiv = document.getElementById('error');
      errorDiv.textContent = message;
      errorDiv.style.display = 'block';
    }
    
    function hideError() {
      document.getElementById('error').style.display = 'none';
    }
    
    // Initialize
    connectWebSockets();
  </script>
</body>
</html>
```

---

## Troubleshooting

### WebSocket Connection Fails
- Verify gateway is running: `curl http://<ip>:8080/api/v1/machine/state`
- Check firewall rules on the gateway device
- Ensure you're using `ws://` (not `wss://`) unless TLS is configured
- Check browser console for specific error messages

### Snapshot Data Stops Flowing
- Check browser console for WebSocket errors
- Verify connection state: `ws.readyState` (1 = OPEN)
- Implement reconnection logic (see Best Practices)
- Check if machine is actually connected to Decaid

### Commands Don't Execute
- Check HTTP response status codes
- Verify machine is in correct state for the operation
- Review Decaid logs: Connect to `ws://<ip>:8080/ws/v1/logs`
- Ensure machine is connected: `GET /api/v1/devices`

### Profile Upload Fails
- Validate profile JSON structure (use v2 format)
- Ensure all required fields are present
- Check that `steps` array is properly formatted
- Verify machine is in `idle` or `sleeping` state

### Scale Not Responding
- Check scale is connected: `GET /api/v1/devices`
- Scan and reconnect a missing scale: `GET /api/v1/devices/scan`
- If alternatives produce ambiguity, connect the selected scale: `PUT /api/v1/devices/connect` with `{"deviceId":"..."}`
- Check scale battery level via scale snapshot stream

---

## API Reference

For complete, interactive API documentation, visit:
```
http://<gateway-ip>:4001
```

This serves OpenAPI/Swagger documentation with:
- All REST endpoints
- Request/response schemas
- Try-it-out functionality
- WebSocket endpoint documentation

---

## Skin Development & Deployment

This section covers how to develop, build, and deploy custom WebUI skins for Decaid, including support for modern web frameworks like Next.js, React, Vue, Svelte, and others.

### Understanding Skin Distribution

Decaid supports multiple skin installation methods:

1. **Bundled Asset Skins**: Skins packaged with the Flutter app (in `assets/web/`)
2. **Remote Bundled Skins**: Skins auto-downloaded from hardcoded GitHub URLs on app startup
3. **User-Installed Skins**: Installed by users via the Settings UI or REST API
4. **Live-Edit Skins**: Served directly from a local folder for development (not copied to app storage)

**Skin Directory Structure:**
```
ApplicationDocuments/
└── web-ui/
    ├── my-skin-id/
    │   ├── index.html        # Required entry point
    │   ├── manifest.json     # Optional metadata
    │   ├── assets/
    │   ├── _next/            # Next.js example
    │   └── ...
    ├── another-skin/
    └── .rea_metadata.json    # Version tracking (managed by REA)
```

> **Skin id restrictions:** A skin's id (from `skin-manifest.json`, `manifest.json`, or the install folder name) becomes a directory name under `web-ui/`, so it must be a single safe filesystem path component: no `/` or `\` separators, no `.` or `..`, no leading drive letter or NUL byte, and no Windows-reserved characters. Unsafe ids are rejected with a clear error and the skin is not installed.

### Cross-Skin Asset Sharing

A skin can fetch files from any other installed skin via:

```
GET /api/v1/webui/skin-assets/{id}/{filepath}
```

- `{id}` — installed skin id (see `GET /api/v1/webui/skins`).
- `{filepath}` — path inside that skin's folder (e.g. `assets/logo.svg`, `components/widget.js`).

The response is the raw file bytes; `Content-Type` is sniffed from the file. This lets a skin reuse icons, fonts, web components, or shared scripts hosted by another installed skin instead of duplicating them.

```html
<!-- pulling a shared logo from another installed skin -->
<img src="/api/v1/webui/skin-assets/shared-assets/icons/logo.svg" />

<!-- loading a component module from a "components" skin -->
<script type="module"
        src="/api/v1/webui/skin-assets/sb-components/dist/gauge.js"></script>
```

The endpoint only serves files from already-installed skins — install the asset-providing skin first via the normal install flow.

### Skin Metadata: manifest.json

While optional, including a `manifest.json` helps Decaid display better skin information:

```json
{
  "id": "my-nextjs-skin",
  "name": "Beautiful Espresso UI",
  "description": "Modern Next.js skin with real-time shot visualization",
  "version": "1.2.0",
  "author": "Your Name",
  "repository": "https://github.com/username/repo"
}
```

**Important**: If `manifest.json` is missing, the skin ID will be the directory name.

---

## Local Development Workflow

### 1. Develop Your Skin Locally

Use any modern web framework. Here's a Next.js example:

**Create Next.js App:**
```bash
npx create-next-app@latest my-espresso-skin
cd my-espresso-skin
```

**Configure for Static Export** (`next.config.js`):
```javascript
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'export',  // Enable static HTML export
  images: {
    unoptimized: true  // Required for static export
  },
  // Optional: Add base path if serving from subdirectory
  // basePath: '/my-skin',
  // assetPrefix: '/my-skin',
}

module.exports = nextConfig
```

**Build Your Skin:**
```bash
npm run build
```

This creates an `out/` directory with static HTML/CSS/JS files.

### 2. Test Locally with Decaid

**Option A: Live-Edit Mode** (recommended for development on desktop):

1. Build your skin (`npm run build`)
2. In Decaid **Settings**, select **"Live-edit from folder..."**
3. Point it at your build output directory (e.g., `out/` or `dist/`)
4. Edit, rebuild, and refresh — no reinstallation needed

**Option B: Install from ZIP** (works on all platforms):

1. Package your build output as a `.zip`
2. In **Settings**, select **"Install from .zip..."** and pick the file
3. The skin is extracted and served immediately

**Option C: Install via REST API:**

```bash
# Install from a local or remote URL
curl -X POST http://localhost:8080/api/v1/webui/skins/install/url \
  -H "Content-Type: application/json" \
  -d '{"url": "file:///path/to/my-skin.zip"}'
```

**Option D: Serve Locally and Point Browser** (during development):

```bash
# In your Next.js project
npm run dev

# Access directly at http://localhost:3000
# Connect to Decaid API at http://<gateway-ip>:8080
```

### 3. Connect to Gateway During Development

When developing locally, your skin needs to connect to the Decaid gateway:

```javascript
// Use environment variable or config
const GATEWAY_URL = process.env.NEXT_PUBLIC_GATEWAY_URL || 'http://192.168.1.100:8080';
const WS_URL = process.env.NEXT_PUBLIC_WS_URL || 'ws://192.168.1.100:8080';

// In your API client
export const apiClient = {
  async getMachineState() {
    const response = await fetch(`${GATEWAY_URL}/api/v1/machine/state`);
    return response.json();
  },
  
  connectSnapshot() {
    return new WebSocket(`${WS_URL}/ws/v1/machine/snapshot`);
  }
};
```

**Development `.env.local`:**
```bash
NEXT_PUBLIC_GATEWAY_URL=http://192.168.1.100:8080
NEXT_PUBLIC_WS_URL=ws://192.168.1.100:8080
```

---

## Production Deployment via GitHub Releases

For production distribution, use GitHub Releases to publish built skins. This approach provides:
- Semantic versioning via Git tags
- Automatic update detection
- Clean separation of source code vs. distribution files
- Professional software distribution workflow

### Method 1: GitHub Actions Automated Release

**Create `.github/workflows/release.yml`:**

```yaml
name: Build and Release WebUI Skin

on:
  push:
    tags:
      - 'v*'  # Trigger on version tags like v1.0.0, v1.2.3, etc.
  workflow_dispatch:  # Allow manual triggering from GitHub UI

jobs:
  build-and-release:
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
      
      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
          cache: 'npm'
          
      - name: Install dependencies
        run: npm ci
        
      - name: Build Next.js app
        run: npm run build
        
      - name: Create manifest.json
        run: |
          cat > out/manifest.json << EOF
          {
            "id": "my-nextjs-skin",
            "name": "Beautiful Espresso UI",
            "description": "Modern Next.js skin with real-time shot visualization",
            "version": "${{ github.ref_name }}",
            "author": "Your Name",
            "repository": "${{ github.repository }}"
          }
          EOF
      
      - name: Create release archive
        run: |
          cd out
          zip -r ../my-skin-${{ github.ref_name }}.zip .
          cd ..
          
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v1
        with:
          files: my-skin-${{ github.ref_name }}.zip
          tag_name: ${{ github.ref_name }}
          name: Release ${{ github.ref_name }}
          draft: false
          prerelease: false
          generate_release_notes: true
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**Usage:**
```bash
# Create and push a version tag
git tag v1.0.0
git push origin v1.0.0

# GitHub Actions will automatically:
# 1. Build your Next.js app
# 2. Create manifest.json with version
# 3. Package as ZIP
# 4. Create GitHub Release with the ZIP attached
```

### Method 2: Distribution Branch (Alternative)

If you prefer not to use GitHub Releases, deploy to a separate `dist` branch:

**Create `.github/workflows/build-dist.yml`:**

```yaml
name: Build to Dist Branch

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
      
      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
          cache: 'npm'
          
      - name: Install and build
        run: |
          npm ci
          npm run build
          
      - name: Create manifest
        run: |
          cat > out/manifest.json << EOF
          {
            "id": "my-nextjs-skin",
            "name": "Beautiful Espresso UI",
            "version": "$(git rev-parse --short HEAD)",
            "author": "Your Name"
          }
          EOF
      
      - name: Deploy to dist branch
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./out
          publish_branch: dist
          force_orphan: true  # Keep dist branch clean (no history)
```

Then install from the `dist` branch:
```dart
// In webui_storage.dart _remoteWebUISources
'https://github.com/username/repo/archive/refs/heads/dist.zip'
```

---

## Configuring Decaid for Auto-Download

### For Remote Bundled Skins (Auto-Download on Startup)

Edit `lib/src/webui_support/webui_storage.dart`:

```dart
/// Remote WebUI source configuration
static const List<Map<String, dynamic>> _remoteWebUISources = [
  // GitHub Release (recommended for production)
  {
    'type': 'github_release',
    'repo': 'username/my-skin-repo',
    'asset': 'my-skin.zip',  // Optional: specific asset name
    'prerelease': false,      // Optional: include pre-releases
  },
  // GitHub Branch Archive
  {
    'type': 'github_branch',
    'repo': 'username/my-skin-repo',
    'branch': 'main',
  },
  // Direct URL
  {
    'type': 'url',
    'url': 'https://example.com/skin.zip',
  },
];
```

**Decaid will:**
- Download skins on first app startup
- Check for updates on subsequent startups
- For GitHub releases: checks for new release tags
- For branches/URLs: uses HTTP ETag/Last-Modified headers
- Only re-download if remote version has changed
- Mark these skins as "bundled" (users cannot remove them)

### In-App Skin Management (Settings UI)

The Settings screen provides a skin selector dropdown with built-in management:

**Installing a Skin from ZIP:**
1. Open **Settings** → tap the skin selector dropdown
2. Select **"Install from .zip..."**
3. Pick a `.zip` file containing your skin (must include `index.html` at root)
4. The skin is extracted to app storage, set as default, and served immediately

**Live-Edit Mode (Development):**
1. Select **"Live-edit from folder..."** in the skin dropdown
2. Pick a folder containing your skin's build output
3. Decaid serves files directly from that folder — no copying
4. Edit your skin files and refresh the browser to see changes instantly

Live-edit validates that the selected folder contains an `index.html`.

**Deleting a Skin:**
- Non-bundled skins show a delete button (trash icon) in the dropdown
- Confirmation dialog prevents accidental deletion
- If the deleted skin is currently active, Decaid switches to the default skin

**Platform Support:**

| Feature | Android | iOS | macOS | Linux | Windows | App Store |
|---------|---------|-----|-------|-------|---------|-----------|
| Install from ZIP | yes | yes | yes | yes | yes | yes |
| Live-edit folder | yes* | no | yes | yes | yes | no |
| Delete skins | yes | yes | yes | yes | yes | yes |

\* Android requires the **Manage External Storage** permission for live-edit. A permission button appears in Settings when needed.

### Settings Plugin (Web-Based Management)

The bundled **settings plugin** provides a web-based settings dashboard at `/api/v1/plugins/settings.reaplugin/ui`. It includes a "Web Interface" section for skin management: select active skin, start/stop server, install/remove skins, and check for updates — all from a browser.

**Linking back from your skin:** Skins can link to the settings plugin with a customizable back button label using the `backName` query parameter:

```
http://<host>:8080/api/v1/plugins/settings.reaplugin/ui?backName=MySkin
```

This shows "Back to MySkin" in the settings plugin's nav bar. When clicked, it navigates to `http://<host>:3000/?_=<timestamp>` (with cache busting). This allows skins to provide a "Settings" link that returns to the skin after configuration changes.

**External links:** When a skin runs inside the embedded webview (mobile/desktop app), navigations to `localhost:3000` and the settings plugin load in place; any other `http`/`https` link opens in the **system browser** while the skin stays loaded. A plain `<a href="https://…">` works, but the in-app webview blocks `target="_blank"` popups (`javaScriptCanOpenWindowsAutomatically: false`), so for JS-driven links route through a delegated click handler — `window.open(url, '_blank')` with a `location.href` fallback — so the navigation reaches `shouldOverrideUrlLoading` and is handed off to the OS.

**Return to the dashboard:** Skin pages served on port 3000 load the tokenless `/__decent/skin-api.js` from an absolute same-origin URL, which exposes `window.decentApp.exitToDashboard()`. ReaPrime stores the account-proxy token in escaped page metadata that only the same-origin script reads. Token injection accepts loopback and IP addresses currently assigned to the device, including Ethernet and secondary adapters; arbitrary hostnames and stale addresses are rejected. If local interface enumeration is unavailable, the WiFi address cached for the server link is used as a fallback. The script response also uses `Cross-Origin-Resource-Policy: same-origin`. In the embedded webview the callback closes the skin and reveals the Decent dashboard. In an external browser it is a no-op. The script works with `script-src 'self'`; policies that reject all same-origin scripts, such as `script-src 'none'` or nonce-only policies without `'self'`, also reject this API.

The embedded webview also shows a platform-specific navigation guide when a skin opens. On Windows, a persistent Dashboard button is overlaid in the top-right corner because WebView2 owns browser keyboard shortcuts. Disable or restore the guide in **Settings** under **General** with **Skin navigation guide**.

**Server control endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/v1/webui/server/status` | Current status (`{serving, path, port, ip}`) |
| POST | `/api/v1/webui/server/start` | Start serving the default skin on port 3000 |
| POST | `/api/v1/webui/server/stop` | Stop serving |
| POST | `/api/v1/webui/skins/update` | Check all remote skin sources for updates |

The start endpoint uses `defaultSkinId` from settings. To switch skins: set the default via `PUT /api/v1/webui/skins/default`, then restart the server.

### For User-Installable Skins (via REST API)

Users can also install skins dynamically via REST API without using the Settings UI:

**Install from GitHub Release:**
```bash
curl -X POST http://localhost:8080/api/v1/webui/skins/install/github-release \
  -H "Content-Type: application/json" \
  -d '{
    "repo": "username/my-skin-repo",
    "asset": "my-skin.zip",
    "prerelease": false
  }'
```

**Install from GitHub Branch:**
```bash
curl -X POST http://localhost:8080/api/v1/webui/skins/install/github-branch \
  -H "Content-Type: application/json" \
  -d '{
    "repo": "username/my-skin-repo",
    "branch": "main"
  }'
```

**Install from URL:**
```bash
curl -X POST http://localhost:8080/api/v1/webui/skins/install/url \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://example.com/skin.zip"
  }'
```

**List Installed Skins:**
```bash
curl http://localhost:8080/api/v1/webui/skins
```

**Get Specific Skin:**
```bash
curl http://localhost:8080/api/v1/webui/skins/my-skin-id
```

**Remove Skin (user-installed only):**
```bash
curl -X DELETE http://localhost:8080/api/v1/webui/skins/my-skin-id
```

**Get Default Skin:**
```bash
curl http://localhost:8080/api/v1/webui/skins/default
```

**Set Default Skin:**
```bash
curl -X PUT http://localhost:8080/api/v1/webui/skins/default \
  -H "Content-Type: application/json" \
  -d '{"skinId": "my-skin-id"}'
```

The default skin preference:
- Defaults to `streamline-project` if no preference is set
- Persists across app restarts
- Automatically saved when user selects a skin in Settings view
- Can be changed via API or Settings plugin

---

## Version Management & Updates

Decaid tracks skin metadata in `.rea_metadata.json`:

```json
{
  "my-nextjs-skin": {
    "skinId": "my-nextjs-skin",
    "sourceUrl": "github_branch:username/repo@dist",
    "etag": "\"abc123def456\"",
    "lastModified": "Wed, 01 Feb 2026 12:00:00 GMT",
    "commitHash": "branch:dist",
    "installedAt": "2026-02-01T12:00:00Z",
    "lastChecked": "2026-02-09T10:30:00Z"
  }
}
```

`sourceUrl` records where a skin came from so it can be refreshed later:

- `github_branch:owner/repo@branch` — GitHub branch installs
- `github_release:owner/repo@tag` — GitHub release installs. `releaseAssetName`
  (the specifically selected asset) and `includePrerelease` (prerelease
  tracking) are stored alongside and re-applied on every update.
- A plain `http(s)://` URL — raw URL installs, tracked via `etag` /
  `lastModified` headers

**Update Detection:**
- User-installed skins are checked for updates via `updateAllSkins()`, which
  runs on the app's periodic update check, from `POST /api/v1/webui/skins/update`,
  from the web settings plugin's "Check for Skin Updates", and from the native
  skin selector's "Check for updates" button.
- Raw-URL and GitHub-release skins are compared against their recorded source
  on every check: URL skins via HTTP `ETag` / `Last-Modified` headers,
  release skins by re-resolving the latest release (honoring the recorded
  `releaseAssetName` and `includePrerelease`).
- Only downloads if remote version differs from installed version
- Updates are automatic for remote bundled skins and all user-installed skins
  (GitHub branch, GitHub release, or raw URL)

---

## Best Practices for Skin Development

### 1. Environment Variables for Gateway URL

Always use environment variables for API endpoints:

```javascript
// .env.local (development)
NEXT_PUBLIC_GATEWAY_URL=http://192.168.1.100:8080
NEXT_PUBLIC_WS_URL=ws://192.168.1.100:8080

// .env.production (build)
NEXT_PUBLIC_GATEWAY_URL=http://localhost:8080
NEXT_PUBLIC_WS_URL=ws://localhost:8080
```

**Why localhost in production?** When served by Decaid, the skin runs on the same device as the gateway.

### 2. Static Export Configuration

Ensure your framework is configured for static export:

**Next.js** (`next.config.js`):
```javascript
module.exports = {
  output: 'export',
  images: { unoptimized: true }
}
```

**Vite** (`vite.config.js`):
```javascript
export default {
  base: './',  // Use relative paths
  build: {
    outDir: 'dist',
    assetsDir: 'assets'
  }
}
```

**Create React App**:
```bash
npm run build  # Already static by default
```

### 3. Handle Missing manifest.json

If you don't include `manifest.json`, ensure your directory name is descriptive:

```bash
# Build output structure
out/
├── index.html
├── _next/
└── assets/

# Will be installed as:
web-ui/
└── out/  # <- Skin ID will be "out" (not great!)
```

**Better:** Always include `manifest.json` with proper `id` field.

### 4. Test Before Release

Before creating a GitHub release:

1. **Build locally:**
   ```bash
   npm run build
   ```

2. **Test the build output:**
   ```bash
   npx serve out
   # Open http://localhost:3000
   ```

3. **Verify all assets load** (check browser console for 404s)

4. **Test WebSocket connections** to your development gateway

5. **Create manifest.json** and verify metadata

6. **Only then create release tag**

### 5. Versioning Strategy

Use semantic versioning for skin releases:

- `v1.0.0` - Initial release
- `v1.1.0` - New features, backward compatible
- `v1.1.1` - Bug fixes
- `v2.0.0` - Breaking changes

---

## Framework-Specific Examples

### Next.js

```bash
# Create app
npx create-next-app@latest my-skin

# Configure next.config.js for static export
# Build
npm run build

# Output is in ./out/
```

### React (Vite)

```bash
# Create app
npm create vite@latest my-skin -- --template react

# Build
npm run build

# Output is in ./dist/
```

### Vue

```bash
# Create app
npm create vue@latest my-skin

# Build
npm run build

# Output is in ./dist/
```

### Svelte

```bash
# Create app
npm create svelte@latest my-skin

# Install adapter-static
npm install -D @sveltejs/adapter-static

# Configure svelte.config.js
# Build
npm run build

# Output is in ./build/
```

---

## Troubleshooting

### Build Output Missing index.html

Ensure your framework is configured for static HTML generation:
- Next.js needs `output: 'export'`
- SvelteKit needs `@sveltejs/adapter-static`
- Some frameworks require explicit configuration

### Assets Not Loading (404 Errors)

Check asset paths are relative:
- Next.js: Automatically handled with `output: 'export'`
- Vite: Set `base: './'` in config
- Check browser console for failing asset URLs

### WebSocket Connection Fails

During development with skin on `localhost:3000` and gateway on `192.168.1.100:8080`:
- Ensure CORS is enabled on gateway (it is by default)
- Use explicit gateway IP in `NEXT_PUBLIC_WS_URL`
- Check browser console for connection errors

### Skin Not Appearing in Decaid

- Verify directory name or `manifest.json` `id` field
- Check `ApplicationDocuments/web-ui/` directory exists
- Ensure `index.html` is at root of skin directory
- Review Decaid logs for installation errors

### Updates Not Detected

For remote bundled skins:
- GitHub must return different `ETag` or `Last-Modified` headers
- Branch archives update when branch changes
- Releases have stable ETags (won't auto-update)
- Force re-download by deleting skin directory and restarting app

---

## Example: Complete Next.js Skin Project

**Project Structure:**
```
my-espresso-skin/
├── .github/
│   └── workflows/
│       └── release.yml
├── src/
│   ├── app/
│   │   ├── page.tsx
│   │   └── layout.tsx
│   ├── components/
│   │   ├── MachineStatus.tsx
│   │   └── ShotChart.tsx
│   └── lib/
│       └── api-client.ts
├── public/
├── next.config.js
├── package.json
├── .env.local
└── README.md
```

**next.config.js:**
```javascript
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'export',
  images: { unoptimized: true }
}

module.exports = nextConfig
```

**.env.local:**
```bash
NEXT_PUBLIC_GATEWAY_URL=http://192.168.1.100:8080
NEXT_PUBLIC_WS_URL=ws://192.168.1.100:8080
```

**src/lib/api-client.ts:**
```typescript
const GATEWAY_URL = process.env.NEXT_PUBLIC_GATEWAY_URL!;
const WS_URL = process.env.NEXT_PUBLIC_WS_URL!;

export const api = {
  async getMachineState() {
    const res = await fetch(`${GATEWAY_URL}/api/v1/machine/state`);
    return res.json();
  },
  
  async setMachineState(state: string) {
    await fetch(`${GATEWAY_URL}/api/v1/machine/state/${state}`, {
      method: 'PUT'
    });
  },
  
  connectSnapshot() {
    return new WebSocket(`${WS_URL}/ws/v1/machine/snapshot`);
  }
};
```

**package.json scripts:**
```json
{
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "next lint",
    "release": "npm run build && echo 'Ready to tag and push!'"
  }
}
```

**Deployment:**
```bash
# Development
npm run dev

# Production build
npm run build

# Create release
git tag v1.0.0
git push origin v1.0.0

# GitHub Actions builds and creates release automatically
```

---

## Advanced: Multiple Skins in One Repository

You can manage multiple skins in a monorepo:

```
espresso-skins/
├── packages/
│   ├── minimal/
│   │   ├── package.json
│   │   └── src/
│   ├── advanced/
│   │   ├── package.json
│   │   └── src/
│   └── experimental/
│       ├── package.json
│       └── src/
├── .github/
│   └── workflows/
│       ├── release-minimal.yml
│       ├── release-advanced.yml
│       └── release-experimental.yml
└── package.json (root)
```

Each skin can have its own release workflow targeting different GitHub Release tags.

---

## Contributing Your Skin

Once your skin is ready for public use:

1. **Document it well:**
   - Add screenshots to README
   - Document unique features
   - Provide setup instructions

2. **Add to community list:**
   - Submit PR to Decaid documentation
   - Share on Decent Diaspora forums

3. **Consider open-sourcing:**
   - Choose appropriate license (MIT, Apache, GPL, etc.)
   - Welcome contributions and issues

---

## Next Steps

1. **Study the Streamline Project** reference implementation for real-world patterns
2. **Start with the minimal example** above and expand incrementally
3. **Build interactive charts** using Chart.js, D3.js, or Plotly
4. **Explore workflow automation** for recurring brewing recipes
5. **Consider plugin development** for advanced custom functionality (see `Plugins.md`)

---

## Summary

**For Development:**
- Build your skin with any modern web framework
- Configure for static HTML export
- Test locally using `npm run dev` or by copying build to `web-ui/`
- Connect to gateway API using environment variables

**For Distribution:**
- Use GitHub Actions to automate builds
- Create releases with version tags (recommended)
- OR use a `dist` branch for continuous deployment
- Always include `manifest.json` with proper metadata

**For Auto-Updates:**
- Add your skin to `_remoteWebUISources` in `webui_storage.dart`
- Decaid will auto-download and check for updates
- Uses HTTP headers for efficient version detection

For questions or issues, open an issue on the [Decaid GitHub repository](https://github.com/decentespresso/decaid).
