import SwiftUI
import VisionKit

/// Pairing with the Mac: scan the code in RealBook's "Listen on iPhone" tab, or paste its link.
struct PairView: View {
    let paired: (Pairing) -> Void
    @State private var link = ""
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("On your Mac, open RealBook → Listen on iPhone, turn it on, and point the camera at the code.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner { text in use(text) }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxHeight: 360)
                } else {
                    Text("This iPhone can't scan codes here; paste the link from your Mac instead.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Or paste the link", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Pair") { use(link) }.disabled(link.isEmpty)
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                Spacer()
            }
            .padding()
            .navigationTitle("Pair with Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }

    private func use(_ text: String) {
        if let p = Pairing(link: text) {
            paired(p)
        } else {
            problem = "That isn't a RealBook code. Use the one in the Listen on iPhone tab on your Mac."
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let text = code.payloadStringValue, Pairing(link: text) != nil else { continue }
                done = true
                scanner.stopScanning()
                found(text)
            }
        }
    }
}
