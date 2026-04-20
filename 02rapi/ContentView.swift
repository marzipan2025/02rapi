import SwiftUI

// MARK: - Channel

enum RadioChannel: String, CaseIterable, Identifiable, Sendable, Codable {
    case kbsCool, mbcFM4U, sbsPower, mbcStandard, kbsRadio1

    var id: String { rawValue }

    var frequency: String {
        switch self {
        case .kbsCool: "89.1"
        case .mbcFM4U: "91.9"
        case .sbsPower: "107.7"
        case .mbcStandard: "95.9"
        case .kbsRadio1: "97.3"
        }
    }

    var svgName: String {
        switch self {
        case .kbsCool: "btn_891"
        case .mbcFM4U: "btn_919"
        case .sbsPower: "btn_1077"
        case .mbcStandard: "btn_959"
        case .kbsRadio1: "btn_973"
        }
    }

    var brandColor: Color {
        switch self {
        case .kbsCool:     Color(red: 0x33/255, green: 0xA1/255, blue: 0xDB/255)
        case .mbcFM4U:     Color(red: 0xEB/255, green: 0x16/255, blue: 0x8F/255)
        case .sbsPower:    Color(red: 0x92/255, green: 0x3F/255, blue: 0xFF/255)
        case .mbcStandard: Color(red: 0xFB/255, green: 0xBD/255, blue: 0x01/255)
        case .kbsRadio1:   Color(red: 0x42/255, green: 0xDD/255, blue: 0x00/255)
        }
    }

    func resolveStreamURL() async throws -> URL {
        switch self {
        case .kbsCool:
            return try await resolveRedirect("https://radio.bsod.kr/stream/?stn=kbs&ch=2fm")
        case .mbcFM4U:
            return try await resolveMBCPlaylist(channel: "mfm")
        case .sbsPower:
            return try await resolveRedirect("https://radio.bsod.kr/stream/?stn=sbs&ch=powerfm")
        case .mbcStandard:
            return try await resolveMBCPlaylist(channel: "sfm")
        case .kbsRadio1:
            return try await resolveRedirect("https://radio.bsod.kr/stream/?stn=kbs&ch=1radio")
        }
    }

    private func resolveRedirect(_ urlString: String) async throws -> URL {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (_, response) = try await URLSession.shared.data(from: url)
        return response.url ?? url
    }

    private func resolveMBCPlaylist(channel: String) async throws -> URL {
        let random = Int.random(in: 100000...999999)
        let api = URL(string: "https://sminiplay.imbc.com/aacplay.ashx?channel=\(channel)&agent=webapp&protocol=M3U8&nocash=\(random)")!
        let (data, _) = try await URLSession.shared.data(from: api)
        guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: str) else { throw URLError(.badServerResponse) }
        return url
    }
}

// MARK: - Channel Slot

struct ChannelSlot: Equatable {
    var channel: RadioChannel
    var position: CGPoint
}

// MARK: - Persistent State

// 포지션은 저장하지 않는다 — 재실행 시 슬롯 인덱스에 따라 초기 좌표로 정규화.
private struct PersistentState: Codable {
    let visibleChannels: [String]  // 슬롯 인덱스 순서
    let hiddenQueue: [String]      // FIFO 순서
}

// MARK: - Window Drag View

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView { WindowDragNSView() }
    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

// MARK: - Parabolic Cycle Offset

private struct ParabolicOffset: ViewModifier, @preconcurrency Animatable {
    var progress: Double    // 0 (포털 중심) → 1 (착지점)
    let start: CGSize       // t=0 오프셋 (포털중심 - 착지점)
    let apexHeight: CGFloat // 포물선 정점 높이 (선형경로 위 양수)

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = CGFloat(progress)
        let invT = 1 - t
        let x = start.width * invT
        let y = start.height * invT - 4 * apexHeight * t * invT
        return content.offset(x: x, y: y)
    }
}

// MARK: - Glass Background Modifier

private struct ConditionalGlassEffect: ViewModifier {
    var useGlass: Bool

