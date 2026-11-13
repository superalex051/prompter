import SwiftUI

/// A one-line notice under the Presenter view's top bar about something that just happened to the screens
/// (`PresentingController.notice`). It goes away by itself.
struct PresenterNoticeBanner: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var identifier = "presenter.notice"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PresenterTheme.accent)
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(PresenterTheme.accent.opacity(0.14))
        .overlay(alignment: .bottom) {
            Rectangle().fill(PresenterTheme.accent.opacity(0.35)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
