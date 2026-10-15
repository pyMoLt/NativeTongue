// Excerpts from mattt/coreai-kit (BSD-3-Clause): ModelRuntime.swift, Audio/AudioRuntime.swift.
import Foundation

@available(macOS 27.0, iOS 27.0, *)
public enum EngineVariant: String, Sendable {
    /// Auto-detect from the model structure (pipelined for dynamic models).
    case auto
    /// GPU-pipelined engine: fastest streaming chat, no per-step logits.
    case pipelined = "coreai-pipelined"
    /// Step-synchronous engine: per-step logits (required for guided generation).
    case sequential = "coreai-sequential"
    /// Neural Engine oriented engine for chunked static (AOT) bundles.
    case staticShape = "static-shape"

    /// The factory override string; nil = auto-detection.
    var factoryOverride: String? { self == .auto ? nil : rawValue }

    /// The engine a catalog entry's `engine` hint names. An unknown hint (a newer catalog
    /// than this build) degrades to `.auto`, mirroring `CatalogEntry.Kind.unknown`.
    init(catalogHint: String?) {
        switch catalogHint {
        case "sequential": self = .sequential
        case "pipelined": self = .pipelined
        case "static-shape": self = .staticShape
        default: self = .auto
        }
    }
}

@available(macOS 27.0, iOS 27.0, *)
public enum KitAudioError: Error, LocalizedError {
    case noMetalDevice
    case bufferAllocationFailed
    case encoderOutputMissing(String)
    case audioTooLong(tokens: Int, max: Int)
    case melFiltersMissing
    case unsupportedSampleRate(Int)
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .renderFailed(let why): return "Audio prompt render failed: \(why)"
        case .noMetalDevice: return "No Metal device available for the audio runtime."
        case .bufferAllocationFailed: return "Could not allocate the audio static-input buffer."
        case .encoderOutputMissing(let name):
            return "Audio encoder did not produce the expected output '\(name)'."
        case .audioTooLong(let tokens, let max):
            return "Clip has \(tokens) audio tokens but the bundle accepts at most \(max)."
        case .melFiltersMissing:
            return "Bundled mel_filters.f32 resource was not found in CoreAIKit."
        case .unsupportedSampleRate(let sr):
            return "Audio must be 16 kHz mono; got \(sr) Hz (resample before attaching)."
        }
    }
}

// Excerpt from mattt/coreai-kit CoreAIKitVision.
@available(macOS 27.0, iOS 27.0, *)
public enum VisionError: Error, LocalizedError, Sendable {
    case functionNotFound(String)
    case statefulGraphUnsupported([String])
    case unknownInput(String)
    case shapeMismatch(input: String, expected: [Int], got: [Int])
    case dtypeMismatch(input: String, expected: String)
    case unsupportedScalarType(String)
    case missingOutput(String)
    case bundleLayout(String)
    case imageRenderFailed
    case cameraAccessDenied
    case cameraUnavailable

    public var errorDescription: String? {
        switch self {
        case .functionNotFound(let name):
            return "Graph function '\(name)' not found in model"
        case .statefulGraphUnsupported(let states):
            return "GraphModel runs stateless graphs only; model declares states \(states)"
        case .unknownInput(let name):
            return "Model has no input named '\(name)'"
        case .shapeMismatch(let input, let expected, let got):
            return "Input '\(input)' expects shape \(expected), got \(got)"
        case .dtypeMismatch(let input, let expected):
            return "Input '\(input)' expects \(expected) scalars"
        case .unsupportedScalarType(let type):
            return "Unsupported scalar type \(type)"
        case .missingOutput(let name):
            return "Output '\(name)' missing after run"
        case .bundleLayout(let message):
            return message
        case .imageRenderFailed:
            return "Failed to render the preprocessed image"
        case .cameraAccessDenied:
            return "Camera access was denied"
        case .cameraUnavailable:
            return "No usable camera was found"
        }
    }
}
