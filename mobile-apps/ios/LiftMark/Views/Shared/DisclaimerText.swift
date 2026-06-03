import SwiftUI

struct DisclaimerText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            disclaimerSection(
                title: "Tracking Only",
                body: "lift.md is a workout tracking tool. It does not provide exercise instruction, "
                    + "form guidance, coaching, or medical advice. You are solely responsible for "
                    + "knowing how to safely perform any exercises you track."
            )

            disclaimerSection(
                title: "Assumption of Risk",
                body: "Strength training and physical exercise carry inherent risks including "
                    + "injury, disability, and in rare cases death. By using this app, you "
                    + "acknowledge these risks and accept full responsibility for your "
                    + "physical safety during workouts."
            )

            disclaimerSection(
                title: "Younger Users",
                body: "If you are under 18, we recommend working with a parent, guardian, or qualified fitness professional when performing strength training exercises."
            )
        }
    }

    private func disclaimerSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.lmSubheadline.weight(.semibold))
            Text(body)
                .font(.lmCaption)
                .foregroundStyle(.secondary)
        }
    }
}
