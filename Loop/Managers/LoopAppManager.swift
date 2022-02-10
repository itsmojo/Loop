//
//  LoopAppManager.swift
//  Loop
//
//  Created by Darin Krauss on 2/16/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import UIKit
import Intents
import Combine
import LoopKit
import LoopKitUI
import MockKit

public protocol AlertPresenter: AnyObject {
    /// Present the alert view controller, with or without animation.
    /// - Parameters:
    ///   - viewControllerToPresent: The alert view controller to present.
    ///   - animated: Animate the alert view controller presentation or not.
    ///   - completion: Completion to call once view controller is presented.
    func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)?)

    /// Retract any alerts with the given identifier.  This includes both pending and delivered alerts.

    /// Dismiss the topmost view controller, presumably the alert view controller.
    /// - Parameters:
    ///   - animated: Animate the alert view controller dismissal or not.
    ///   - completion: Completion to call once view controller is dismissed.
    func dismissTopMost(animated: Bool, completion: (() -> Void)?)

    /// Dismiss an alert, even if it is not the top most alert.
    /// - Parameters:
    ///   - alertToDismiss: The alert to dismiss
    ///   - animated: Animate the alert view controller dismissal or not.
    ///   - completion: Completion to call once view controller is dismissed.
    func dismissAlert(_ alertToDismiss: UIAlertController, animated: Bool, completion: (() -> Void)?)
}

public extension AlertPresenter {
    func present(_ viewController: UIViewController, animated: Bool) { present(viewController, animated: animated, completion: nil) }
    func dismissTopMost(animated: Bool) { dismissTopMost(animated: animated, completion: nil) }
    func dismissAlert(_ alertToDismiss: UIAlertController, animated: Bool) { dismissAlert(alertToDismiss, animated: animated, completion: nil) }
}

protocol WindowProvider: AnyObject {
    var window: UIWindow? { get }
}

class LoopAppManager: NSObject {
    private enum State: Int {
        case initialize
        case checkProtectedDataAvailable
        case launchManagers
        case launchOnboarding
        case launchHomeScreen
        case launchComplete

        var next: State { State(rawValue: rawValue + 1) ?? .launchComplete }
    }

    private weak var windowProvider: WindowProvider?
    private var launchOptions: [UIApplication.LaunchOptionsKey: Any]?

    private var pluginManager: PluginManager!
    private var bluetoothStateManager: BluetoothStateManager!
    private var alertManager: AlertManager!
    private var loopAlertsManager: LoopAlertsManager!
    private var trustedTimeChecker: TrustedTimeChecker!
    private var deviceDataManager: DeviceDataManager!
    private var onboardingManager: OnboardingManager!
    private var alertPermissionsChecker: AlertPermissionsChecker!
    private var supportManager: SupportManager!

    private var state: State = .initialize

    private let log = DiagnosticLog(category: "LoopAppManager")

    private let closedLoopStatus = ClosedLoopStatus(isClosedLoop: false, isClosedLoopAllowed: false)

    lazy private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    func initialize(windowProvider: WindowProvider, launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(state == .initialize)

        self.windowProvider = windowProvider
        self.launchOptions = launchOptions
        
        if FeatureFlags.siriEnabled && INPreferences.siriAuthorizationStatus() == .notDetermined {
            INPreferences.requestSiriAuthorization { _ in }
        }

        registerBackgroundTasks()

        self.state = state.next
    }

    func launch() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(isLaunchPending)

