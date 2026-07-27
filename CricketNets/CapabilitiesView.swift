import SwiftUI

/// Reports what this phone can actually deliver, and what that means for tracking a hard shot.
///
/// The point is the bottom table. A 160 km/h shot crosses the view in under a tenth of a second, so
/// the frame rate decides whether there are enough sightings to fit a launch vector at all — not
/// whether the tracking is clever.
struct CapabilitiesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report = CaptureCapabilities.Report()
    @State private var standoff: Double = 3.5

    /// Typical ARKit wide-camera geometry, used for the frame estimates.
    private let focal = 1500.0
    private let imageWidth = 1920.0
    private let imageHeight = 1440.0

    private var portraitFOV: Double {
        CaptureCapabilities.horizontalFOVDegrees(focalLengthPx: focal, imageWidth: imageWidth,
                                                 imageHeight: imageHeight, portrait: true)
    }
    private var landscapeFOV: Double {
        CaptureCapabilities.horizontalFOVDegrees(focalLengthPx: focal, imageWidth: imageWidth,
                                                 imageHeight: imageHeight, portrait: false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    verdict
                    pipeline("ARKit (what we use now)", report.arKitFormats,
                             note: report.arKitSupportsSceneDepth
                                 ? "Scene depth supported. Gives camera pose for free."
                                 : "No scene depth on this device.")
                    pipeline("AVFoundation LiDAR camera", report.lidarCameraFormats,
                             note: report.hasLiDARCamera
                                 ? "Depth-capable formats. No camera pose — fine on a tripod."
                                 : "No LiDAR depth camera found.")
                    frameBudget
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Device limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { report = CaptureCapabilities.probe() }
    }

    private var verdict: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FASTEST DEPTH CAPTURE").font(.caption2.bold()).tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                stat("\(Int(report.bestARKitFPS))", "ARKit fps", .cyan)
                stat("\(Int(report.bestLiDARCameraFPS))", "AVFoundation fps",
                     report.fasterPathExists ? .green : .white)
            }
            Text(report.fasterPathExists
                 ? "AVFoundation offers a faster depth-capable format than ARKit. Worth moving the depth path onto it — camera pose is the only thing lost, and a tripod doesn't need it."
                 : "No faster depth path available. ARKit's ceiling is the device's ceiling, so more frames have to come from standing further back or holding the phone landscape.")
                .font(.caption)
                .foregroundStyle(report.fasterPathExists ? .green : .orange)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func stat(_ value: String, _ label: String, _ accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(accent).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func pipeline(_ title: String, _ options: [CaptureCapabilities.VideoOption],
                          note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.bold()).tracking(0.8)
                .foregroundStyle(.secondary)
            Text(note).font(.caption2).foregroundStyle(.white.opacity(0.6))
            if options.isEmpty {
                Text("none").font(.caption).foregroundStyle(.orange)
            } else {
                ForEach(options.prefix(8)) { option in
                    HStack {
                        Text(option.label).font(.caption.monospacedDigit())
                        Spacer()
                        if option.fps >= 100 {
                            Text("fast").font(.caption2.bold()).foregroundStyle(.green)
                        }
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    /// The number that actually matters: sightings available for a hard shot.
    private var frameBudget: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FRAMES PER SHOT").font(.caption2.bold()).tracking(0.8)
                .foregroundStyle(.secondary)
            Text("A launch vector needs at least 3 sightings, and some frames won't resolve. Below about 5 the hardest shots start being missed entirely.")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))

            HStack {
                Text("Phone distance").font(.caption).foregroundStyle(.white.opacity(0.85))
                Slider(value: $standoff, in: 1.5...5, step: 0.5).tint(.cyan)
                Text(String(format: "%.1f m", standoff))
                    .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    .frame(width: 48, alignment: .trailing)
            }

            grid
            Text("Portrait sees \(Int(portraitFOV))° across; landscape sees \(Int(landscapeFOV))°. The app is portrait-locked, which costs about a quarter of the frames.")
                .font(.system(size: 9)).foregroundStyle(.orange.opacity(0.9))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var grid: some View {
        let rates = [30.0, 60.0, max(90, report.bestLiDARCameraFPS)].filter { $0 > 0 }
        return VStack(spacing: 4) {
            HStack {
                Text("shot").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                ForEach(rates, id: \.self) { r in
                    Text("\(Int(r))fps").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach([120.0, 145.0, 160.0], id: \.self) { kmh in
                HStack {
                    Text("\(Int(kmh)) km/h").font(.caption.monospacedDigit())
                        .foregroundStyle(.white).frame(width: 70, alignment: .leading)
                    ForEach(rates, id: \.self) { r in
                        let f = CaptureCapabilities.expectedFrames(
                            speedKmh: kmh, distance: standoff, fps: r,
                            horizontalFOVDegrees: portraitFOV)
                        Text(String(format: "%.1f", f))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(f >= 5 ? .green : (f >= 3 ? .orange : .red))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