    func body(content: Content) -> some View {
        if useGlass {
            content
                .glassEffect(.clear, in: .rect(cornerRadius: 32))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32))
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    // 초기 슬롯: 89.1(좌), 107.7(가운데), 91.9(우) @ y=150
    private static let initialSlots: [ChannelSlot] = [
        ChannelSlot(channel: .kbsCool,  position: CGPoint(x: 44,  y: 150)),
        ChannelSlot(channel: .sbsPower, position: CGPoint(x: 138, y: 150)),
        ChannelSlot(channel: .mbcFM4U,  position: CGPoint(x: 228, y: 150))
    ]
    // 초기 히든 큐 (FIFO): 선두가 먼저 나옴
    private static let initialHiddenQueue: [RadioChannel] = [.mbcStandard, .kbsRadio1]

    private static let persistKey = "v102State"

    @State private var slots: [ChannelSlot] = Self.initialSlots
    @State private var hiddenQueue: [RadioChannel] = Self.initialHiddenQueue
    @State private var dragStart: [CGPoint?] = [nil, nil, nil]

    // 사이클링 애니메이션 상태 (슬롯별)
    @State private var slotOpacity: [Double] = [1, 1, 1]
    @State private var slotSinkOffset: [CGFloat] = [0, 0, 0]          // Phase 1 (빨려내려감) y offset
    @State private var slotCycleProgress: [Double] = [1, 1, 1]        // Phase 3 포물선 진행도 (0=포털중심, 1=착지)
    @State private var slotCycleStart: [CGSize] = [.zero, .zero, .zero] // Phase 3 시작 오프셋 (landing 기준)
    @State private var slotCycleApexH: [CGFloat] = [0, 0, 0]          // Phase 3 포물선 아펙스 높이
    @State private var isAnimating: [Bool] = [false, false, false]
    @State private var animationTasks: [Task<Void, Never>?] = [nil, nil, nil]

    @State private var isOnTop = false
    @AppStorage("glassEffectEnabled_v103") private var useGlassEffect: Bool = true

    @StateObject private var radio = MpvRadioPlayer()

    // 소리원 (상단 반원)
    private let soundCenter = CGPoint(x: 160, y: 13)
    private let soundRadius: CGFloat = 120
    private let redZoneWidth: CGFloat = 20

    // 채널포털 (하단 상부만 16px 보임; 지름 240, 상단 y=184 → 중심 y=304)
    private let portalCenter = CGPoint(x: 160, y: 304)
    private let portalRadius: CGFloat = 120

    private let lineX: CGFloat = 160
    private let btnSize = CGSize(width: 59, height: 22)
    private let refInBtn = CGPoint(x: 30, y: 17)

    // Phase 1 (빨려내려감) 슬라이드 거리 (offset y +67 → 화면 밖)
    private let sinkOffset: CGFloat = 67