        resumeLaunch()
        finishLaunch()
    }

    var isLaunchPending: Bool { state == .checkProtectedDataAvailable }

    var isLaunchComplete: Bool { state == .launchComplete }

    private func resumeLaunch() {
        if state == .checkProtectedDataAvailable {
            checkProtectedDataAvailable()
        }
        if state == .launchManagers {
            launchManagers()
        }
        if state == .launchOnboarding {
            launchOnboarding()
        }
        if state == .launchHomeScreen {
            launchHomeScreen()
        }
    }

    private func checkProtectedDataAvailable() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(state == .checkProtectedDataAvailable)

        guard isProtectedDataAvailable() else {
            log.default("Protected data not available; deferring launch...")
            return
        }

        self.state = state.next
    }

    private func launchManagers() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(state == .launchManagers)

        windowProvider?.window?.tintColor = .loopAccent
        OrientationLock.deviceOrientationController = self
        UNUserNotificationCenter.current().delegate = self

        self.pluginManager = PluginManager()
        self.bluetoothStateManager = BluetoothStateManager()
        self.alertManager = AlertManager(alertPresenter: self,
                                         expireAfter: Bundle.main.localCacheDuration)
        self.alertPermissionsChecker = AlertPermissionsChecker(alertManager: alertManager)
        self.loopAlertsManager = LoopAlertsManager(alertManager: alertManager,
                                                   bluetoothProvider: bluetoothStateManager)
        self.trustedTimeChecker = TrustedTimeChecker(alertManager: alertManager)
        self.deviceDataManager = DeviceDataManager(pluginManager: pluginManager,
                                                   alertManager: alertManager,
                                                   bluetoothProvider: bluetoothStateManager,
                                                   alertPresenter: self,
                                                   closedLoopStatus: closedLoopStatus)
        SharedLogging.instance = deviceDataManager.loggingServicesManager

        scheduleBackgroundTasks()

        self.onboardingManager = OnboardingManager(pluginManager: pluginManager,
                                                   bluetoothProvider: bluetoothStateManager,
                                                   deviceDataManager: deviceDataManager,
                                                   servicesManager: deviceDataManager.servicesManager,
                                                   loopDataManager: deviceDataManager.loopManager,
                                                   windowProvider: windowProvider,
                                                   userDefaults: UserDefaults.appGroup!)

        deviceDataManager.onboardingManager = onboardingManager
        deviceDataManager.analyticsServicesManager.application(didFinishLaunchingWithOptions: launchOptions)

        supportManager = SupportManager(pluginManager: pluginManager,
                                        deviceDataManager: deviceDataManager,
                                        servicesManager: deviceDataManager.servicesManager,
                                        alertIssuer: alertManager)

        closedLoopStatus.$isClosedLoopAllowed
            .combineLatest(deviceDataManager.loopManager.$dosingEnabled)
            .map { $0 && $1 }
            .assign(to: \.closedLoopStatus.isClosedLoop, on: self)
            .store(in: &cancellables)

        self.state = state.next
    }

    private func launchOnboarding() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(state == .launchOnboarding)

        onboardingManager.launch {
            DispatchQueue.main.async {
                self.state = self.state.next
                self.resumeLaunch()
            }
        }
    }

    private func launchHomeScreen() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(state == .launchHomeScreen)

        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: Self.self))
        let statusTableViewController = storyboard.instantiateViewController(withIdentifier: "MainStatusViewController") as! StatusTableViewController
        statusTableViewController.alertPermissionsChecker = alertPermissionsChecker
        statusTableViewController.closedLoopStatus = closedLoopStatus
        statusTableViewController.deviceManager = deviceDataManager
        statusTableViewController.onboardingManager = onboardingManager
        statusTableViewController.supportManager = supportManager
        bluetoothStateManager.addBluetoothObserver(statusTableViewController)

        var rootNavigationController = rootViewController as? RootNavigationController
        if rootNavigationController == nil {
            rootNavigationController = RootNavigationController()
            rootViewController = rootNavigationController
        }
        rootNavigationController?.setViewControllers([statusTableViewController], animated: true)

        deviceDataManager.refreshDeviceData()

        handleRemoteNotificationFromLaunchOptions()

        self.launchOptions = nil

        self.state = state.next
    }

    private func finishLaunch() {
        guard !isLaunchPending else {
            return
        }

        alertManager.playbackAlertsFromPersistence()
    }

    // MARK: - Life Cycle

    func didBecomeActive() {
        if let rootViewController = rootViewController {
            ProfileExpirationAlerter.alertIfNeeded(viewControllerToPresentFrom: rootViewController)
        }
        deviceDataManager?.didBecomeActive()
    }

    // MARK: - Remote Notification

    func setRemoteNotificationsDeviceToken(_ remoteNotificationsDeviceToken: Data) {
        deviceDataManager?.loopManager.mutateSettings {
            settings in settings.deviceToken = remoteNotificationsDeviceToken
        }
    }

    private func handleRemoteNotificationFromLaunchOptions() {
        handleRemoteNotification(launchOptions?[.remoteNotification] as? [String: AnyObject])
    }

    @discardableResult
    func handleRemoteNotification(_ notification: [String: AnyObject]?) -> Bool {
        guard let notification = notification else {
            return false
        }
        deviceDataManager?.handleRemoteNotification(notification)
        return true
    }

    // MARK: - Continuity

    func userActivity(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        if userActivity.activityType == NewCarbEntryIntent.className {
            log.default("Restoring %{public}@ intent", userActivity.activityType)
            rootViewController?.restoreUserActivityState(.forNewCarbEntry())
            return true
        }

        switch userActivity.activityType {
        case NSUserActivity.newCarbEntryActivityType,
             NSUserActivity.viewLoopStatusActivityType:
            log.default("Restoring %{public}@ activity", userActivity.activityType)
            if let rootViewController = rootViewController {
                restorationHandler([rootViewController])
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Interface

    private static let defaultSupportedInterfaceOrientations = UIInterfaceOrientationMask.allButUpsideDown

    var supportedInterfaceOrientations = defaultSupportedInterfaceOrientations

    // MARK: - Background Tasks

    private func registerBackgroundTasks() {
        if DeviceDataManager.registerCriticalEventLogHistoricalExportBackgroundTask({ self.deviceDataManager?.handleCriticalEventLogHistoricalExportBackgroundTask($0) }) {
            log.debug("Critical event log export background task registered")
        } else {
            log.error("Critical event log export background task not registered")
        }
    }

    private func scheduleBackgroundTasks() {
        deviceDataManager?.scheduleCriticalEventLogHistoricalExportBackgroundTask()
    }

    // MARK: - Private

    private func isProtectedDataAvailable() -> Bool {
        let fileManager = FileManager.default
        do {
            let documentDirectory = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let fileURL = documentDirectory.appendingPathComponent("protection.test")
            guard fileManager.fileExists(atPath: fileURL.path) else {
                let contents = Data("unimportant".utf8)
                try? contents.write(to: fileURL, options: .completeFileProtectionUntilFirstUserAuthentication)
                // If file doesn't exist, we're at first start, which will be user directed.
                return true
            }
            let contents = try? Data(contentsOf: fileURL)
            return contents != nil
        } catch {
            log.error("Could not create after first unlock test file: %@", String(describing: error))
        }
        return false
    }

    private var rootViewController: UIViewController? {
        get { windowProvider?.window?.rootViewController }
        set { windowProvider?.window?.rootViewController = newValue }
    }
}

// MARK: - AlertPresenter

extension LoopAppManager: AlertPresenter {
    func present(_ viewControllerToPresent: UIViewController, animated: Bool, completion: (() -> Void)?) {
        rootViewController?.topmostViewController.present(viewControllerToPresent, animated: animated, completion: completion)
    }

    func dismissTopMost(animated: Bool, completion: (() -> Void)?) {
        rootViewController?.topmostViewController.dismiss(animated: animated, completion: completion)
    }

    func dismissAlert(_ alertToDismiss: UIAlertController, animated: Bool, completion: (() -> Void)?) {
        if rootViewController?.topmostViewController == alertToDismiss {
            dismissTopMost(animated: animated, completion: completion)
        } else {
            // check if the alert to dismiss is presenting another alert (and so on)
            // calling dismiss() on an alert presenting another alert will only dismiss the presented alert
            // (and any other alerts presented by the presented alert)

            // get the stack of presented alerts that would be undesirably dismissed
            var presentedAlerts: [UIAlertController] = []
            var currentAlert = alertToDismiss
            while let presentedAlert = currentAlert.presentedViewController as? UIAlertController {
                presentedAlerts.append(presentedAlert)
                currentAlert = presentedAlert
            }

            if presentedAlerts.isEmpty {
                alertToDismiss.dismiss(animated: animated, completion: completion)
            } else {
                // Do not animate any of these view transitions, since the alert to dismiss is not at the top of the stack

                // dismiss all the child presented alerts.
                // Calling dismiss() on a VC that is presenting an other VC will dismiss the presented VC and all of its child presented VCs
                alertToDismiss.dismiss(animated: false) {
                    // dismiss the desired alert
                    // Calling dismiss() on a VC that is NOT presenting any other VCs will dismiss said VC
                    alertToDismiss.dismiss(animated: false) {
                        // present the child alerts that were undesirably dismissed
                        var orderedPresentationBlock: (() -> Void)? = nil
                        for alert in presentedAlerts.reversed() {
                            if alert == presentedAlerts.last {
                                orderedPresentationBlock = {
                                    self.present(alert, animated: false, completion: completion)
                                }
                            } else {
                                orderedPresentationBlock = {
                                    self.present(alert, animated: false, completion: orderedPresentationBlock)
                                }
                            }
                        }
                        orderedPresentationBlock?()
                    }
                }
            }
        }
    }
}

// MARK: - DeviceOrientationController

extension LoopAppManager: DeviceOrientationController {
    func setDefaultSupportedInferfaceOrientations() {
        supportedInterfaceOrientations = Self.defaultSupportedInterfaceOrientations
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension LoopAppManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        switch notification.request.identifier {
        // TODO: Until these notifications are converted to use the new alert system, they shall still show in the foreground
        case LoopNotificationCategory.bolusFailure.rawValue,
             LoopNotificationCategory.pumpBatteryLow.rawValue,
             LoopNotificationCategory.pumpExpired.rawValue,
             LoopNotificationCategory.pumpFault.rawValue:
            completionHandler([.badge, .sound, .list, .banner])
        default:
            // All other userNotifications are not to be displayed while in the foreground
            completionHandler([])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case NotificationManager.Action.retryBolus.rawValue:
            if  let units = response.notification.request.content.userInfo[LoopNotificationUserInfoKey.bolusAmount.rawValue] as? Double,
                let startDate = response.notification.request.content.userInfo[LoopNotificationUserInfoKey.bolusStartDate.rawValue] as? Date,
                startDate.timeIntervalSinceNow >= TimeInterval(minutes: -5)
            {
                deviceDataManager?.analyticsServicesManager.didRetryBolus()
                
                deviceDataManager?.enactBolus(units: units, automatic: false) { (_) in
                    DispatchQueue.main.async {
                        completionHandler()
                    }
                }
                return
            }
        case NotificationManager.Action.acknowledgeAlert.rawValue:
            let userInfo = response.notification.request.content.userInfo
            if let alertIdentifier = userInfo[LoopNotificationUserInfoKey.alertTypeID.rawValue] as? Alert.AlertIdentifier,
               let managerIdentifier = userInfo[LoopNotificationUserInfoKey.managerIDForAlert.rawValue] as? String {
                alertManager?.acknowledgeAlert(identifier: Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: alertIdentifier))
            }
        default:
            break
        }

        completionHandler()
    }
}