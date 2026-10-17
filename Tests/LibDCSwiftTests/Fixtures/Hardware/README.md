# Hardware recordings

`.dcrec` recordings of real dive computers on real cables, made by `SerialHardwareTests` and replayed by
`SerialReplayTests.testCommittedHardwareRecordingsReplay`. The recorder swaps the computer's serial for a
stand-in, but the dives (dates, and positions on computers that log them) are as the computer sent them, so
commit a recording only for dives that are fine to publish. See `Docs/MACOS_SERIAL_CABLES.md`.
