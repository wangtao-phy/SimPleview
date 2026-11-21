import SwiftUI

/// 工具栏色板由各窗口共享。只有选中色块时才更新当前文档的工具颜色。
struct AnnotationPaletteButton: View {
    @ObservedObject var state: AppState
    // 保留系统预设的名称以适应外观；自选色存为 sRGB 十六进制。空字符串表示主动清空。
    @AppStorage("annotationToolbarPalette") private var storedColors = "Blue,Red,Yellow,Green,Purple"
    @State private var isShowingPalette = false
    @State private var isAddingColor = false
    @State private var draftColor = Color.clear
    @State private var hoveredColor: String?
    @State private var removableColor: String?
    @GestureState private var drag: SwatchDrag?
    @Namespace private var paletteViewport

    private struct Swatch: Identifiable {
        let id: String
        let color: NSColor
    }

    private struct SwatchDrag {
        let colorID: String
        let location: CGPoint
        let target: String?
    }

    private let cellSize: CGFloat = 34
    private let cellSpacing: CGFloat = 4

    private var colorIDs: [String] {
        // 色块 ID 同时用于排序。读取旧偏好时保留首次出现的位置，避免重复 ID。
        var seen = Set<Substring>()
        return storedColors.split(separator: ",").filter { seen.insert($0).inserted }.map(String.init)
    }

