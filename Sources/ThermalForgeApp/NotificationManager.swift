//
//  NotificationManager.swift
//  ThermalForgeApp
//
//  Native macOS desktop notifications for thermal safety alerts.
//

import Foundation
import UserNotifications
import ThermalForgeCore

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                TFLogger.shared.error("Notification authorization failed: \(error)")
            } else {
                TFLogger.shared.info("Notification authorization granted: \(granted)")
            }
        }
    }

    func sendSafetyAlert(sensorTemp: Float, limitTemp: Float) {
        let content = UNMutableNotificationContent()
        content.title = "ThermalForge Safety Alert"
        content.body = "A sensor reached \(Int(round(sensorTemp)))°C (safety limit: \(Int(round(limitTemp)))°C). Fans are locked at 100% maximum speed."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "thermalforge.safety.upperlimit.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                TFLogger.shared.error("Failed to post safety notification: \(error)")
            } else {
                TFLogger.shared.safety("Posted desktop safety notification for \(sensorTemp)°C (limit: \(limitTemp)°C)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
