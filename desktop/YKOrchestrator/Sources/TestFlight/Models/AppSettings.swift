//
//  AppSettings.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

/// App-wide preferences governing how the publish pipeline collects a build
/// number. Both default to `true`, so the out-of-the-box behaviour is unchanged
/// (management on + one shared value across environments).
enum AppSettings {
    /// When `true`, the build number is asked for on every run. When `false`,
    /// the field is hidden and the pipeline silently submits `1`.
    static let buildNumberManagedKey = "FlightKit.settings.buildNumberManaged"

    /// Only meaningful when managed. `true` → one shared value across envs;
    /// `false` → one field/value per environment.
    static let buildNumberSharedKey = "FlightKit.settings.buildNumberShared"

    /// Build number sent in the background when management is disabled.
    static let unmanagedBuildNumber = "1"

    /// `UserDefaults.bool(forKey:)` returns `false` for a missing key, which would
    /// wrongly flip the default to "off". `object(forKey:)` distinguishes
    /// "no record" so the default stays `true` (matching `@AppStorage(...) = true`).
    static var buildNumberManaged: Bool {
        UserDefaults.standard.object(forKey: buildNumberManagedKey) as? Bool ?? true
    }
    static var buildNumberShared: Bool {
        UserDefaults.standard.object(forKey: buildNumberSharedKey) as? Bool ?? true
    }
}
