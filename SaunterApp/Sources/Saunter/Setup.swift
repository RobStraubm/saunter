import SwiftUI

// MARK: - Einrichtung: Laufband waehlen, Koerperdaten, Buero-Netz, Health-Export

struct SetupInfo: Decodable {
    let done: Bool
    let address: String
    let device_name: String
    let height_cm: Double
    let weight_kg: Double
    let sex: String
    let imessage_target: String
}

struct FoundDevice: Decodable, Identifiable {
    let address: String
    let name: String
    let rssi: Int
    let likely: Bool
    var id: String { address }
}

private struct ScanResponse: Decodable {
    let ok: Bool
    let devices: [FoundDevice]?
    let error: String?
}

extension TreadmillModel {
    /// Sucht Bluetooth-Geraete ueber den Daemon (dauert ca. 8 s). Nur auf Knopfdruck.
    func scanDevices() async throws -> [FoundDevice] {
        var req = URLRequest(url: apiBase.appendingPathComponent("scan"))
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(ScanResponse.self, from: data)
        guard resp.ok else { throw SetupError(message: resp.error ?? "Suche fehlgeschlagen") }
        return resp.devices ?? []
    }
}

struct SetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SetupView: View {
    @ObservedObject var model: TreadmillModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var devices: [FoundDevice] = []
    @State private var scanning = false
    @State private var scanError: String?
    @State private var height: Double = 175
    @State private var weight: Double = 75
    @State private var sex = "male"
    @State private var imessage = ""
    @State private var loaded = false

    private var setup: SetupInfo? { model.status?.setup }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Laufband einrichten").font(.title2.weight(.bold))
                    Text("Alles bleibt auf diesem Mac. Du kannst das jederzeit wieder öffnen.")
                        .font(.callout).foregroundStyle(Palette.ink2)
                }

                if !model.daemonReachable {
                    Label("Der Saunter-Daemon läuft nicht. Ist install.sh durchgelaufen?", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.critical)
                }

                section("1  Laufband", symbol: "figure.walk") { deviceSection }
                section("2  Über dich", symbol: "person") { bodySection }
                section("3  Büro (optional)", symbol: "building.2") {
                    Text("Der Tages-Streak zählt nur Bürotage. Am Büro-Netz erkennt die App, wann du dort warst, und fragt nicht nach.")
                        .font(.caption).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    OfficeNetworkRow()
                        .font(.callout)
                }
                section("4  Apple Health (optional)", symbol: "heart") { healthSection }

                HStack {
                    Spacer()
                    Button("Fertig") { finish() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.daemonReachable)
                }
            }
            .padding(28)
        }
        .frame(width: 520, height: 720)
        .onAppear(perform: load)
        .onChange(of: model.status?.setup?.address) { load() }
    }

    // MARK: Abschnitte

    @ViewBuilder
    private var deviceSection: some View {
        if let setup, !setup.address.isEmpty {
            HStack(spacing: 8) {
                Circle().fill(model.status?.connected == true ? Palette.statusGood : Palette.muted).frame(width: 8, height: 8)
                Text(setup.device_name.isEmpty ? "Laufband gewählt" : setup.device_name).font(.callout.weight(.semibold))
                Text(model.status?.connected == true ? "verbunden" : "nicht verbunden")
                    .font(.caption).foregroundStyle(Palette.ink2)
            }
        }
        Text("Band einschalten und die Hersteller-App (z. B. FitShow) schließen – sonst ist das Band belegt. Ein verbundenes Band taucht in der Suche nicht auf.")
            .font(.caption).foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button {
                Task { await scan() }
            } label: {
                if scanning {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Suche …") }
                } else {
                    Label(devices.isEmpty ? "Laufband suchen" : "Erneut suchen", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            .buttonStyle(.glass)
            .disabled(scanning || !model.daemonReachable)
            if let scanError {
                Text(scanError).font(.caption).foregroundStyle(Palette.critical)
            }
        }
        if !devices.isEmpty {
            VStack(spacing: 0) {
                ForEach(devices) { device in
                    deviceRow(device)
                    if device.id != devices.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 10)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border))
        }
    }

    private func deviceRow(_ device: FoundDevice) -> some View {
        let chosen = setup?.address == device.address
        return HStack(spacing: 10) {
            Image(systemName: "cellularbars", variableValue: signalLevel(device.rssi)).foregroundStyle(Palette.ink2)
                .help("Signal \(device.rssi) dBm")
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.callout)
                if device.likely {
                    Text("wahrscheinlich ein Laufband").font(.caption2).foregroundStyle(Palette.statusGood)
                }
            }
            Spacer()
            if chosen {
                Label("Gewählt", systemImage: "checkmark").font(.caption).foregroundStyle(Palette.ink2)
            } else {
                if device.likely {
                    Button("Auswählen") { choose(device) }.buttonStyle(.glassProminent).controlSize(.small)
                } else {
                    Button("Auswählen") { choose(device) }.buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Für die Schätzung von Schritten und Kalorien.")
                .font(.caption).foregroundStyle(Palette.ink2)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Größe")
                    Stepper(value: $height, in: 100...230, step: 1) {
                        Text("\(Fmt.num(height, 0)) cm").monospacedDigit()
                    }
                }
                GridRow {
                    Text("Gewicht")
                    Stepper(value: $weight, in: 30...250, step: 1) {
                        Text("\(Fmt.num(weight, 0)) kg").monospacedDigit()
                    }
                }
                GridRow {
                    Text("Schrittlänge nach")
                    Picker("", selection: $sex) {
                        Text("Männer-Formel").tag("male")
                        Text("Frauen-Formel").tag("female")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
            .font(.callout)
        }
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nach jedem Training schickt der Mac dir eine iMessage. Eine Kurzbefehl-Automation auf dem iPhone trägt das Training dann in Apple Health ein (Anleitung im README). Leer lassen, wenn du das nicht brauchst.")
                .font(.caption).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Deine iMessage-Adresse oder Nummer", text: $imessage)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Aktionen

    private func load() {
        guard !loaded, let setup else { return }
        loaded = true
        height = setup.height_cm
        weight = setup.weight_kg
        sex = setup.sex
        imessage = setup.imessage_target
    }

    private func scan() async {
        scanning = true
        scanError = nil
        do {
            devices = try await model.scanDevices()
            if devices.isEmpty { scanError = "Nichts gefunden – ist das Band an?" }
        } catch {
            scanError = error.localizedDescription
        }
        scanning = false
    }

    private func finish() {
        Task {
            let ok = await model.send("settings", ["height_cm": height, "weight_kg": weight, "sex": sex,
                                                   "imessage_target": imessage, "setup_done": true])
            if ok { dismissWindow(id: "setup") }
        }
    }

    private func choose(_ device: FoundDevice) {
        model.run("settings", ["address": device.address, "device_name": device.name])
    }

    /// -90 dBm (kaum) bis -50 dBm (direkt daneben) auf 0...1.
    private func signalLevel(_ rssi: Int) -> Double {
        min(1, max(0, Double(rssi + 90) / 40))
    }
}
