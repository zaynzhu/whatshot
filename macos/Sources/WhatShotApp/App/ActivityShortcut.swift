import SwiftUI

/// 页头动态入口，数字按作品去重；选中状态同时用文字、描边和颜色表达。
struct ActivityShortcut: View {
  let title: String
  let count: Int
  let icon: String
  var selected = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: icon).font(.system(size: 13))
        Text(title).font(.system(size: 11, weight: .semibold))
        Text("\(count)").font(.system(size: 18, weight: .bold).monospacedDigit())
      }
      .foregroundStyle(selected ? Theme.bg : (count > 0 ? Theme.accent : Theme.textSecondary))
      .padding(.horizontal, 14).padding(.vertical, 10)
      .background(selected ? Theme.accent : Theme.elevated, in: RoundedRectangle(cornerRadius: 9))
      .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title)，\(count) 部")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
