import SwiftUI

/// Bidirectional Side Navigation — supports both LTR and RTL layouts.
///
/// Reads `layoutDirection` from the SwiftUI environment and adapts automatically:
/// - LTR: drawer slides in from the LEFT edge
/// - RTL: drawer slides in from the RIGHT edge
///
/// All offset and gesture math is normalised using a `dir` multiplier:
///   dir = -1  (LTR) → negative x hides drawer off-screen left
///   dir = +1  (RTL) → positive x hides drawer off-screen right
///
/// slideOffset = 0                → drawer fully visible at its edge
/// slideOffset = drawerWidth * dir → drawer fully hidden off-screen
struct NativeSideNavigation<Content: View>: View {
    @ObservedObject var uiState = NativeUIState.shared
    private var isRTL: Bool { UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft }
    @State private var expandedGroups: Set<String> = []
    @State private var dragOffset: CGFloat = 0

    let content: Content
    let onNavigate: (String) -> Void

    private let drawerWidthRatio: CGFloat = 0.85
    private let edgeSwipeThreshold: CGFloat = 30

    /// +1 for RTL (drawer on right), -1 for LTR (drawer on left).
    /// Multiplying any offset or velocity by this normalises direction math.
    private var dir: CGFloat { isRTL ? 1 : -1 }

    /// The physical edge the drawer appears on.
    private var drawerEdge: Edge { isRTL ? .trailing : .leading }

    /// Safe area inset on the drawer's side.
    private func safeInset(_ geometry: GeometryProxy) -> CGFloat {
        isRTL
        ? geometry.safeAreaInsets.trailing
        : geometry.safeAreaInsets.leading
    }

    init(onNavigate: @escaping (String) -> Void, @ViewBuilder content: () -> Content) {
        self.onNavigate = onNavigate
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let drawerWidth = geometry.size.width * (isLandscape ? 0.4 : drawerWidthRatio)
            let safeArea = safeInset(geometry)

            // Hidden offset: moves drawer fully off-screen on its side.
            // dir * (drawerWidth + safeArea + 10)
            //   LTR → negative x → off-screen LEFT
            //   RTL → positive x → off-screen RIGHT
            let hiddenOffset = dir * (drawerWidth + safeArea + 10)

            // Current drawer x position:
            //   open:   0           (drawer at edge, fully visible)
            //   closed: hiddenOffset (drawer off-screen)
            let drawerXOffset: CGFloat = {
                let base: CGFloat = uiState.shouldPresentSidebar ? 0 : hiddenOffset
                return base + dragOffset
            }()

            // Overlay opacity: 0 when hidden, 0.5 when fully open
            let overlayOpacity: Double = {
                let progress = 1 - abs(drawerXOffset) / drawerWidth
                return Double(max(0, min(0.5, progress * 0.5)))
            }()

            // Swipe inward from the drawer's edge to open.
            // Inward direction = opposite of dir:
            //   LTR: swipe right (+) from left edge
            //   RTL: swipe left  (-) from right edge
            let edgeSwipeGesture = DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Must start from the correct physical edge
                let atEdge = isRTL
                ? value.startLocation.x > geometry.size.width - edgeSwipeThreshold
                : value.startLocation.x < edgeSwipeThreshold

                guard atEdge else { return }

                // Normalised translation: negative = inward (opening)
                let norm = dir * value.translation.width
                guard norm < 0 else { return }

                // dragOffset mirrors the normalised translation back to screen coords
                // and clamps so drawer can't go past fully open
                dragOffset = max(norm, -abs(hiddenOffset)) * dir
            }
            .onEnded { value in
                let normTranslation = dir * value.translation.width
                let normVelocity = dir * (value.predictedEndTranslation.width - value.translation.width)

                if abs(normTranslation) > drawerWidth * 0.3 || normVelocity < -300 {
                    open()
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { dragOffset = 0 }
                }
            }

            // Swipe outward on drawer or overlay to close.
            // Outward direction = same as dir:
            //   LTR: swipe left  (-) → close
            //   RTL: swipe right (+) → close
            let closeDragGesture = DragGesture()
            .onChanged { value in
                // Normalised translation: positive = outward (closing)
                let norm = dir * value.translation.width
                guard norm > 0 else { return }
                dragOffset = min(norm, abs(hiddenOffset)) * dir
            }
            .onEnded { value in
                let normTranslation = dir * value.translation.width
                let normVelocity = dir * (value.predictedEndTranslation.width - value.translation.width)

                if normTranslation > drawerWidth * 0.3 || normVelocity > 300 {
                    close()
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { dragOffset = 0 }
                }
            }