    // 채널 사이클링 효과음 (튀어나올 때). Pre-load + 30% 볼륨.
    // Credit: "UI Pop Sound" by Pixabay (Pixabay Content License)
    private let popSound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "ui_pop", withExtension: "mp3") else { return nil }
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = 0.3
        return sound
    }()

    private func playPop() {
        guard let sound = popSound else { return }
        sound.stop()
        sound.play()
    }

    private var hasMoved: Bool {
        slots != Self.initialSlots || hiddenQueue != Self.initialHiddenQueue
    }

    var body: some View {
        ZStack {
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 소리원 (상단)
            Circle()
                .fill(Color(red: 0x8D/255, green: 0x98/255, blue: 0xC7/255).opacity(0.25))
                .frame(width: soundRadius * 2, height: soundRadius * 2)
                .position(soundCenter)
                .allowsHitTesting(false)

            // 채널포털 (하단; 시각 속성만 소리원과 동일)
            Circle()
                .fill(Color(red: 0x8D/255, green: 0x98/255, blue: 0xC7/255).opacity(0.25))
                .frame(width: portalRadius * 2, height: portalRadius * 2)
                .position(portalCenter)
                .allowsHitTesting(false)

            blobsCanvas
                .allowsHitTesting(false)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.black.opacity(0.3), .black.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1, height: 200)
                .position(x: lineX, y: 113)
                .allowsHitTesting(false)

            // textdeco (상단 정렬, 앱 너비에 맞춤)
            SVGImage(name: "textdeco", fallbackText: "", color: .clear)
                .frame(width: 300, height: 121)
                .position(x: 160, y: 72.5)
                .allowsHitTesting(false)

            ForEach(0..<3, id: \.self) { index in
                channelButton(at: index)
            }

            // Reloc button (20,20), 20x20
            Button(action: restoreDefaults) {
                SVGImage(name: "reloc", fallbackText: "↺", color: Color(red: 0xBE/255.0, green: 0xC2/255.0, blue: 0xD0/255.0), tinted: true)
                    .frame(width: 20, height: 20)
                    .opacity(hasMoved ? 1.0 : 0.6)
            }
            .buttonStyle(.plain)
            .position(x: 18, y: 22)

            // OnTop button
            Button(action: toggleOnTop) {
                SVGImage(name: "onTop", fallbackText: "📌", color: Color(red: 0xBE/255.0, green: 0xC2/255.0, blue: 0xD0/255.0), tinted: true)
                    .frame(width: 20, height: 20)
                    .opacity(isOnTop ? 1.0 : 0.6)
            }
            .buttonStyle(.plain)
            .position(x: 298, y: 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ConditionalGlassEffect(useGlass: useGlassEffect))
        .ignoresSafeArea()
        .onAppear { loadPersistedState() }
        .onReceive(NotificationCenter.default.publisher(for: .restoreDefaults)) { _ in
            restoreDefaults()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleOnTop)) { _ in
            toggleOnTop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleGlassEffect)) { _ in
            useGlassEffect.toggle()
        }
    }

    // 현재 보여지는 3개 채널을 그대로 두고, position 만 초기 슬롯 위치로 재정렬.
    // (채널 identity, hiddenQueue 는 유지. 진행 중인 사이클 애니메이션은 취소.)
    private func restoreDefaults() {
        // 진행 중인 사이클 애니메이션 취소
        for i in 0..<animationTasks.count {
            animationTasks[i]?.cancel()
            animationTasks[i] = nil
        }

        // 애니메이션 없이 position 만 재배치
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            for i in 0..<slots.count {
                slots[i].position = Self.initialSlots[i].position
            }
            slotOpacity = [1, 1, 1]
            slotSinkOffset = [0, 0, 0]
            slotCycleProgress = [1, 1, 1]
            slotCycleStart = [.zero, .zero, .zero]
            slotCycleApexH = [0, 0, 0]
            isAnimating = [false, false, false]
        }

        // 새 position 에 맞춰 오디오 업데이트 (볼륨/팬 재계산)
        for slot in slots {
            updateAudio(slot.channel, pos: slot.position)
        }

        persistState()
    }

    private func toggleOnTop() {
        isOnTop.toggle()
        if let window = NSApplication.shared.windows.first {
            window.level = isOnTop ? .floating : .normal
        }
    }

    private var blobsCanvas: some View {
        Canvas { context, _ in
            let clipPath = Path(ellipseIn: CGRect(
                x: soundCenter.x - soundRadius, y: soundCenter.y - soundRadius,
                width: soundRadius * 2, height: soundRadius * 2
            ))
            var clipped = context
            clipped.clip(to: clipPath)

            for slot in slots {
                let ref = refPoint(slot.position)
                let d = dist(ref, soundCenter)
                guard d <= soundRadius else { continue }
                let t = 1 - d / soundRadius
                let diameter = 48 + (240 - 48) * t

                var blob = clipped
                blob.opacity = 0.4
                blob.addFilter(.blur(radius: 20))
                blob.fill(
                    Path(ellipseIn: CGRect(
                        x: ref.x - diameter / 2, y: ref.y - diameter / 2,
                        width: diameter, height: diameter
                    )),
                    with: .color(slot.channel.brandColor)
                )
            }
        }
    }

    @ViewBuilder
    private func channelButton(at index: Int) -> some View {
        let slot = slots[index]
        let cx = slot.position.x + btnSize.width / 2
        let cy = slot.position.y + btnSize.height / 2
        let animating = isAnimating[index]

        SVGImage(name: slot.channel.svgName, fallbackText: slot.channel.frequency, color: slot.channel.brandColor)
            .frame(width: btnSize.width, height: btnSize.height)
            .contentShape(Rectangle())
            .opacity(slotOpacity[index])
            .modifier(ParabolicOffset(
                progress: slotCycleProgress[index],
                start: slotCycleStart[index],
                apexHeight: slotCycleApexH[index]
            ))
            .offset(y: slotSinkOffset[index])
            .allowsHitTesting(!animating)
            .position(x: cx, y: cy)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStart[index] == nil { dragStart[index] = slots[index].position }
                        let start = dragStart[index]!
                        let rawX = start.x + value.translation.width
                        let rawY = start.y + value.translation.height
                        let clamped = clampButtonPosition(CGPoint(x: rawX, y: rawY))
                        slots[index].position = clamped
                        updateAudio(slots[index].channel, pos: clamped)
                    }
                    .onEnded { _ in
                        handleDragEnd(index: index)
                    }
            )
    }

    private func handleDragEnd(index: Int) {
        let refPos = refPoint(slots[index].position)
        let inPortal = dist(refPos, portalCenter) <= portalRadius
        dragStart[index] = nil

        if inPortal && !hiddenQueue.isEmpty && !isAnimating[index] {
            cycleChannel(at: index)
            // persistState 는 사이클 애니메이션 완료 후 Task 안에서 호출
        } else {
            persistState()
        }
    }

    // 채널포털에 드롭 시 FIFO 사이클링 + 580ms 애니메이션 시퀀스.
    //  Phase 1 (0–130ms):   "천천히 내려가다가 쑥 빠지는" — easeIn 슬라이드 0→67
    //                        · 0–65ms:  opacity 1 유지 (천천히 내려감)
    //                        · 65–130ms: opacity 1→0 (가속하며 빨려 사라짐)
    //  Gap    (130–280ms):  빈 구간 (포털 내부 체류, 150ms)
    //  Swap   (t=280ms):    채널 교체 + 랜덤 착지 좌표 + 포물선 파라미터 산출
    //                        새 버튼의 visual center = 포털 중심 (160, 304) 에 배치
    //  Phase 3 (280–580ms): 포털 중심에서 착지점까지 포물선 아크 (easeOut 300ms)
    private func cycleChannel(at index: Int) {
        isAnimating[index] = true

        let oldChannel = slots[index].channel
        radio.stop(channel: oldChannel)

        // Phase 1: easeIn 슬라이드 (130ms) + 지연 페이드 (65ms 후 65ms 페이드)
        withAnimation(.easeIn(duration: 0.13)) {
            slotSinkOffset[index] = sinkOffset
        }
        withAnimation(.easeIn(duration: 0.065).delay(0.065)) {
            slotOpacity[index] = 0
        }

        animationTasks[index] = Task { @MainActor in
            defer { isAnimating[index] = false }

            do {
                // Phase 1 (130ms) + Gap (150ms) = 280ms 대기
                try await Task.sleep(nanoseconds: 280_000_000)
                if Task.isCancelled { return }

                // 채널 교체 + hiddenQueue 업데이트 + 랜덤 착지 좌표 산출
                hiddenQueue.append(oldChannel)
                let newChannel = hiddenQueue.removeFirst()
                let landing = randomBackgroundPosition()

                // 포물선 시작 오프셋: 버튼 visual center 가 포털 중심 (160, 304) 이 되도록
                //   landing + (btn.w/2, btn.h/2) + (startX, startY) = portalCenter
                let startX = portalCenter.x - btnSize.width / 2 - landing.x
                let startY = portalCenter.y - btnSize.height / 2 - landing.y

                // 아펙스 높이: 포물선 아펙스 → 착지점의 y 차이가 정확히 6px 이 되도록 제한.
                //   y_offset(t) = s·(1-t) - 4h·t·(1-t),  s = startY, h = apexH
                //   |apex_offset_y| = (4h - s)² / (16h) = 6
                //   → 16h² - (8s + 96)h + s² = 0
                //   → h = s/4 + 3 + √(6s + 36) / 2  (큰 해, t_peak ∈ (0,1) 보장)
                // 효과: 아펙스가 경로의 ~83% 지점에 위치하여 "착지점 바로 위에서 살짝 내려앉는" 느낌.
                let apexH = startY / 4 + 3 + sqrt(6 * startY + 36) / 2

                var swapTx = Transaction()
                swapTx.disablesAnimations = true
                withTransaction(swapTx) {
                    slots[index] = ChannelSlot(channel: newChannel, position: landing)
                    slotOpacity[index] = 1
                    slotSinkOffset[index] = 0
                    slotCycleStart[index] = CGSize(width: startX, height: startY)
                    slotCycleApexH[index] = apexH
                    slotCycleProgress[index] = 0
                }

                // 포털에서 튀어나오는 순간 효과음 (ui_pop, 30% volume)
                playPop()

                // Phase 3: 포털 중심에서 착지점까지 포물선 아크 (300ms, easeOut)
                withAnimation(.easeOut(duration: 0.3)) {
                    slotCycleProgress[index] = 1
                }
                try await Task.sleep(nanoseconds: 300_000_000)

                persistState()
            } catch {
                // Task 취소됨 — isAnimating 은 defer 로 정리됨
            }
        }
    }

    // 채널포털 사이클 후 새 버튼이 떨어질 랜덤 좌표.
    // 앱 사방 10px 안쪽 전체 영역 (버튼 rect 가 [10, 10]–[310, 190] 안쪽에 들어가도록).
    // 착지점 버튼 rect + Phase 3 포물선 경로 전체가 소리원·포털과 시각적으로 닿지 않도록 거절 샘플링.
    // (포털은 초기 exit 허용, 재접촉만 금지. 소리원은 전구간 금지.)
    private func randomBackgroundPosition() -> CGPoint {
        // 앱 320x200, 10px inset → 버튼 top-left 범위
        let xRange: ClosedRange<CGFloat> = 10...(320 - 10 - btnSize.width)  // [10, 251]
        let yRange: ClosedRange<CGFloat> = 10...(200 - 10 - btnSize.height) // [10, 168]

        for _ in 0..<500 {
            let x = CGFloat.random(in: xRange)
            let y = CGFloat.random(in: yRange)
            let candidate = CGPoint(x: x, y: y)

            // 착지점 정지 rect 가 두 원과 시각적으로 닿지 않아야 함
            if buttonRectIntersectsCircle(candidate, circleCenter: soundCenter, circleRadius: soundRadius) { continue }
            if buttonRectIntersectsCircle(candidate, circleCenter: portalCenter, circleRadius: portalRadius) { continue }

            // Phase 3 포물선 경로 전체가 닿지 않아야 함
            if isPhase3PathClear(landing: candidate) {
                return candidate
            }
        }
        // 폴백: 중앙 안전 좌표 (극히 드물게만 도달)
        return CGPoint(x: 130.5, y: 155)
    }

    // 버튼 rect 와 원의 기하학적 교차 검사. "시각적으로 닿음" 의 엄격한 정의.
    // (rect 내부의 원 center 에 가장 가까운 점과 center 의 거리 < radius)
    private func buttonRectIntersectsCircle(_ topLeft: CGPoint, circleCenter: CGPoint, circleRadius: CGFloat) -> Bool {
        let rectMaxX = topLeft.x + btnSize.width
        let rectMaxY = topLeft.y + btnSize.height
        let closestX = max(topLeft.x, min(circleCenter.x, rectMaxX))
        let closestY = max(topLeft.y, min(circleCenter.y, rectMaxY))
        let dx = circleCenter.x - closestX
        let dy = circleCenter.y - closestY
        return dx * dx + dy * dy < circleRadius * circleRadius
    }

    // Phase 3 포물선 경로가 소리원/포털과 시각적으로 닿는지 검사 (60 step 샘플링).
    //  · 소리원: 전구간 교차 금지
    //  · 포털:  초기 exit 전까지는 허용 (포털 내부에서 시작), exit 이후 재접촉 금지
    private func isPhase3PathClear(landing: CGPoint) -> Bool {
        let startX = portalCenter.x - btnSize.width / 2 - landing.x
        let startY = portalCenter.y - btnSize.height / 2 - landing.y
        let apexH = startY / 4 + 3 + sqrt(6 * startY + 36) / 2

        let steps = 60
        var exitedPortal = false
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let invT = 1 - t
            let xOffset = startX * invT
            let yOffset = startY * invT - 4 * apexH * t * invT
            let topLeft = CGPoint(x: landing.x + xOffset, y: landing.y + yOffset)

            // 소리원: 전구간 금지
            if buttonRectIntersectsCircle(topLeft, circleCenter: soundCenter, circleRadius: soundRadius) {
                return false
            }

            // 포털: 초기 exit 후 재접촉 금지
            let inPortal = buttonRectIntersectsCircle(topLeft, circleCenter: portalCenter, circleRadius: portalRadius)
            if !exitedPortal && !inPortal {
                exitedPortal = true
            }
            if exitedPortal && inPortal {
                return false
            }
        }
        return true
    }

    private func clampButtonPosition(_ raw: CGPoint) -> CGPoint {
        let x = min(max(raw.x, 7), 320 + 1 - btnSize.width)
        // 버튼 중심 x가 화면 가운데 3분의 1에 있으면 바닥까지 내려갈 수 있음
        let btnCenterX = x + btnSize.width / 2
        let inCenterThird = btnCenterX >= 320.0 / 3 && btnCenterX <= 320.0 * 2 / 3
        let yMax: CGFloat = inCenterThird ? (200 - btnSize.height) : (200 - 8 - btnSize.height)
        let y = min(max(raw.y, 5), yMax)
        return CGPoint(x: x, y: y)
    }

    private func updateAudio(_ channel: RadioChannel, pos: CGPoint) {
        let ref = refPoint(pos)
        let d = dist(ref, soundCenter)

        if d <= soundRadius {
            // 소리원 내부: 10%~120% 볼륨
            let t = 1 - d / soundRadius
            let volume = Float(0.10 + 1.10 * t)
            let pan = Float((ref.x - lineX) / soundRadius).clamped(-1, 1)
            radio.play(channel: channel, volume: volume, pan: pan)
        } else if d <= soundRadius + redZoneWidth {
            // 레드존 (소리원 밖 20px 이내): 1% 볼륨 고정
            let pan = Float((ref.x - lineX) / soundRadius).clamped(-1, 1)
            radio.play(channel: channel, volume: 0.01, pan: pan)
        } else {
            radio.stop(channel: channel)
        }
    }

    private func refPoint(_ btnPos: CGPoint) -> CGPoint {
        CGPoint(x: btnPos.x + refInBtn.x, y: btnPos.y + refInBtn.y)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }

    // MARK: Persistence

    private func persistState() {
        let state = PersistentState(
            visibleChannels: slots.map { $0.channel.rawValue },
            hiddenQueue: hiddenQueue.map { $0.rawValue }
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    private func loadPersistedState() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let state = try? JSONDecoder().decode(PersistentState.self, from: data) else {
            return
        }
        guard state.visibleChannels.count == 3, state.hiddenQueue.count == 2 else { return }

        // 포지션은 저장값을 무시하고 슬롯 인덱스에 대응하는 초기 좌표로 정규화.
        var loadedSlots: [ChannelSlot] = []
        for (i, raw) in state.visibleChannels.enumerated() {
            guard let ch = RadioChannel(rawValue: raw) else { return }
            loadedSlots.append(ChannelSlot(
                channel: ch,
                position: Self.initialSlots[i].position
            ))
        }

        var loadedHidden: [RadioChannel] = []
        for raw in state.hiddenQueue {
            guard let ch = RadioChannel(rawValue: raw) else { return }
            loadedHidden.append(ch)
        }

        // 5개 채널이 중복 없이 모두 포함되어야 함
        let union = Set(loadedSlots.map { $0.channel }).union(Set(loadedHidden))
        guard union.count == RadioChannel.allCases.count else { return }

        self.slots = loadedSlots
        self.hiddenQueue = loadedHidden
    }
}

