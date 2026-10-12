//
//  PreviewWindowCaptureExclusion.swift
//  Screendrop
//
//  Created by Codex on 27/04/26.
//

import AppKit
import SwiftUI

@MainActor
final class PreviewWindowCaptureExclusion {
    static let shared = PreviewWindowCaptureExclusion()

    /// Whether Screendrop's UI should be available to screenshot and screen
    /// recording APIs. Opt in via Settings; the pre-record reminder can turn it off.
    static var includesAppWindowsInCaptures: Bool {
        ScreendropPreferences.includeAppWindowsInCaptures
    }

    private let registeredWindows = NSHashTable<NSWindow>.weakObjects()

    private init() {}

    /// Registers any Screendrop-owned window whose capture visibility should
    /// follow the production preference.
    func register(window: NSWindow?) {
        guard let window else { return }

        registeredWindows.add(window)
        applyCaptureVisibility(to: window)
    }

    /// Applies a changed preference immediately to windows that already
    /// exist, rather than waiting for them to be recreated.
    func refreshRegisteredWindows() {
        for window in registeredWindows.allObjects {
            applyCaptureVisibility(to: window)
        }
    }

    private func applyCaptureVisibility(to window: NSWindow) {
        window.sharingType = Self.includesAppWindowsInCaptures ? .readOnly : .none
    }
}