            ZStack(alignment: isRTL ? .trailing : .leading) {
                // ── Main content ──────────────────────────────────────────────
                content
                .zIndex(0)
                .disabled(uiState.shouldPresentSidebar)

                // ── Dim overlay ───────────────────────────────────────────────
                if uiState.shouldPresentSidebar || dragOffset != 0 {
                    Color.black
                    .opacity(overlayOpacity)
                    .ignoresSafeArea()
                    .zIndex(1)
                    .onTapGesture { close() }
                    .gesture(closeDragGesture)
                    .transition(.opacity)
                }

                // ── Side drawer ───────────────────────────────────────────────
                if uiState.hasSideNav() {
                    drawerContent
                    .frame(width: drawerWidth)
                    .background(Color(.systemBackground))
                    .offset(x: drawerXOffset)
                    .zIndex(2)
                    .gesture(closeDragGesture)
                    .onAppear {
                        let side = isRTL ? "RIGHT (RTL)" : "LEFT (LTR)"
                        print("📱 NativeSideNavigation: drawer on \(side) edge")
                        if let children = uiState.sideNavData?.children {
                            for child in children where child.type == "side_nav_group" {
                                if case .group(let group) = child.data,
                                group.expanded == true {
                                    expandedGroups.insert(group.heading)
                                }
                            }
                        }
                    }
                }

                // ── Invisible edge detector for swipe-to-open ────────────────
                if uiState.hasSideNav() && !uiState.shouldPresentSidebar {
                    Color.clear
                    .frame(width: edgeSwipeThreshold)
                    .contentShape(Rectangle())
                    .gesture(edgeSwipeGesture)
                    .ignoresSafeArea(edges: isRTL ? .trailing : .leading)
                    .zIndex(3)
                }
            }
            .onChange(of: uiState.shouldPresentSidebar) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.3)) { dragOffset = 0 }
                }
            }
        }
    }

    // MARK: - Actions

    private func open() {
        withAnimation(.easeOut(duration: 0.25)) {
            uiState.openSidebar()
            dragOffset = 0
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.25)) {
            uiState.closeSidebar()
            dragOffset = 0
        }
    }

    // MARK: - Drawer Content

    @ViewBuilder
    private var drawerContent: some View {
        if let sideNavData = uiState.sideNavData,
        let children = sideNavData.children {
            let pinnedHeaders = children.filter { child in
                if child.type == "side_nav_header",
                case .header(let header) = child.data {
                    return header.pinned == true
                }
                return false
            }
            let scrollableChildren = children.filter { child in
                if child.type == "side_nav_header",
                case .header(let header) = child.data {
                    return header.pinned != true
                }
                return true
            }

            VStack(spacing: 0) {
                ForEach(Array(pinnedHeaders.enumerated()), id: \.offset) { _, child in
                    sideNavChild(child: child)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(scrollableChildren.enumerated()), id: \.offset) { _, child in
                            sideNavChild(child: child)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func sideNavChild(child: SideNavChild) -> some View {
        switch child.type {
        case "side_nav_header":
            if case .header(let header) = child.data {
                SideNavHeaderView(header: header)
            }
        case "side_nav_item":
            if case .item(let item) = child.data {
                SideNavItemView(
                    item: item,
                    labelVisibility: uiState.sideNavData?.labelVisibility,
                    onNavigate: { url in
                        onNavigate(url)
                        withAnimation(.easeInOut(duration: 0.3)) { uiState.closeSidebar() }
                    }
                )
            }
        case "side_nav_group":
            if case .group(let group) = child.data {
                SideNavGroupView(
                    group: group,
                    isExpanded: expandedGroups.contains(group.heading),
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedGroups.contains(group.heading) {
                                expandedGroups.remove(group.heading)
                            } else {
                                expandedGroups.insert(group.heading)
                            }
                        }
                    },
                    labelVisibility: uiState.sideNavData?.labelVisibility,
                    onNavigate: { url in
                        onNavigate(url)
                        withAnimation(.easeInOut(duration: 0.3)) { uiState.closeSidebar() }
                    }
                )
            }
        case "horizontal_divider":
            Divider().padding(.vertical, 8)
        default:
            EmptyView()
        }
    }
}

// MARK: - SideNavHeaderView

struct SideNavHeaderView: View {
    let header: SideNavHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                if let iconName = header.icon {
                    Image(systemName: getIconForName(iconName))
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let title = header.title {
                        Text(title).font(.headline)
                    }
                    if let subtitle = header.subtitle {
                        Text(subtitle).font(.subheadline).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(16)
        }
        .background(parseBackgroundColor(header.backgroundColor))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func parseBackgroundColor(_ colorString: String?) -> Color {
        guard let colorString = colorString else { return Color(.systemGray6) }
        let hex = colorString.replacingOccurrences(of: "#", with: "")
        guard hex.count == 6 || hex.count == 8 else { return Color(.systemGray6) }
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        return Color(
            red:   Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8)  & 0xFF) / 255.0,
            blue:  Double(rgb & 0xFF)          / 255.0
        )
    }
}