// MARK: - SVG Image

struct SVGImage: View {
    let name: String
    let fallbackText: String
    let color: Color
    var tinted: Bool = false

    var body: some View {
        if let url = Bundle.main.url(forResource: name, withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            if tinted {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .colorMultiply(color)
            } else {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        } else {
            Text(fallbackText)
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let restoreDefaults = Notification.Name("restoreDefaults")
    static let toggleOnTop = Notification.Name("toggleOnTop")
    static let toggleGlassEffect = Notification.Name("toggleGlassEffect")
}

// MARK: - Float Extension

extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float {
        Swift.min(Swift.max(self, lo), hi)
    }
}

// MARK: - libmpv 동적 로딩

private final class MpvLib: @unchecked Sendable {
    static let shared = MpvLib()

    typealias CreateFn = @convention(c) () -> OpaquePointer?
    typealias InitFn = @convention(c) (OpaquePointer) -> Int32
    typealias DestroyFn = @convention(c) (OpaquePointer) -> Void
    typealias SetOptStrFn = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    typealias CommandFn = @convention(c) (OpaquePointer, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32
    typealias SetPropFn = @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, UnsafeRawPointer) -> Int32
    typealias SetPropStrFn = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32

    let create: CreateFn
    let initialize: InitFn
    let destroy: DestroyFn
    let setOptionString: SetOptStrFn
    let command: CommandFn
    let setProperty: SetPropFn
    let setPropertyString: SetPropStrFn

    let available: Bool

    private init() {
        // 1순위: 앱 번들 내 Frameworks, 2순위: IINA
        let bundleFw = (Bundle.main.privateFrameworksPath ?? "")
        let iinaFw = "/Applications/IINA.app/Contents/Frameworks"
        let fw = FileManager.default.fileExists(atPath: "\(bundleFw)/libmpv.2.dylib") ? bundleFw : iinaFw

        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: fw) {
            let dylibs = files.filter { $0.hasSuffix(".dylib") && $0 != "libmpv.2.dylib" }
            var remaining = dylibs
            for _ in 0..<10 {
                var failed: [String] = []
                for file in remaining {
                    if dlopen("\(fw)/\(file)", RTLD_LAZY | RTLD_GLOBAL) == nil {
                        failed.append(file)
                    }
                }
                remaining = failed
                if remaining.isEmpty { break }
            }
            if !remaining.isEmpty {
                print("Failed to load: \(remaining)")
            }
        }

        guard let handle = dlopen("\(fw)/libmpv.2.dylib", RTLD_LAZY) else {
            let err = String(cString: dlerror())
            print("libmpv not found: \(err)")
            self.create = { nil }
            self.initialize = { _ in -1 }
            self.destroy = { _ in }
            self.setOptionString = { _, _, _ in -1 }
            self.command = { _, _ in -1 }
            self.setProperty = { _, _, _, _ in -1 }
            self.setPropertyString = { _, _, _ in -1 }
            self.available = false
            return
        }

        self.create = unsafeBitCast(dlsym(handle, "mpv_create"), to: CreateFn.self)
        self.initialize = unsafeBitCast(dlsym(handle, "mpv_initialize"), to: InitFn.self)
        self.destroy = unsafeBitCast(dlsym(handle, "mpv_terminate_destroy"), to: DestroyFn.self)
        self.setOptionString = unsafeBitCast(dlsym(handle, "mpv_set_option_string"), to: SetOptStrFn.self)
        self.command = unsafeBitCast(dlsym(handle, "mpv_command"), to: CommandFn.self)
        self.setProperty = unsafeBitCast(dlsym(handle, "mpv_set_property"), to: SetPropFn.self)
        self.setPropertyString = unsafeBitCast(dlsym(handle, "mpv_set_property_string"), to: SetPropStrFn.self)
        self.available = true
        print("libmpv loaded ✓")
    }
}

// MARK: - Mpv Radio Player (싱글 인스턴스 + 동적 af 필터)

final class MpvRadioPlayer: ObservableObject, @unchecked Sendable {