    var body: some View {
        Button {
            isShowingPalette.toggle()
        } label: {
            HStack(spacing: 4) {
                colorDot(state.currentColor, size: 16)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .frame(minWidth: 32, minHeight: 22)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(state.L("Color"))
        .help(state.L("Color"))
        .popover(isPresented: $isShowingPalette, arrowEdge: .bottom) {
            VStack {
                if isAddingColor { colorEditor } else { palette }
            }
            .padding(10)
            .onDisappear {
                isAddingColor = false
                hoveredColor = nil
                removableColor = nil
            }
        }
    }

    private var palette: some View {
        let colors = colorIDs.compactMap { id in color(for: id).map { Swatch(id: id, color: $0) } }
        let selected = colorCode(state.currentColor)
        let shownColumns = min(colors.count, 5)
        let rows = (colors.count + 4) / 5
        let pitch = cellSize + cellSpacing
        let viewport = CGSize(width: CGFloat(shownColumns) * pitch - cellSpacing,
                              height: CGFloat(min(rows, 3)) * pitch - cellSpacing)
        let grid = CGRect(x: 0, y: 0, width: viewport.width, height: CGFloat(rows) * pitch - cellSpacing)

        func colorAt(_ location: CGPoint, in viewportLocation: CGPoint) -> String? {
            guard CGRect(origin: .zero, size: viewport).contains(viewportLocation), grid.contains(location) else { return nil }
            let row = Int(location.y / pitch)
            let column = Int(location.x / pitch)
            let index = row * shownColumns + column
            return colors.indices.contains(index) ? colors[index].id : nil
        }

        func origin(of index: Int) -> CGPoint {
            CGPoint(x: CGFloat(index % shownColumns) * pitch, y: CGFloat(index / shownColumns) * pitch)
        }
        let source = colors.firstIndex { $0.id == drag?.colorID }
        let target = colors.firstIndex { $0.id == drag?.target }
        let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: shownColumns)
        return HStack(alignment: .top, spacing: cellSpacing) {
            if !colors.isEmpty {
                ScrollView {
                    if #available(macOS 27, *) {
                        LazyVGrid(columns: columns, spacing: cellSpacing) {
                            ForEach(colors) { item in
                                swatch(item, isSelected: selected == colorCode(item.color))
                            }
                            .reorderable()
                        }
                        .reorderContainer(for: Swatch.self) { change in
                            let before: String?
                            switch change.destination.position {
                            case .before(let id): before = id
                            case .end: before = nil
                            }
                            saveOrder(moving: change.sources, before: before)
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: cellSpacing) {
                            ForEach(Array(colors.enumerated()), id: \.element.id) { index, item in
                                let start = origin(of: index)
                                let preview = origin(of: previewIndex(for: index, from: source, to: target))
                                let offset = CGSize(width: preview.x - start.x, height: preview.y - start.y)
                                swatch(item, isSelected: selected == colorCode(item.color))
                                    .opacity(source == index ? 0 : 1)
                                    .offset(offset)
                                    .animation(.snappy, value: offset)
                                    .gesture(reorderGesture(item.id, from: start, colorAt: colorAt))
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: viewport.width, height: viewport.height)
                .coordinateSpace(.named(paletteViewport))
                .overlay(alignment: .topLeading) {
                    if let drag, target != nil, let color = color(for: drag.colorID) {
                        colorDot(color, size: 24)
                            .shadow(radius: 2)
                            .position(drag.location)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            Button {
                draftColor = Color(nsColor: state.currentColor)
                hoveredColor = nil
                isAddingColor = true
            } label: {
                Image(systemName: "plus.circle").font(.system(size: 24))
                    .frame(width: cellSize, height: cellSize)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(state.L("Add Color"))
            .help(state.L("Add Color"))
        }
        .buttonStyle(.plain)
        .task(id: hoveredColor) {
            removableColor = nil
            guard let hoveredColor else { return }
            // 指针离开色块或收起色板会取消等待，避免减号出现在旧位置。
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, self.hoveredColor == hoveredColor else { return }
            removableColor = hoveredColor
        }
    }

    private func swatch(_ item: Swatch, isSelected: Bool) -> some View {
        let id = item.id
        let name = id.hasPrefix("#") ? id : state.L(id)
        let removeLabel = state.L("Remove Color")

        return ZStack(alignment: .topTrailing) {
            Button {
                state.currentColor = item.color
                isShowingPalette = false
            } label: {
                colorDot(item.color, size: 24)
                    .padding(3)
                    .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
                    .frame(width: cellSize, height: cellSize)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(name)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: Text(removeLabel)) { remove(id) }

            if hoveredColor == id, removableColor == id {
                Button { remove(id) } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white, .red)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(removeLabel) \(name)")
            }
        }
        .onHover { inside in
            if inside, drag == nil { hoveredColor = id } else if hoveredColor == id { hoveredColor = nil }
        }
    }

    /// macOS 26 的网格还没有原生排序。只移动视图的显示位置，松手前保留原顺序。
    private func previewIndex(for index: Int, from source: Int?, to target: Int?) -> Int {
        guard let source, let target else { return index }
        if source < index && index <= target { return index - 1 }
        if target <= index && index < source { return index + 1 }
        return index
    }

    private func reorderGesture(_ id: String, from origin: CGPoint,
                                colorAt: @escaping (CGPoint, CGPoint) -> String?) -> some Gesture {
        // 起点色块的本地坐标不受滚动偏移影响，可见区域的坐标则用于判断是否取消。
        let gesture = DragGesture(minimumDistance: 5)
            .simultaneously(with: DragGesture(minimumDistance: 5, coordinateSpace: .named(paletteViewport)))
        func preview(_ value: SimultaneousGesture<DragGesture, DragGesture>.Value) -> SwatchDrag? {
            guard let local = value.first?.location, let visible = value.second?.location else { return nil }
            let position = CGPoint(x: origin.x + local.x, y: origin.y + local.y)
            return SwatchDrag(colorID: id, location: visible, target: colorAt(position, visible))
        }
        return gesture.updating($drag) { value, drag, _ in drag = preview(value) }
            .onChanged { _ in hoveredColor = nil }
            .onEnded { value in
                if let target = preview(value)?.target { moveColor(id, to: target) }
            }
    }

    private var colorEditor: some View {
        let code = colorCode(NSColor(draftColor))
        let canAdd = code.map { candidate in
            !colorIDs.contains { color(for: $0).flatMap(colorCode) == candidate }
        } ?? false
        return VStack(spacing: 12) {
            ColorPicker(state.L("Color"), selection: $draftColor, supportsOpacity: false)
            HStack {
                Button(state.L("Cancel")) { isAddingColor = false }
                Button(state.L("Add Color")) {
                    let ids = colorIDs
                    guard let code, canAdd, !ids.contains(code) else { return }
                    storedColors = (ids + [code]).joined(separator: ",")
                    isAddingColor = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(4)
    }

    private func remove(_ id: String) {
        storedColors = colorIDs.filter { $0 != id }.joined(separator: ",")
        hoveredColor = nil
        removableColor = nil
    }

    private func moveColor(_ source: String, to target: String) {
        let ids = colorIDs
        guard let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: target), from != to else { return }
        let insertion = to + (from < to ? 1 : 0)
        withAnimation(.snappy) { saveOrder(moving: [source], before: ids.dropFirst(insertion).first) }
    }

    private func saveOrder(moving sources: [String], before target: String?) {
        let ids = colorIDs
        let moving = Set(sources)
        guard !moving.isEmpty, moving.count == sources.count, moving.isSubset(of: ids) else { return }
        var remaining = ids.filter { !moving.contains($0) }
        if let target {
            guard let index = remaining.firstIndex(of: target) else { return }
            remaining.insert(contentsOf: sources, at: index)
        } else {
            remaining.append(contentsOf: sources)
        }
        if remaining != ids { storedColors = remaining.joined(separator: ",") }
    }

    private func colorDot(_ color: NSColor, size: CGFloat) -> some View {
        Circle().fill(Color(nsColor: color))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.18)))
            .frame(width: size, height: size)
    }

    private func color(for id: String) -> NSColor? {
        switch id {
        case "Blue": .platformBlue
        case "Red": .platformRed
        case "Yellow": .platformYellow
        case "Green": .platformGreen
        case "Purple": .platformPurple
        default: NSColor(hex: id)
        }
    }

    private func colorCode(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return nil }
        let bytes = components.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }
}
