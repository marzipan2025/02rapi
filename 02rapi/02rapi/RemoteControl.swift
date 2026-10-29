import Foundation
import MediaPlayer
import CoreAudio

// 외부 재생/정지 명령 — 에어팟·블루투스 이어폰 버튼, 키보드 재생 키(F8), 제어 센터 재생 위젯.
// macOS 는 이 명령을 "지금 재생 중인 앱" 하나에만 보내므로, RAPI 를 그 앱으로 등록해 두고
// 명령은 알림으로 바꿔 ContentView 가 받는다.
// 이어폰 연결이 끊겨 기본 출력 장치가 사라질 때도 정지 알림을 보낸다 (소리가 스피커로 넘어가지 않게).
@MainActor
final class RemoteControl {
    static let shared = RemoteControl()

    private var lastOutputDevice: AudioObjectID = 0
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: .remotePlay, object: nil)
            return .success
        }
        center.pauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .remotePause, object: nil)
            return .success
        }
        center.stopCommand.addTarget { _ in
            NotificationCenter.default.post(name: .remotePause, object: nil)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .remoteToggle, object: nil)
            return .success
        }
        setPlaying(true)

        lastOutputDevice = Self.defaultOutputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            MainActor.assumeIsolated { RemoteControl.shared.outputDeviceChanged() }
        }
    }

    private func outputDeviceChanged() {
        let previous = lastOutputDevice
        lastOutputDevice = Self.defaultOutputDevice()
        // 다른 장치로 직접 바꾼 게 아니라, 쓰던 장치가 목록에서 사라졌을 때만 정지
        if previous != 0 && !Self.outputDevices().contains(previous) {
            NotificationCenter.default.post(name: .remotePause, object: nil)
        }
    }

    // 제어 센터·외부 장치에 보이는 재생 상태
    func setPlaying(_ playing: Bool) {
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "RAPI",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        info.playbackState = playing ? .playing : .paused
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func outputDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        return devices
    }
}

extension Notification.Name {
    static let remotePlay = Notification.Name("remotePlay")
    static let remotePause = Notification.Name("remotePause")
    static let remoteToggle = Notification.Name("remoteToggle")
}