// MARK: - SideNavItemView

struct SideNavItemView: View {
    let item: SideNavItem
    let labelVisibility: String?
    let onNavigate: (String) -> Void
    var leadingIndent: CGFloat = 0

    var body: some View {
        Button(action: {
            print("🖱️ Side nav item clicked: \(item.label) -> \(item.url)")
            handleNavigation()
        }) {
            HStack(spacing: 16) {
                Image(systemName: getIconForName(item.icon))
                .font(.system(size: 20))
                .foregroundColor(item.active == true ? .accentColor : .primary)
                .frame(width: 24)

                if shouldShowLabel() {
                    Text(item.label)
                    .foregroundColor(item.active == true ? .accentColor : .primary)
                }

                Spacer()

                if let badge = item.badge {
                    Text(badge)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(parseBadgeColor(item.badgeColor))
                    .cornerRadius(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16 + leadingIndent)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(item.active == true ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func shouldShowLabel() -> Bool {
        switch labelVisibility {
        case "unlabeled": return false
        case "selected":  return item.active == true
        default:          return true
        }
    }

    private func handleNavigation() {
        if item.openInBrowser == true || isExternalUrl(item.url) {
            print("🌐 Opening external URL: \(item.url)")
            if let url = URL(string: item.url) { UIApplication.shared.open(url) }
        } else {
            print("📱 Opening internal URL: \(item.url)")
            onNavigate(item.url)
        }
    }

    private func isExternalUrl(_ url: String) -> Bool {
        (url.hasPrefix("http://") || url.hasPrefix("https://"))
        && !url.contains("127.0.0.1")
        && !url.contains("localhost")
    }

    private func parseBadgeColor(_ colorString: String?) -> Color {
        switch colorString?.lowercased() {
        case "lime":   return Color(red: 0.52, green: 0.80, blue: 0.09)
        case "green":  return Color(red: 0.13, green: 0.77, blue: 0.37)
        case "blue":   return Color(red: 0.23, green: 0.51, blue: 0.96)
        case "red":    return Color(red: 0.94, green: 0.27, blue: 0.27)
        case "yellow": return Color(red: 0.92, green: 0.70, blue: 0.03)
        case "purple": return Color(red: 0.66, green: 0.33, blue: 0.97)
        case "pink":   return Color(red: 0.93, green: 0.28, blue: 0.60)
        case "orange": return Color(red: 0.98, green: 0.45, blue: 0.09)
        default:       return Color(red: 0.39, green: 0.40, blue: 0.95)
        }
    }
}

// MARK: - SideNavGroupView

struct SideNavGroupView: View {
    let group: SideNavGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    let labelVisibility: String?
    let onNavigate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 16) {
                    if let iconName = group.icon {
                        Image(systemName: getIconForName(iconName))
                        .font(.system(size: 20))
                        .frame(width: 24)
                    }
                    Text(group.heading).fontWeight(.medium)
                    Spacer()
                    // chevron.forward auto-mirrors with layoutDirection:
                    // LTR → points right, RTL → points left
                    Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if isExpanded, let children = group.children {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        if let item = child.data {
                            SideNavItemView(
                                item: item,
                                labelVisibility: labelVisibility,
                                onNavigate: onNavigate,
                                leadingIndent: 24
                            )
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal:   .move(edge: .top).combined(with: .opacity)
                            ))
                        }
                    }
                }
            }
        }
    }
}
