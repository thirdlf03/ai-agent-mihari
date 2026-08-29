import SwiftUI

/// アプリのルート。今は権限オンボーディングだけを出す。
public struct RootView: View {
    @StateObject private var permissions = PermissionsModel()

    public init() {}

    public var body: some View {
        OnboardingView(model: permissions)
    }
}
