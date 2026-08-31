@_exported import LibDCBridge

/// Bump this string on every push a tester needs to verify against --
/// pastable proof of which commit a bug report's logs actually came from.
/// Added after a tester's logs kept showing a pre-fix failure mode after a
/// push that should have changed it, most likely because they were re-
/// downloading a ZIP snapshot rather than `git pull`ing, so there was no
/// way to tell "still broken" apart from "running old code" from logs alone.
public let libDCSwiftBuildTag = "2026-09-01-nautic-fromname"