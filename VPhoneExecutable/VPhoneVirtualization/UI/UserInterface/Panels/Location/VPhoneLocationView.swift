//
//  VPhoneLocationView.swift
//  VPhoneVirtualization
//
//  Created by Phineas Guo on 2026/11/07.
//

import AppKit
import MapKit
import SwiftUI

// MARK: - Window

@MainActor
final class VPhoneLocationWindowController: NSWindowController {
    init(onApply: @escaping (Double, Double) -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false,
        )
        panel.title = String(localized: "Custom Location", bundle: VPhoneLocalization.bundle)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentMinSize = NSSize(width: 480, height: 420)
        super.init(window: panel)
        panel.contentView = NSHostingView(rootView: VPhoneLocationView(
            onApply: { [weak self] latitude, longitude in
                onApply(latitude, longitude)
                self?.close()
            },
            onCancel: { [weak self] in self?.close() },
        ))
        panel.center()
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - Location Picker

struct VPhoneLocationView: View {
    let onApply: (Double, Double) -> Void
    let onCancel: () -> Void

    @State private var latitude = ""
    @State private var longitude = ""
    @State private var camera: MapCameraPosition = .automatic

    private var coordinate: CLLocationCoordinate2D? {
        guard let latitude = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let longitude = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Enter coordinates or click the map to select a location.", bundle: VPhoneLocalization.bundle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Latitude", bundle: VPhoneLocalization.bundle)
                    TextField("−90 … 90", text: $latitude)
                        .accessibilityLabel(Text("Latitude", bundle: VPhoneLocalization.bundle))
                }
                VStack(alignment: .leading) {
                    Text("Longitude", bundle: VPhoneLocalization.bundle)
                    TextField("−180 … 180", text: $longitude)
                        .accessibilityLabel(Text("Longitude", bundle: VPhoneLocalization.bundle))
                }
                Button(action: showOnMap) {
                    Text("Show on Map", bundle: VPhoneLocalization.bundle)
                }
                .disabled(coordinate == nil)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(showOnMap)

            MapReader { proxy in
                Map(position: $camera) {
                    if let coordinate {
                        Marker(String(localized: "Custom Location", bundle: VPhoneLocalization.bundle), coordinate: coordinate)
                    }
                }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    latitude = String(format: "%.6f", coordinate.latitude)
                    longitude = String(format: "%.6f", coordinate.longitude)
                }
            }

            HStack {
                Text("Latitude: −90…90. Longitude: −180…180. Use decimal degrees.", bundle: VPhoneLocalization.bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel", bundle: VPhoneLocalization.bundle)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    guard let coordinate else { return }
                    onApply(coordinate.latitude, coordinate.longitude)
                } label: {
                    Text("Apply", bundle: VPhoneLocalization.bundle)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(coordinate == nil)
            }
        }
        .padding(12)
    }

    private func showOnMap() {
        guard let coordinate else { return }
        camera = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05),
        ))
    }
}
