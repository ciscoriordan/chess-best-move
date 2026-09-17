import SwiftUI

/// ThinkTimeControl (design.md section 6): a custom segmented control on a `sunken` track
/// with five segments in the `data` token. The selected segment is `ink` with `canvas`
/// text (never cobalt). At accessibility text sizes it becomes a `Menu` showing the value.
struct ThinkTimeControl: View {
    @Binding var selection: ThinkTime
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                menu
                    .accessibilityLabel("Think time")
                    .accessibilityValue(selection.spokenLabel)
            } else {
                // The group label goes on a container, so each segment keeps its own label
                // ("3 seconds") instead of every segment reading "Think time".
                segments
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Think time")
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(ThinkTime.allCases) { time in
                let isSelected = time == selection
                Button {
                    selection = time
                } label: {
                    Text(time.label)
                        .typography(.data)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Palette.canvas : Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: Layout.chipHeight)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.r2 - 2, style: .continuous)
                                .fill(isSelected ? Palette.ink : Color.clear)
                        )
                        .frame(minHeight: Layout.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityLabel(time.spokenLabel)
            }
        }
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: Radius.r2, style: .continuous)
                .fill(Palette.sunken)
                .frame(height: Layout.chipHeight + 4)
        )
    }

    private var menu: some View {
        Menu {
            Picker("Think time", selection: $selection) {
                ForEach(ThinkTime.allCases) { time in
                    Text(time.label).tag(time)
                }
            }
        } label: {
            HStack(spacing: Spacing.s2) {
                Text(selection.label).typography(.data)
                Image(systemName: "chevron.up.chevron.down")
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Spacing.s3)
            .frame(minHeight: Layout.minimumHitTarget)
            .background(RoundedRectangle(cornerRadius: Radius.r2, style: .continuous).fill(Palette.sunken))
        }
    }
}

private struct ThinkTimeControlPreview: View {
    @State private var time = ThinkTime.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            ThinkTimeControl(selection: $time)
            ThinkTimeControl(selection: $time).environment(\.dynamicTypeSize, .accessibility2)
        }
        .padding(Spacing.s4)
        .background(Palette.canvas)
    }
}

#Preview("Think time") {
    ThinkTimeControlPreview()
}
