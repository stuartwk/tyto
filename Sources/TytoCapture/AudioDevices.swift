//
//  AudioDevices.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/6/26.
//

import Foundation
import CoreAudio

/// Queries about the machine's audio devices: which is default, what it's called,
/// what rate it runs at. Used to pick the aggregate's clock source now, and to
/// detect headphones vs speakers later.
package nonisolated enum AudioDevices {
    
    package static func defaultOutputID() -> AudioObjectID? {
        device(kAudioHardwarePropertyDefaultOutputDevice)
    }

    package static func defaultInputID() -> AudioObjectID? {
        device(kAudioHardwarePropertyDefaultInputDevice)
    }
    
    package static func uid(of deviceID: AudioObjectID) -> String? {
        CoreAudioHAL.string(kAudioDevicePropertyDeviceUID, from: deviceID)
    }

    package static func name(of deviceID: AudioObjectID) -> String? {
        CoreAudioHAL.string(kAudioObjectPropertyName, from: deviceID)
    }

    package static func sampleRate(of deviceID: AudioObjectID) -> Double? {
        CoreAudioHAL.value(kAudioDevicePropertyNominalSampleRate, from: deviceID)
    }
    
    private static func device(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        let id: AudioObjectID? = CoreAudioHAL.value(selector, from: CoreAudioHAL.systemObject)
        guard let id, id != CoreAudioHAL.unknownObject else { return nil }
        return id
    }
    
}