    // 채널당 1개 mpv 인스턴스. 디코더 1개로 에코 문제 제거.
    private var channels: [RadioChannel: OpaquePointer] = [:]
    // 마지막으로 적용한 pan 값 (양자화된). 변화 없으면 필터 리로드 생략.
    private var currentPans: [RadioChannel: Float] = [:]
    private var loading: Set<RadioChannel> = []
    private let lib = MpvLib.shared

    func play(channel: RadioChannel, volume: Float, pan: Float) {
        guard lib.available else { return }

        if let mpv = channels[channel] {
            // 볼륨은 매 프레임 부드럽게 업데이트
            setVolume(mpv, volume: Double(volume * 100))

            // pan은 0.02 단위로 양자화 → 필터 리로드 빈도 축소
            let quantized = (pan * 50).rounded() / 50
            if currentPans[channel] != quantized {
                currentPans[channel] = quantized
                updatePanFilter(mpv, pan: quantized)
            }
        } else if !loading.contains(channel) {
            loading.insert(channel)
            Task {
                do {
                    let url = try await channel.resolveStreamURL()
                    await MainActor.run {
                        self.startPlayback(channel: channel, url: url.absoluteString, volume: volume, pan: pan)
                        self.loading.remove(channel)
                    }
                } catch {
                    print("Stream error [\(channel)]: \(error)")
                    await MainActor.run { self.loading.remove(channel) }
                }
            }
        }
    }

