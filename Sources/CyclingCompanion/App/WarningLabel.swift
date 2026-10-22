import SwiftUI

/// A warning: orange icon, primary-coloured text. Orange text on a light background fails the
/// contrast audit (milestone 7, RULE-28), so only the icon carries the colour.
struct WarningLabel: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"

    init(_ text: String, systemImage: String = "exclamationmark.triangle.fill") {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
        }
    }
}
