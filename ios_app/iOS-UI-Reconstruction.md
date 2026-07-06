# iOS UI Reconstruction Plan

**Goal:** Transform iOS app from basic tab-based lists to modern card-based design matching reference screenshot.

**Reference:** Samsung Wearable app (Galaxy Watch7 interface)

---

## Current State vs Target

### Current (Basic)
- TabView with 5 tabs
- Plain List rows
- No device card
- No visual hierarchy
- No settings screens

### Target (Modern Card-Based)
- Single main screen with device card
- Sectioned settings (General, Notifications, Health)
- Toggle switches with proper styling
- Device details screen with info table
- Music control options screen
- Clean, spacious layout

---

## New File Structure

```
ios_app/WearLink/
├── Views/
│   ├── Main/
│   │   ├── DevicesListView.swift       # Main screen with device cards
│   │   └── DeviceCardView.swift        # Reusable device card component
│   ├── DeviceDetails/
│   │   ├── DeviceDetailsView.swift     # Device details + settings
│   │   ├── DeviceInfoSection.swift     # Device info table
│   │   ├── GeneralSettingsSection.swift # Auto-connect, Analytics toggles
│   │   ├── NotificationSettingsSection.swift # Notification toggles
│   │   └── HealthSettingsSection.swift # Health data toggle
│   ├── Music/
│   │   ├── MusicControlOptionsView.swift # Music settings screen
│   │   └── MusicControlView.swift      # Now-playing with controls
│   └── Common/
│       ├── ToggleRow.swift             # Reusable toggle row component
│       ├── SectionHeader.swift         # Section header styling
│       └── DeviceIconView.swift        # Circular device icon
```

---

## Screen-by-Screen Plan

### 1. DevicesListView (Main Screen)
**Replaces:** ConnectionView + RootView tab structure

**Layout:**
- Navigation bar: "Devices" + settings gear icon
- Device card list (one card per paired watch)
  - Circular device icon (blue gradient)
  - Device name (e.g., "Galaxy Watch7 (A64Y)")
  - Android version
  - Battery level with icon + percentage
  - Connection status dot (green = connected)
- Bottom banner: "Health data sync completed"
- Footer tip card: "Follow these steps to set up..."

**Data from:** `BLEManager.state`, custom device info model

---

### 2. DeviceDetailsView
**Layout:**
- Back button: "Devices"
- Title: "Device Details"
- Large circular device icon (centered, blue gradient)
- Device name (large, bold)
- Connection status pill (green "Connected")

**Sections:**

**GENERAL**
- Auto-connect → ToggleRow
- Analytics → ToggleRow

**NOTIFICATIONS**
- Enable Notifications → ToggleRow
- Bidirectional Sync → ToggleRow (with info icon)
- App Notifications → NavigationLink (opens app picker)
- Notification History → NavigationLink

**HEALTH**
- Collect Health Data → ToggleRow

**FIND DEVICE**
- Find Device button (bell icon, blue)
- Description text

**DEVICE MANAGEMENT**
- Forget Device → Destructive button (red)

---

### 3. DeviceInfoSection (Sub-screen)
**Layout:**
- Table-style rows with labels + values
- Device Name, Device ID, Product Name, Model Name
- Android Version, App Version, Manufacturer
- Battery Level, Is Charging

**Data from:** Custom device info model (populated via BLE)

---

### 4. MusicControlOptionsView
**Layout:**
- Back button: "Back"
- Title: "Music Control Options"

**Sections:**

**BACKGROUND COLOR**
- Background Color → Picker (RANDOM + color options)
- Description text

**DISPLAY OPTIONS**
- Show Album Art → ToggleRow
- Description text
- Watch Face Always On → ToggleRow
- Description text

**Footer:** "Retrieved 0 health records"

---

## Component Library

### ToggleRow
```swift
struct ToggleRow: View {
    let title: String
    let subtitle: String?
    let icon: Image?
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            icon // Optional icon
            VStack(alignment: .leading) {
                Text(title)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.green) // Samsung-style green
        }
    }
}
```

### DeviceCardView
```swift
struct DeviceCardView: View {
    let deviceName: String
    let deviceVersion: String
    let batteryLevel: Int
    let isConnected: Bool
    
    var body: some View {
        HStack {
            DeviceIconView() // Circular gradient icon
            VStack(alignment: .leading) {
                Text(deviceName)
                    .font(.headline)
                Text(deviceVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack {
                Text("\(batteryLevel)%")
                    .font(.caption)
                    .foregroundStyle(batteryLevel > 20 ? .green : .red)
                Image(systemName: "battery.75")
            }
            if isConnected {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8)
    }
}
```

### DeviceIconView
```swift
struct DeviceIconView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [.blue, .cyan]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 60, height: 60)
            Image(systemName: "applewatch")
                .foregroundStyle(.white)
                .font(.title2)
        }
    }
}
```

---

## Color Palette

```swift
// Extension or asset catalog
extension Color {
    static let wearLinkPrimary = Color.blue
    static let wearLinkAccent = Color.cyan
    static let wearLinkToggleOn = Color.green
    static let wearLinkCardBg = Color(.systemBackground)
    static let wearLinkSectionBg = Color(.secondarySystemBackground)
}
```

---

## Migration Steps

1. **Create Views/ directory structure**
2. **Build component library first** (ToggleRow, DeviceCardView, DeviceIconView, SectionHeader)
3. **Implement DevicesListView** (main screen)
4. **Implement DeviceDetailsView** (settings screen)
5. **Implement MusicControlOptionsView**
6. **Update RootView** to use new navigation structure
7. **Deprecate old views** (ConnectionView, CallView, NotificationView, MusicView, HealthView → keep for feature logic, but no longer primary navigation)
8. **Update AppContainer** if needed for new view models
9. **Test on device** for layout + touch targets

---

## Data Model Changes

Need new models for device info:

```swift
struct WearableDevice: Identifiable, Codable {
    let id: String
    var name: String
    var model: String
    var androidVersion: String
    var appVersion: String
    var batteryLevel: Int
    var isCharging: Bool
    var isConnected: Bool
    var lastSeen: Date
}

struct DeviceSettings {
    var autoConnect: Bool = true
    var analytics: Bool = true
    var enableNotifications: Bool = true
    var bidirectionalSync: Bool = false
    var collectHealthData: Bool = true
    var showAlbumArt: Bool = false
    var watchFaceAlwaysOn: Bool = true
}
```

---

## BLE Integration Points

- `BLEManager.state` → connection status
- Need new service to query device info (battery, model, etc.)
- Health data sync status → from `HealthViewModel`

---

## Open Questions

1. **Device pairing flow** — How does user pair new watch? Need "Add Device" button?
2. **Multiple devices** — Support multiple watches or one at a time?
3. **Device info source** — Query via BLE or cache locally?
4. **Settings persistence** — UserDefaults or file-based?

---

## Priority Order

1. **DevicesListView** — Main screen, first impression
2. **ToggleRow + DeviceCardView** — Core components
3. **DeviceDetailsView** — Primary settings screen
4. **MusicControlOptionsView** — Secondary settings
5. **DeviceInfoSection** — Nice-to-have details

---

## Estimated Effort

- Components: 2-3 hours
- DevicesListView: 2 hours
- DeviceDetailsView: 3 hours
- MusicControlOptionsView: 1 hour
- Integration + testing: 2 hours
- **Total: ~10 hours**

---

## Next Actions

1. Create Views/ directory
2. Create ToggleRow.swift
3. Create DeviceCardView.swift
4. Create DeviceIconView.swift
5. Create DevicesListView.swift
6. Update RootView.swift
7. Build + test