    func stop(channel: RadioChannel) {
        guard let mpv = channels[channel] else { return }
        lib.destroy(mpv)
        channels[channel] = nil
        currentPans[channel] = nil
    }

    private func startPlayback(channel: RadioChannel, url: String, volume: Float, pan: Float) {
        guard let mpv = lib.create() else {
            print("Failed to create mpv for \(channel)")
            return
        }

        _ = lib.setOptionString(mpv, "vid", "no")            // 비디오 끔
        _ = lib.setOptionString(mpv, "terminal", "no")        // 터미널 출력 끔
        _ = lib.setOptionString(mpv, "audio-display", "no")   // 오디오 시각화 끔

        let quantized = (pan * 50).rounded() / 50
        _ = lib.setOptionString(mpv, "af", panFilter(pan: quantized))

        guard lib.initialize(mpv) == 0 else {
            lib.destroy(mpv)
            return
        }

        setVolume(mpv, volume: Double(volume * 100))
        loadURL(mpv, url: url)

        channels[channel] = mpv
        currentPans[channel] = quantized
        print("mpv playing \(channel) ✓")
    }

    // Equal-power panning을 lavfi pan 필터로 표현
    private func panFilter(pan: Float) -> String {
        let angle = (pan + 1) * .pi / 4  // pan -1 → 0, +1 → π/2
        let leftGain = cos(angle)         // pan -1일 때 1.0
        let rightGain = sin(angle)        // pan +1일 때 1.0
        // 스테레오 소스 양 채널을 모노로 합친 뒤 L/R 게인 적용
        return String(
            format: "lavfi=[pan=stereo|c0=%.3f*c0+%.3f*c1|c1=%.3f*c0+%.3f*c1]",
            leftGain, leftGain, rightGain, rightGain
        )
    }

    private func updatePanFilter(_ mpv: OpaquePointer, pan: Float) {
        let filter = panFilter(pan: pan)
        filter.withCString { filterPtr in
            "af".withCString { keyPtr in
                _ = lib.setPropertyString(mpv, keyPtr, filterPtr)
            }
        }
    }

    private func setVolume(_ mpv: OpaquePointer, volume: Double) {
        var vol = volume
        _ = lib.setProperty(mpv, "volume", 5 /* MPV_FORMAT_DOUBLE */, &vol)
    }

    private func loadURL(_ mpv: OpaquePointer, url: String) {
        url.withCString { urlPtr in
            "replace".withCString { replacePtr in
                var args: [UnsafePointer<CChar>?] = []
                "loadfile".withCString { loadfilePtr in
                    args = [loadfilePtr, urlPtr, replacePtr, nil]
                    _ = lib.command(mpv, &args)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
