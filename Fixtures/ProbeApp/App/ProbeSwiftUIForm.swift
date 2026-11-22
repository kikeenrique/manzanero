import SwiftUI
import UIKit

/// The SwiftUI form probe (docs/probe-app.md#swiftui-form-probe): shown
/// instead of the touch surface when the app is launched with
/// `-ProbeSwiftUI YES`. A SwiftUI `TextField` with a label and an identifier,
/// and a text that shows the value bound to it, so `set-value` and `type`
/// can be checked against what the app's own state received.
enum ProbeSwiftUIForm {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ProbeSwiftUI") }
    static let fieldIdentifier = "probe.swiftui.field"
    static let boundIdentifier = "probe.swiftui.bound"
    static let changesIdentifier = "probe.swiftui.changes"

    @MainActor static func controller() -> UIViewController { UIHostingController(rootView: FormView()) }

    struct FormView: View {
        @State private var text = ""
        @State private var changes = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("SwiftUI form probe").font(.headline)
                TextField("Name", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Probe name")
                    .accessibilityIdentifier(ProbeSwiftUIForm.fieldIdentifier)
                // The bound value as the app holds it, quoted so an empty or
                // spaced value can be told apart.
                Text("Bound: \"\(text)\"")
                    .accessibilityIdentifier(ProbeSwiftUIForm.boundIdentifier)
                    .accessibilityValue(text)
                Text("Changes: \(changes)")
                    .accessibilityIdentifier(ProbeSwiftUIForm.changesIdentifier)
                    .accessibilityValue(String(changes))
                Spacer()
            }
            .padding(24)
            .onChange(of: text) { changes += 1 }
        }
    }
}
