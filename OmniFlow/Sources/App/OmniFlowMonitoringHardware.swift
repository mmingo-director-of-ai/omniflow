// Copyright (c) 2026 Quandry Labs (MIT).
import Darwin
import Foundation

enum OmniFlowSystemThermalCondition: String, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

enum OmniFlowFanNoiseEstimate: String, Equatable, Sendable {
    case stopped
    case nearlySilent
    case quiet
    case audible
    case highAirflow

    static func estimate(rpm: Double, utilization: Double) -> OmniFlowFanNoiseEstimate {
        if rpm < 100 { return .stopped }
        switch utilization {
        case ..<0.25: return .nearlySilent
        case ..<0.45: return .quiet
        case ..<0.70: return .audible
        default: return .highAirflow
        }
    }
}

struct OmniFlowFanTelemetry: Equatable, Sendable {
    let count: Int
    let averageRPM: Double
    let maximumRPM: Double

    var utilization: Double {
        guard maximumRPM > 0 else { return 0 }
        return min(1, max(0, averageRPM / maximumRPM))
    }

    var noiseEstimate: OmniFlowFanNoiseEstimate {
        .estimate(rpm: averageRPM, utilization: utilization)
    }
}

struct OmniFlowHardwareTelemetrySample: Equatable, Sendable {
    enum PowerSource: String, Equatable, Sendable {
        case smcTotal
        case systemLoad
    }

    let thermalCondition: OmniFlowSystemThermalCondition
    let temperatureCelsius: Double?
    let temperatureSource: String?
    let systemPowerWatts: Double?
    let powerSource: PowerSource?
    let fan: OmniFlowFanTelemetry?

    static let placeholder = OmniFlowHardwareTelemetrySample(
        thermalCondition: .unknown,
        temperatureCelsius: nil,
        temperatureSource: nil,
        systemPowerWatts: nil,
        powerSource: nil,
        fan: nil
    )
}

/// Public telemetry only. SMC/IOHID sensor probing
/// is deliberately not carried into this distribution target.
final class OmniFlowHardwareTelemetryReader {
    func sample() -> OmniFlowHardwareTelemetrySample {
        .init(thermalCondition: .init(ProcessInfo.processInfo.thermalState),
              temperatureCelsius: nil, temperatureSource: nil,
              systemPowerWatts: nil, powerSource: nil, fan: nil)
    }
}
