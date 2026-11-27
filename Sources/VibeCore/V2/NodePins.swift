// The Mac node's record of its builds' code, `NodePins`, is the keeper's package's (Keeper/Sources/VibeKeep/NodePins.swift,
// moved there whole and unchanged: one parser for the record the node's checks and the keeper read). Exported, as
// VibePlatform is (PlatformExport.swift), so every module that imports VibeCore names it as before, `NodePins.Build`
// and `NodePins.Refused` included, with no import of its own.
@_exported import VibeKeep
