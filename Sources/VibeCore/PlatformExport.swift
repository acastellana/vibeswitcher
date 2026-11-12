// The platform layer, for every file of VibeCore and everything that imports VibeCore: no call site needs an import.
@_exported import VibePlatform

// CryptoKit's names (SHA256, HMAC, SymmetricKey, ChaChaPoly, P256…) the same way: Apple's CryptoKit where there is
// one, and elsewhere swift-crypto's Crypto, which has the same API. The one file outside the platform layer that asks
// which it's on (`PlatformLintTests` exempts it).
#if canImport(CryptoKit)
@_exported import CryptoKit
#else
@_exported import Crypto
#endif
