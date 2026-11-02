import SwiftUI

/// Settings' Sensors row (milestone 12, AC-1): how many sensors are remembered, opening the
/// Sensors screen.
struct SensorsSection: View {
    let store: RememberedSensorStore

    var body: some View {
        Section {
            NavigationLink {
                SensorsScreen()
            } label: {
                LabeledContent {
                    Text(store.isEmpty ? "None" : "\(store.sensors.count)")
                } label: {
                    Label("Sensors", systemImage: "heart.circle")
                }
            }
            .accessibilityIdentifier("settings.sensors")
        } footer: {
            Text("Bluetooth heart rate and cadence sensors used during your rides.")
        }
    }
}

/// The Sensors screen (milestone 12, AC-1 to AC-14): the remembered sensors with live values while
/// the screen is open, forgetting them, adding new ones from a scan, and what to do when Bluetooth
/// is unavailable. Opening it is what first asks for Bluetooth permission (AC-11).
struct SensorsScreen: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var isAdding = false

    var body: some View {
        let store = dependencies.sensorStore
        let hub = dependencies.sensorHub
        List {
            if let message = Self.availabilityMessage(hub.availability) {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                    if hub.availability == .unauthorized {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            }
            ForEach(SensorKind.allCases, id: \.self) { kind in
                let sensors = store.sensors.filter { $0.kind == kind }
                if !sensors.isEmpty {
                    Section(kind.title) {
                        ForEach(sensors) { sensor in
                            RememberedSensorRow(sensor: sensor, hub: hub)
                        }
                        .onDelete { offsets in
                            for index in offsets { store.forget(sensors[index]) }
                            hub.rememberedSensorsChanged()
                        }
                    }
                }
            }
            Section {
                // Plain text: at the largest sizes a list wraps an icon's title around the icon.
                Button("Add Sensor") { isAdding = true }
                    .disabled(hub.availability != .poweredOn)
            } footer: {
                Text(store.isEmpty
                    ? "Pair a heart rate strap or a cadence sensor. During a ride the app uses the first one of each kind it finds."
                    : "During a ride the app uses the first sensor of each kind it finds. Swipe left to forget one.")
            }
        }
        .navigationTitle("Sensors")
        .onAppear { hub.acquire(.screen) }
        .onDisappear { hub.release(.screen) }
        .sheet(isPresented: $isAdding) {
            AddSensorSheet(store: store, hub: hub)
        }
    }

    /// AC-13, AC-14.
    static func availabilityMessage(_ availability: BluetoothAvailability) -> String? {
        switch availability {
        case .unauthorized: "Bluetooth permission is denied. Allow it in Settings to use sensors."
        case .poweredOff: "Bluetooth is off. Turn it on to use sensors."
        case .unsupported: "This device can't use Bluetooth sensors."
        case .poweredOn, .unknown: nil
        }
    }
}

private struct RememberedSensorRow: View {
    let sensor: RememberedSensor
    let hub: SensorHub

    var body: some View {
        LabeledContent {
            Text(valueText)
                .monospacedDigit()
        } label: {
            Text(sensor.displayName)
        }
        .accessibilityIdentifier("sensor.\(sensor.id)")
    }

    /// AC-9: the live value while connected.
    private var valueText: String {
        guard let reading = hub.readings[sensor.identifier] else { return "Not connected" }
        switch sensor.kind {
        case .heartRate: return reading.heartRateBPM.map { "\($0) bpm" } ?? "Connected"
        case .cadence: return reading.cadenceRPM.map { "\($0) rpm" } ?? "Connected"
        }
    }
}

/// AC-3 to AC-5: scans while open and remembers the device the rider picks.
private struct AddSensorSheet: View {
    let store: RememberedSensorStore
    let hub: SensorHub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(newDevices) { device in
                        Button {
                            store.remember(device)
                            hub.rememberedSensorsChanged()
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name ?? kindsText(device))
                                Text(kindsText(device))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text("Nearby")
                        ProgressView()
                    }
                } footer: {
                    Text("Wake the sensor up: put the strap on, or turn the crank a few times.")
                }
            }
            .navigationTitle("Add Sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { hub.startScan() }
        .onDisappear { hub.stopScan() }
    }

    /// Devices not yet remembered for every kind they offer.
    private var newDevices: [DiscoveredDevice] {
        hub.discovered.filter { !$0.kinds.isSubset(of: store.kinds(for: $0.identifier)) }
    }

    private func kindsText(_ device: DiscoveredDevice) -> String {
        SensorKind.allCases.filter { device.kinds.contains($0) }.map(\.title).joined(separator: " and ")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        SensorsScreen()
    }
    .environment(AppDependencies.preview)
}
#endif
