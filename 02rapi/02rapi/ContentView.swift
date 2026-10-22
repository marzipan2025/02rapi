import SwiftUI
import AVFoundation

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

    // 업데이트 버튼 상태
    private enum UpdatePhase { case none, offered, installing, updated }
    // 업데이트 후 재실행된 첫 실행인지 (한 번만 소비)
    private static let justUpdated = AppUpdater.consumeJustUpdated()

    @State private var updatePhase: UpdatePhase = .none
    @State private var updateRelease: AppRelease?
    @State private var updatePos: CGPoint = CGPoint(x: 122, y: 220)
    @State private var updateOpacity: Double = 1
    @State private var updateSinkOffset: CGFloat = 0
    @State private var updateDragStart: CGPoint?
    @State private var updateFlowDone = false
    // 오픈 인트로: 채널 버튼 3개는 숨긴 채 시작해 디졸브 + 떠오르기로 등장
    // (슬롯별: 왼쪽 버튼부터 0.1초 간격으로 차례로 시작)
    @State private var channelsOpacity: [Double] = [0, 0, 0]
    @State private var channelsRise: [CGFloat] = [12, 12, 12]

    @State private var isOnTop = false
    // ⌘G 로 순환하는 유리 모드: 창 Liquid Glass → 창 머티리얼 → 창 Liquid Glass + 소리원 유리
    private enum GlassMode: Int, CaseIterable {
        case glass, material, glassWithSound
    }
    @AppStorage("glassEffectEnabled_v103") private var useGlassEffect: Bool = true  // 1.1.0 이하의 설정 (이전용)
    @AppStorage("glassMode_v111") private var glassModeRaw: Int = -1
    private var glassMode: GlassMode {
        GlassMode(rawValue: glassModeRaw) ?? (useGlassEffect ? .glass : .material)
    }

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

    // 업데이트 버튼 (svg 128x36 을 채널 버튼과 같은 배율로 → 76x22, 글자 중심 x=38)
    private let updateBtnSize = CGSize(width: 76, height: 22)
    private let refInUpdateBtn = CGPoint(x: 38, y: 17)
    // 대기 위치: ref 가 소리원 중심선 위, 반지름 1/3 지점에서 12px 위 (160, 41)
    private var updateRestPos: CGPoint {
        CGPoint(x: lineX - refInUpdateBtn.x, y: soundCenter.y + soundRadius / 3 - 12 - refInUpdateBtn.y)
    }
    // 튀어나오기 시작 위치: 화면 아래 바깥
    private var updateStartPos: CGPoint { CGPoint(x: updateRestPos.x, y: 220) }

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

    // Update / Updated 등장음: 허밍과 같은 A장조 말렛 (직접 합성, 파일 자체 음량으로 재생)
    private let updatePopSound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "update_pop", withExtension: "wav") else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }()
    private let updatedPopSound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "updated_pop", withExtension: "wav") else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }()

    private func playUpdatePop(_ phase: UpdatePhase) {
        guard let sound = phase == .updated ? updatedPopSound : updatePopSound else { return }
        sound.stop()
        sound.play()
    }

    // 설치 중 점멸에 맞춘 허밍 루프 (update_hum.wav: 14초 = 점멸 2.8초 × 5, 이음새 없음)
    @State private var humPlayer: AVAudioPlayer?

    private func startHum() {
        guard humPlayer == nil,
              let url = Bundle.main.url(forResource: "update_hum", withExtension: "wav"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        // 점멸은 기준 시각(timeIntervalSinceReferenceDate)으로 위상을 잡으므로 같은 시각으로 재생 위치를 맞춘다
        player.currentTime = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: player.duration)
        player.play()
        player.setVolume(1, fadeDuration: 1.0)
        humPlayer = player
    }

    private func stopHum(fade: TimeInterval) async {
        guard let player = humPlayer else { return }
        humPlayer = nil
        player.setVolume(0, fadeDuration: fade)
        try? await Task.sleep(nanoseconds: UInt64(fade * 1_000_000_000))
        player.stop()
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

            // 다운로드·설치 중: 포털이 흰색으로 묵직하게 점멸 (2.8초 주기).
            // 아래층에 원 경계 밖으로 45px 블러가 퍼지는 글로우(지름 230, 최대 0.4)가 같은 호흡으로 함께 점멸.
            if updatePhase == .installing {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let wave = (1 - cos(t * 2 * .pi / 2.8)) / 2
                    // smoothstep: 바닥과 정점에서 오래 머물고 중간을 지나가는 묵직한 호흡
                    let breath = wave * wave * (3 - 2 * wave)
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: portalRadius * 2 - 10, height: portalRadius * 2 - 10)
                            .blur(radius: 45)
                            .opacity(0.4 * breath)
                            .position(portalCenter)
                        Circle()
                            .fill(Color.white)
                            .opacity(0.7 * breath)  // 아래 글로우와 겹쳐 최대 약 0.75
                            .frame(width: portalRadius * 2, height: portalRadius * 2)
                            .position(portalCenter)
                    }
                }
                .allowsHitTesting(false)
            }

            blobsCanvas
                .allowsHitTesting(false)

            // 소리원 위에 맑은 Liquid Glass 한 겹 (렌즈 셰이더 굴절·색수차는 그 아래에 그대로)
            if glassMode == .glassWithSound {
                Circle()
                    .fill(Color.clear)
                    .frame(width: soundRadius * 2, height: soundRadius * 2)
                    .glassEffect(.clear, in: Circle())
                    .position(soundCenter)
                    .allowsHitTesting(false)
            }

            if updatePhase != .none {
                UpdateBlob(ref: updateRef(updatePos), soundCenter: soundCenter, soundRadius: soundRadius)
                    .opacity(updateOpacity)
                    .allowsHitTesting(false)
            }

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
                    .opacity(channelsOpacity[index])
                    .offset(y: channelsRise[index])
                    .allowsHitTesting(channelsOpacity[index] == 1)
            }

            if updatePhase != .none {
                updateButton
            }

            // Reloc button (20,20), 20x20
            Button(action: restoreDefaults) {
                SVGImage(name: "reloc", fallbackText: "↺", color: Color(red: 0xBE/255.0, green: 0xC2/255.0, blue: 0xD0/255.0), tinted: true)
                    .frame(width: 20, height: 20)
                    .opacity(0.6)  // 상태 표시 없이 항상 흐리게 (밝기 변화는 OnTop 핀만)
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
        .modifier(ConditionalGlassEffect(useGlass: glassMode != .material))
        .ignoresSafeArea()
        .onAppear { loadPersistedState() }
        .task { await startUpdateFlow() }
        .onChange(of: updatePhase) { old, new in
            if new == .installing {
                startHum()
            } else if old == .installing {
                Task { await stopHum(fade: 0.6) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreDefaults)) { _ in
            restoreDefaults()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleOnTop)) { _ in
            toggleOnTop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleGlassEffect)) { _ in
            glassModeRaw = (glassMode.rawValue + 1) % GlassMode.allCases.count
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

            let blobs: [(center: CGPoint, diameter: CGFloat, color: Color)] = slots.compactMap { slot in
                let ref = refPoint(slot.position)
                let d = dist(ref, soundCenter)
                guard d <= soundRadius else { return nil }
                let t = 1 - d / soundRadius
                let diameter = 48 + (240 - 48) * t
                return (ref, diameter, slot.channel.brandColor)
            }
            clipped.fill(clipPath, with: .style(blobMesh(blobs, box: clipPath.boundingRect)))
        }
        // 소리원을 볼록렌즈처럼: 가운데 확대 + 가장자리 색수차
        .modifier(BlobLensEffect(center: soundCenter, radius: soundRadius))
    }

    // 메시: 소리원을 덮는 13×13 메시 그라데이션.
    //  · 불투명도 = 블러들의 가우시안 가중치 합 → 크고 가까운 블러일수록 넓고 진하게 (볼륨·좌우 인지)
    //  · 색 = "자기 반지름 대비 거리"의 역세제곱 가중 평균 → 각 블러 중심 근처는 반드시 자기 색이고,
    //    큰 블러가 작은 블러를 덮지 못한 채 경계에서만 섞인다.
    private func blobMesh(_ blobs: [(center: CGPoint, diameter: CGFloat, color: Color)], box: CGRect) -> MeshGradient {
        let n = 13
        let resolved: [Color.Resolved] = blobs.map { $0.color.resolve(in: EnvironmentValues()) }
        var points: [SIMD2<Float>] = []
        var colors: [Color] = []
        for row in 0..<n {
            for col in 0..<n {
                let u = Float(col) / Float(n - 1)
                let v = Float(row) / Float(n - 1)
                let p = CGPoint(x: box.minX + CGFloat(u) * box.width, y: box.minY + CGFloat(v) * box.height)
                var w: Float = 0
                var hueW: Float = 0
                var r: Float = 0
                var g: Float = 0
                var b: Float = 0
                for i in blobs.indices {
                    let sigma: CGFloat = blobs[i].diameter * 0.4
                    let dd: CGFloat = dist(p, blobs[i].center)
                    let exponent: CGFloat = -(dd * dd) / (2 * sigma * sigma)
                    w += Float(exp(exponent))

                    let rel: CGFloat = max(dd / (blobs[i].diameter / 2), 0.05)
                    let hi = Float(1 / (rel * rel * rel))
                    let ci: Color.Resolved = resolved[i]
                    hueW += hi
                    r += hi * ci.linearRed
                    g += hi * ci.linearGreen
                    b += hi * ci.linearBlue
                }
                var k: Float = 0
                if hueW > 0 { k = 1 / hueW }
                let lr: Float = r * k
                let lg: Float = g * k
                let lb: Float = b * k
                let alpha: Float = min(1, w) * 0.45
                let c = Color.Resolved(colorSpace: .sRGBLinear, red: lr, green: lg, blue: lb, opacity: alpha)
                points.append(SIMD2<Float>(u, v))
                colors.append(Color(c))
            }
        }
        return MeshGradient(width: n, height: n, points: points, colors: colors)
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

    // MARK: Update Button

    private var updateButton: some View {
        let name = updatePhase == .updated ? "btn_updated" : "btn_update"
        return SVGImage(name: name, fallbackText: updatePhase == .updated ? "Updated" : "Update", color: .white)
            .frame(width: updateBtnSize.width, height: updateBtnSize.height)
            .contentShape(Rectangle())
            .opacity(updateOpacity)
            .offset(y: updateSinkOffset)
            .allowsHitTesting(updatePhase == .offered)
            .position(x: updatePos.x + updateBtnSize.width / 2, y: updatePos.y + updateBtnSize.height / 2)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if updateDragStart == nil { updateDragStart = updatePos }
                        let start = updateDragStart!
                        updatePos = clampButtonPosition(
                            CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height),
                            size: updateBtnSize
                        )
                    }
                    .onEnded { _ in handleUpdateDragEnd() }
            )
    }

    private enum EarlyCheck: Sendable { case done(AppRelease?), timedOut }
    // 실행 시 업데이트 확인을 기다리는 최대 시간 (이후엔 인트로부터)
    private static let updateCheckWait: UInt64 = 2_500_000_000

    private func updateRef(_ pos: CGPoint) -> CGPoint {
        CGPoint(x: pos.x + refInUpdateBtn.x, y: pos.y + refInUpdateBtn.y)
    }

    // 실행 직후: 업데이트 직후라면 Updated 연출 → 오픈 인트로,
    // 아니면 새 버전부터 확인 → 있으면 주파수 버튼 없이 Update 버튼만, 없으면 오픈 인트로.
    // 네트워크가 느리면 인트로가 늦어지지 않도록 확인은 최대 updateCheckWait 까지만 기다린다.
    // 실행 직후 창 스타일이 바뀌면서 뷰가 한 번 사라졌다 나타나 .task 가 취소·재시작된다.
    // 취소된 쪽은 곧바로 빠지고, 끝까지 간 흐름은 updateFlowDone 으로 한 번만 돌게 한다.
    private func startUpdateFlow() async {
        guard !updateFlowDone else { return }
        if Self.justUpdated {
            do {
                try await playUpdated()
                try await playIntro()
            } catch { return }
            updateFlowDone = true
            return
        }
        let check = Task { await AppUpdater.checkForUpdate() }
        let early = await withTaskGroup(of: EarlyCheck.self) { group in
            group.addTask { .done(await check.value) }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.updateCheckWait)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        if Task.isCancelled { check.cancel(); return }

        let release: AppRelease?
        switch early {
        case .done(let r):
            release = r
            if release == nil {
                do { try await playIntro() } catch { return }
            }
        case .timedOut:
            // 확인이 늦으면 인트로를 먼저 보여 주고, 나중에 업데이트가 확인되면 버튼을 숨긴다
            do { try await playIntro() } catch { check.cancel(); return }
            release = await check.value
            if Task.isCancelled { return }
            if release != nil {
                for slot in slots { radio.stop(channel: slot.channel) }
                withAnimation(.easeOut(duration: 0.3)) {
                    channelsOpacity = [0, 0, 0]
                    channelsRise = [12, 12, 12]
                }
            }
        }
        updateFlowDone = true
        guard let release else { return }
        updateRelease = release
        // 업데이트가 있으면 주파수 버튼 없이 Update 버튼만
        await popUpdateButton(.offered)

        #if DEBUG
        // 테스트용: RAPI_UPDATE_AUTOINSTALL=1 이면 드래그 없이 바로 설치 시작
        if ProcessInfo.processInfo.environment["RAPI_UPDATE_AUTOINSTALL"] != nil {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            startInstall(release)
        }
        #endif
    }

    // 화면 아래에서 튀어나와 소리원 1/3 지점에 멈춤 (스프링 오버슛)
    private func popUpdateButton(_ phase: UpdatePhase) async {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            updatePhase = phase
            updatePos = updateStartPos
            updateOpacity = 1
            updateSinkOffset = 0
        }
        // 시작 좌표가 한 프레임 그려진 뒤에 애니메이션 시작
        try? await Task.sleep(nanoseconds: 30_000_000)
        playUpdatePop(phase)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) {
            updatePos = updateRestPos
        }
    }

    private func handleUpdateDragEnd() {
        updateDragStart = nil
        guard updatePhase == .offered, let release = updateRelease,
              dist(updateRef(updatePos), portalCenter) <= portalRadius else { return }
        startInstall(release)
    }

    // 포털에 넣으면: 채널 사이클과 같은 방식으로 빨려 들어가고, 포털 점멸 동안 다운로드·설치.
    // (주파수 버튼은 Update 버튼이 나올 때 이미 숨겨져 있음)
    // 성공하면 새 버전으로 재실행 (새 앱이 Updated 연출을 이어서 재생).
    private func startInstall(_ release: AppRelease) {
        updatePhase = .installing

        withAnimation(.easeIn(duration: 0.13)) { updateSinkOffset = sinkOffset }
        withAnimation(.easeIn(duration: 0.065).delay(0.065)) { updateOpacity = 0 }

        Task { @MainActor in
            do {
                let installed = try await AppUpdater.downloadAndInstall(release)
                // 새 앱을 켜기 전에 허밍을 0까지 줄인다
                await stopHum(fade: 0.8)
                AppUpdater.relaunch(bundle: installed.bundle, leftover: installed.leftover, version: release.version)
            } catch {
                // 실패하면 Update 버튼이 다시 튀어나와 재시도할 수 있게 한다
                print("Update failed: \(error)")
                await popUpdateButton(.offered)
            }
        }
    }

    // 오픈 인트로: 채널 버튼 3개가 디졸브되며 떠오름. (await 는 시작만 기다림)
    // 왼쪽 버튼부터 0.1초 간격으로 모션 시작 (앞 버튼이 끝나길 기다리지 않고 겹쳐서 진행).
    private func playIntro() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        let leftToRight = slots.indices.sorted { slots[$0].position.x < slots[$1].position.x }
        for (order, index) in leftToRight.enumerated() {
            withAnimation(.easeOut(duration: 0.8).delay(0.1 * Double(order))) {
                channelsOpacity[index] = 1
                channelsRise[index] = 0
            }
        }
    }

    // 업데이트 후 첫 실행: Updated 가 아래에서 튀어올라 2초 정지 → 디졸브로 사라짐.
    // 다 사라진 뒤 오픈 인트로가 이어진다.
    private func playUpdated() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        await popUpdateButton(.updated)
        // 스프링 안착(~0.5초) 후 2초 정지
        try await Task.sleep(nanoseconds: 500_000_000 + 2_000_000_000)
        withAnimation(.easeInOut(duration: 0.8)) {
            updateOpacity = 0
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        updatePhase = .none
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

    private func clampButtonPosition(_ raw: CGPoint, size: CGSize? = nil) -> CGPoint {
        let size = size ?? btnSize
        let x = min(max(raw.x, 7), 320 + 1 - size.width)
        // 버튼 중심 x가 화면 가운데 3분의 1에 있으면 바닥까지 내려갈 수 있음
        let btnCenterX = x + size.width / 2
        let inCenterThird = btnCenterX >= 320.0 / 3 && btnCenterX <= 320.0 * 2 / 3
        let yMax: CGFloat = inCenterThird ? (200 - size.height) : (200 - 8 - size.height)
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

// MARK: - Blob Lens Effect
//
// 소리원 블러 레이어에 볼록렌즈 굴절 + 가장자리 색수차. BlobLens.metal 참고.

private struct BlobLensEffect: ViewModifier {
    let center: CGPoint
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.layerEffect(
            ShaderLibrary.blobLens(
                .float2(center),
                .float(radius),
                .float(0.3),     // 굴절 강도: 중심 약 1.4배 확대
                .float(0.14)     // 색수차: 가장자리 약 17px, 안쪽에서도 약 5px
            ),
            maxSampleOffset: CGSize(width: 48, height: 48)
        )
    }
}

// MARK: - Update Blob
//
// 업데이트 버튼의 흰색 블러. blobsCanvas 와 같은 규칙(소리원 중심에 가까울수록 커짐, 소리원으로 클립)이지만
// 튀어오르는 스프링 애니메이션 매 프레임마다 지름을 다시 계산하도록 ref 를 animatableData 로 받는다.

private struct UpdateBlob: View, @preconcurrency Animatable {
    var ref: CGPoint
    let soundCenter: CGPoint
    let soundRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ref.x, ref.y) }
        set { ref = CGPoint(x: newValue.first, y: newValue.second) }
    }

    var body: some View {
        let d = sqrt(pow(ref.x - soundCenter.x, 2) + pow(ref.y - soundCenter.y, 2))
        let t = max(0, 1 - d / soundRadius)
        let diameter = 48 + (240 - 48) * t
        ZStack {
            if d <= soundRadius {
                Circle()
                    .fill(Color.white)
                    .frame(width: diameter, height: diameter)
                    .blur(radius: 20)
                    .opacity(0.28)  // 채널 블러(0.4)의 70%
                    .position(ref)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mask(
            Circle()
                .frame(width: soundRadius * 2, height: soundRadius * 2)
                .position(soundCenter)
        )
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
    // pan 필터 마지막 갱신 시각 (스로틀링). af 그래프 재빌드는 비용이 크므로 빈도 제한.
    private var lastPanUpdate: [RadioChannel: CFAbsoluteTime] = [:]
    private var loading: Set<RadioChannel> = []
    // 로딩 중 도착한 최신 목표값. startPlayback 시점에 이걸 적용해
    // 진입 시점의 스테일 값이 아닌 현재 위치의 볼륨/팬으로 재생을 시작.
    private var pendingTargets: [RadioChannel: (volume: Float, pan: Float)] = [:]
    private let lib = MpvLib.shared

    // pan 필터 재빌드 최소 간격. 60ms = 최대 ~16Hz 재빌드 빈도.
    private let panUpdateInterval: CFAbsoluteTime = 0.060

    func play(channel: RadioChannel, volume: Float, pan: Float) {
        guard lib.available else { return }

        if let mpv = channels[channel] {
            // 볼륨은 매 프레임 부드럽게 업데이트 (mpv soft property, 그래프 재빌드 없음)
            setVolume(mpv, volume: Double(volume * 100))

            // pan 은 0.05 단위로 양자화 + 60ms 스로틀.
            // af=lavfi=[pan=...] 갱신은 mpv 내부에서 audio filter graph 를 재빌드해
            // 매 호출마다 미세한 audio dropout 이 생김. 빈도를 낮춰 글리치 억제.
            let quantized = (pan * 20).rounded() / 20
            if currentPans[channel] != quantized {
                let now = CFAbsoluteTimeGetCurrent()
                let last = lastPanUpdate[channel] ?? 0
                if now - last >= panUpdateInterval {
                    currentPans[channel] = quantized
                    lastPanUpdate[channel] = now
                    updatePanFilter(mpv, pan: quantized)
                }
                // 스로틀로 드롭된 갱신은 다음 onChanged 호출에서 자연스럽게 따라잡음.
            }
        } else if loading.contains(channel) {
            // 로딩 중 — 최신 목표값만 기록해 두고 startPlayback 에서 사용
            pendingTargets[channel] = (volume, pan)
        } else {
            loading.insert(channel)
            pendingTargets[channel] = (volume, pan)
            Task {
                do {
                    let url = try await channel.resolveStreamURL()
                    await MainActor.run {
                        let target = self.pendingTargets[channel] ?? (volume, pan)
                        self.pendingTargets[channel] = nil
                        self.startPlayback(channel: channel, url: url.absoluteString, volume: target.volume, pan: target.pan)
                        self.loading.remove(channel)
                    }
                } catch {
                    print("Stream error [\(channel)]: \(error)")
                    await MainActor.run {
                        self.pendingTargets[channel] = nil
                        self.loading.remove(channel)
                    }
                }
            }
        }
    }

    func stop(channel: RadioChannel) {
        pendingTargets[channel] = nil
        lastPanUpdate[channel] = nil
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
