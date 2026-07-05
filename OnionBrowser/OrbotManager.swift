//
//  OrbotManager.swift
//  OnionBrowser
//
//  Copyright © 2012 - 2023, Tigas Ventures, LLC (Mike Tigas)
//
//  This file is part of Onion Browser. See LICENSE file for redistribution terms.
//

import Foundation
import OrbotKit

class OrbotManager : NSObject, OrbotStatusChangeListener {

	static let shared = OrbotManager()

#if DEBUG
	#if targetEnvironment(simulator)
		static let simulatorIgnoreOrbot = true
	#else
		static let simulatorIgnoreOrbot = false
	#endif
#endif

	// MARK: OnionManager instance

	public private(set) var lastInfo: OrbotKit.Info?

	public private(set) var lastError: Error?

	// MARK: Public Methods

	@discardableResult
	func closeCircuits(_ circuits: [OrbotKit.TorCircuit]) async -> Bool {
		var groupSuccess = false

		for circuit in circuits {
			let singleSuccess: Bool = await withCheckedContinuation { continuation in
				OrbotKit.shared.closeCircuit(circuit: circuit) { success, error in
					if let error = error {
						Log.error(for: Self.self, "#closeCircuits error=\(error)")
					}

					continuation.resume(returning: success)
				}
			}

			// If only one call succeeds, we count that as a success.
			if singleSuccess {
				groupSuccess = true
			}
		}

		return groupSuccess
	}

	/**
	Get all fully built circuits and detailed info about their nodes.

	- parameter callback: Called, when all info is available.
	- returns: A list of circuits and the nodes they consist of.
	*/
	func getCircuits(host: String?) async -> [OrbotKit.TorCircuit] {
		do {
			return try await withCheckedThrowingContinuation { continuation in
				OrbotKit.shared.circuits { circuits, error in
					if let error {
						return continuation.resume(throwing: error)
					}

					continuation.resume(returning: circuits ?? [])
				}
			}
		}
		catch {
			Log.error(for: Self.self, "#getCircuits error=\(error)")

			return []
		}
	}

	/**
	 Check's Orbot's status, and if not working, returns a view controller to show instead of the browser UI.

	 Starts a continuous Orbot status change check, if successful.

	 - returns: A view controller to show instead of the browser UI, if status is not good.
	 */
	func checkStatus() -> UIViewController? {
		OrbotKit.shared.removeStatusChangeListener(self)

		if !Settings.didWelcome {
			#if DEBUG
			#if targetEnvironment(simulator)
				// Auto-complete onboarding in simulator, use built-in Tor.
				Settings.didWelcome = true
				Settings.useBuiltInTor = true
				Settings.updateAdvertiseLockdownMode = true

				// Skip welcome screen, fall through to built-in Tor path below.
			#endif
			#endif

			if !Settings.didWelcome {
				return WelcomeViewController()
			}
		}

		if #available(iOS 17.0, *) {
			if let useBuiltinTor = Settings.useBuiltInTor {
				if useBuiltinTor {
					// User wants to use built-in Tor. Start it silently in the
					// background and show the browser immediately. Tor will be
					// ready by the time the user navigates to a .onion site.
					if TorManager.shared.status != .started && TorManager.shared.status != .starting {
						TorManager.shared.start(Settings.transport,
							{ _, _ in },
							{ _ in
								DispatchQueue.main.async {
									// Tor is ready: register the scheme handler on all
									// open tabs and retry any pending .onion loads.
									AppDelegate.shared?.allOpenTabs.forEach { $0.ensureProxyAndReload() }

									AppDelegate.shared?.sceneDelegates.forEach { delegate in
										delegate.browsingUi.updateChrome()
									}
								}
							})
					}

					// Always show the browser UI. Tor runs in the background.
					AppDelegate.shared?.allOpenTabs.forEach { $0.ensureProxyAndReload() }
					return nil
				}

				// User decided against built-in Tor.
				// Continue with Orbot flow.
			}
			else {
				// User did not decide, yet.

				return OrbotOrBuiltInViewController()
			}
		}

		if !OrbotKit.shared.installed {
			return InstallViewController()
		}

		if !hasOrbotPermission() {
			let vc = PermissionViewController()
			vc.error = lastError

			return vc
		}

		// simulatorIgnoreOrbot bypass removed - simulator now uses built-in Tor path above.

		if lastInfo?.status == .stopped || lastInfo?.onionOnly ?? false {
			return StartOrbotViewController()
		}

		OrbotKit.shared.notifyOnStatusChanges(self)

		return nil
	}

	func allowRequests() -> Bool {
		if Settings.useBuiltInTor == true, #available(iOS 17.0, *) {
			return TorManager.shared.status == .started
		}
		else {
			// simulatorIgnoreOrbot bypass removed - simulator uses built-in Tor.

			let status = lastInfo?.status
			return status == .starting || status == .started
		}
	}


	// MARK: OrbotStatusChangeListener

	func orbotStatusChanged(info: OrbotKit.Info) {
		guard lastInfo?.status != info.status || lastInfo?.onionOnly != info.onionOnly else {
			lastInfo = info

			return
		}

		lastInfo = info

		Task {
			await MainActor.run {
				if info.status == .stopped || info.onionOnly {
					fullStop()

					for delegate in AppDelegate.shared?.sceneDelegates ?? [] {
						delegate.show(checkStatus())
					}
				}
				else {
					for delegate in AppDelegate.shared?.sceneDelegates ?? [] {
						delegate.show()
					}
				}
			}
		}
	}

	func statusChangeListeningStopped(error: Error) {
		lastError = error

		Task {
			await MainActor.run {
				fullStop()

				for delegate in AppDelegate.shared?.sceneDelegates ?? [] {
					delegate.show(checkStatus())
				}
			}
		}
	}


	// MARK: Private Methods

	private func hasOrbotPermission() -> Bool {
		let token = Settings.orbotApiToken

		if token?.isEmpty ?? true || token == Settings.orbotAccessDenied {
			return false
		}

		OrbotKit.shared.apiToken = token

		let group = DispatchGroup()
		group.enter()

		OrbotKit.shared.info { info, error in
			self.lastInfo = info
			self.lastError = error

			group.leave()
		}

		let result = group.wait(timeout: .now() + 1)

		return result != .timedOut && lastError == nil
	}

	/**
	Cancel all connections and re-evalutate Orbot situation and show respective UI.
	*/
	@MainActor
	private func fullStop() {
		for tab in AppDelegate.shared?.allOpenTabs ?? [] {
			tab.stop()
		}
	}
}
