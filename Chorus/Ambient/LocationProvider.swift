import CoreLocation
import Foundation
import Observation

/// 所在地座標——**只**拿來算日出日落（時間排程的 sunTracking）。
///
/// 三公里精度就夠（日出時間對經度的敏感度是 4 分鐘／度）。一拿到座標就停，
/// 並存進設定：之後離線、Mac mini 沒 Wi-Fi 定不到位、甚至使用者事後關掉定位，
/// 都還能用最後一次座標算。座標不離開這台 Mac、不進備份、不同步給 peer。
@MainActor
@Observable
final class LocationProvider {
    struct Coordinate: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    /// 最後一次成功定位（含上次啟動存下的）。
    private(set) var coordinate: Coordinate?
    private(set) var status: CLAuthorizationStatus
    /// 定位失敗的說明（UI 顯示用）。
    private(set) var lastError: String?
    /// 是否正在等第一次定位結果。
    private(set) var isLocating = false

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let manager: CLLocationManager
    @ObservationIgnored private let bridge: DelegateBridge

    init(settings: SettingsStore) {
        self.settings = settings
        if let stored = settings.ambientLocation, stored.count == 2 {
            coordinate = Coordinate(latitude: stored[0], longitude: stored[1])
        }
        manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        status = manager.authorizationStatus
        bridge = DelegateBridge()
        manager.delegate = bridge
        bridge.owner = self
    }

    /// 要求授權並定位一次。已授權就直接定位；被拒只更新狀態，呼叫端沿用手動時間。
    ///
    /// macOS 上光呼叫 `requestWhenInUseAuthorization()` **常常不會跳授權對話框**
    /// （Apple 論壇 thread 758697；Mac mini 實測也沒跳）——真正觸發對話框的是
    /// 開始定位。所以 notDetermined 時兩個都叫：先請求授權，再 startUpdatingLocation；
    /// 系統要嘛跳框、要嘛（已決定過）直接給座標。拿到第一筆就 stop。
    func refresh() {
        lastError = nil
        status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            isLocating = true
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
        case .authorizedAlways:
            isLocating = true
            manager.startUpdatingLocation()
        default:
            isLocating = false
        }
    }

    /// 診斷用（TestHooks dump）。
    var statusDescription: String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "authorizedAlways"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    #if DEBUG
    /// TestHooks：不經 TCC 直接給座標。
    func inject(latitude: Double, longitude: Double) {
        store(Coordinate(latitude: latitude, longitude: longitude))
    }
    #endif

    // MARK: - 私有

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        self.status = status
        if status == .authorizedAlways, isLocating {
            manager.startUpdatingLocation()
        } else if status == .denied || status == .restricted {
            isLocating = false
            manager.stopUpdatingLocation()
        }
    }

    fileprivate func received(_ coordinate: Coordinate) {
        store(coordinate)
    }

    fileprivate func failed(_ message: String) {
        // 授權對話框還開著時 CoreLocation 會先回一次 denied 類的錯，不算失敗；
        // 使用者按下允許後 didUpdateLocations 照樣會來
        guard status != .notDetermined else { return }
        isLocating = false
        lastError = message
        manager.stopUpdatingLocation()
    }

    private func store(_ coordinate: Coordinate) {
        manager.stopUpdatingLocation()
        self.coordinate = coordinate
        isLocating = false
        lastError = nil
        settings.ambientLocation = [coordinate.latitude, coordinate.longitude]
    }

    /// CLLocationManagerDelegate 不是 MainActor 協定，用一個小橋接物件收回呼，
    /// 再跳回主 actor 更新狀態。
    private final class DelegateBridge: NSObject, CLLocationManagerDelegate {
        weak var owner: LocationProvider?

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let status = manager.authorizationStatus
            Task { @MainActor [owner] in owner?.authorizationChanged(status) }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let last = locations.last else { return }
            let coordinate = Coordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
            Task { @MainActor [owner] in owner?.received(coordinate) }
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
            let message = error.localizedDescription
            Task { @MainActor [owner] in owner?.failed(message) }
        }
    }
}
