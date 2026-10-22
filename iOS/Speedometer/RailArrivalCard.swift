import SwiftUI
#if canImport(SpeedCore)
import SpeedCore
#endif

struct RailArrivalCard: View {
    let candidate: RailArrivalCandidate
    let respond: (String, RailArrivalAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("可能到站了？", systemImage: "tram.fill")
                .font(.headline)
                .foregroundStyle(Palette.measured)
            Text("疑似轨道交通已减速停稳，请帮忙确认。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button { respond(candidate.id, .confirmed) } label: {
                    Text("是，到站了").frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent).tint(Palette.measured).foregroundStyle(.black)
                .accessibilityIdentifier("railArrivalConfirm")
                Button { respond(candidate.id, .denied) } label: {
                    Text("不是").frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered).tint(.white)
                .accessibilityIdentifier("railArrivalDeny")
            }
        }
        .padding(16)
        .background(Palette.bottom, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.measured.opacity(0.35)))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .accessibilityIdentifier("railArrivalCard")
    }
}
