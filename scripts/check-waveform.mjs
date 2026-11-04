// Render the app's actual SwiftUI waveform on macOS; no simulator or audio file needed.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const source = readFileSync(new URL('../PodcastLearning/Views/Components.swift', import.meta.url), 'utf8')
const start = source.indexOf('struct Waveform: View')
const end = source.indexOf('struct ItemSummaryRow: View', start)
assert.ok(start >= 0 && end > start, 'Cannot locate the app waveform')
const dir = mkdtempSync(join(tmpdir(), 'podcast-waveform-'))
try {
  const file = join(dir, 'check.swift')
  writeFileSync(file, `import SwiftUI
import AppKit
struct AccentTheme { var color = Color.purple }
extension EnvironmentValues { @Entry var accentTheme = AccentTheme() }
${source.slice(start, end)}
@MainActor func pixels(_ progress: Double) -> Data {
    let renderer = ImageRenderer(content: Waveform(progress: progress).frame(width: 280, height: 44))
    renderer.scale = 3
    guard let image = renderer.cgImage, let bytes = image.dataProvider?.data else { fatalError("Could not render waveform") }
    return bytes as Data
}
// These two positions were identical when the UI colored only whole bars.
precondition(pixels(0.111) != pixels(0.119), "Playback fill still advances in whole-bar steps")
precondition(pixels(-1) == pixels(0), "Negative progress must clamp to zero")
precondition(pixels(2) == pixels(1), "Progress beyond the end must clamp to one")
print("PASS: continuous sub-bar waveform fill; clamped progress")
`)
  process.stdout.write(execFileSync('swift', ['-swift-version', '6', '-default-isolation', 'MainActor', file], { encoding: 'utf8' }))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
