import SwiftUI

/// 合并「实时 IO」与「顺序读写测速」的标签页：上方实时 IO 监控（后台持续采样），
/// 下方测速配置与结果，整页可滚动。两者始终共存于 ContentView 的 ZStack，
/// 切换标签不销毁，IO 历史曲线与测速状态得以保留。
struct PerformanceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                IOView(embedded: true)
                Divider()
                    .padding(.horizontal, 20)
                SpeedTestView(embedded: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
