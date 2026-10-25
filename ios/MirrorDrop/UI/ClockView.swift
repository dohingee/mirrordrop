import SwiftUI

/// Big running clock for measuring delay: take one photo showing both the phone and the TV,
/// then subtract the two times.
struct ClockView: View {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var body: some View {
        TimelineView(.animation) { context in
            VStack(spacing: 24) {
                Text(Self.formatter.string(from: context.date))
                    .font(.system(size: 56, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                GeometryReader { proxy in
                    let fraction = context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
                    Rectangle()
                        .fill(.orange)
                        .frame(width: 24)
                        .offset(x: (proxy.size.width - 24) * fraction)
                }
                .frame(height: 40)
                Text("화면 공유 중에 이 화면을 켜 두고, iPhone과 TV가 함께 나오게 사진을 찍으세요. 두 시각의 차이가 지연 시간입니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .navigationTitle("지연 측정 시계")
        .navigationBarTitleDisplayMode(.inline)
    }
}
