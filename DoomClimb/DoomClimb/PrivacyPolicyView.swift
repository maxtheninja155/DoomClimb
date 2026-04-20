import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Last updated: April 2026")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                policySection(
                    "Data Storage",
                    body: "DoomClimb stores your climb history exclusively on your device using local storage. No climb data, preferences, or personal information is ever transmitted to external servers or third parties."
                )

                policySection(
                    "Bluetooth Usage",
                    body: "DoomClimb uses Bluetooth to communicate directly with your Kilter Board. Bluetooth is used solely to send LED lighting data to your physical board. No Bluetooth data is logged, stored beyond the current session, or shared."
                )

                policySection(
                    "No Analytics or Tracking",
                    body: "DoomClimb does not collect analytics, usage statistics, crash reports, or any form of behavioral data. We do not know how you use the app."
                )

                policySection(
                    "No Account Required",
                    body: "DoomClimb requires no account, login, email address, or personal information of any kind to function."
                )

                policySection(
                    "Third-Party Services",
                    body: "DoomClimb does not integrate with any third-party analytics, advertising networks, data brokers, or cloud services."
                )

                policySection(
                    "Children's Privacy",
                    body: "DoomClimb does not knowingly collect any information from anyone. Since no data is collected at all, the app is safe for users of all ages."
                )

                policySection(
                    "Changes to This Policy",
                    body: "If this privacy policy changes, the updated version will be made available within the app and on the App Store listing."
                )
            }
            .padding(28)
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func policySection(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .bold))
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
    .preferredColorScheme(.dark)
}
