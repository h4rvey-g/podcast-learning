// Check the real app's theme selection/persistence and asset contrast without a simulator.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8')
const theme = read('PodcastLearning/AccentTheme.swift')
// These unrelated core defaults aren't exercised by this settings-only probe.
const settings = read('PodcastLearning/Services/SettingsStore.swift').replace('import PodcastCore', `
enum CEFR: String { case b2 = "B2" }
enum SpeechService: String { case apple, openRouter }
enum SpeechSynthesizer { static let defaultModel = "unused", defaultVoice = "unused" }
`)
const dir = mkdtempSync(join(tmpdir(), 'podcast-themes-'))
let assets
try {
  const file = join(dir, 'check.swift')
  writeFileSync(file, `${theme}\n${settings}
let suite = "ThemeTests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let settings = SettingsStore(defaults: defaults)
precondition(settings.accentTheme == .purple, "Existing installs must keep purple")
precondition(EnvironmentValues().accentTheme == .purple, "Standalone views must default to purple")
for theme in AccentTheme.allCases {
    settings.accentTheme = theme
    precondition(defaults.string(forKey: "accentTheme") == theme.rawValue)
    precondition(SettingsStore(defaults: defaults).accentTheme == theme, "Theme must survive relaunch")
    var environment = EnvironmentValues()
    environment.accentTheme = theme
    precondition(environment.accentTheme == theme)
}
defaults.set("unknown-future-theme", forKey: "accentTheme")
precondition(SettingsStore(defaults: defaults).accentTheme == .purple, "Unknown themes must fall back safely")
print(String(data: try JSONEncoder().encode(AccentTheme.allCases.map(\\.assetName)), encoding: .utf8)!)
`)
  assets = JSON.parse(execFileSync('swift', ['-swift-version', '6', '-default-isolation', 'MainActor', file], { encoding: 'utf8' }))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
assert.equal(new Set(assets).size, 5, 'Each theme must have its own color asset')

function color(name, dark, high) {
  const { colors } = JSON.parse(read(`PodcastLearning/Assets.xcassets/${name}.colorset/Contents.json`))
  const entry = colors.filter(c => (c.appearances ?? []).every(a =>
    a.appearance === 'luminosity' ? dark && a.value === 'dark' : high && a.value === 'high'
  )).sort((a, b) => (b.appearances?.length ?? 0) - (a.appearances?.length ?? 0))[0]
  assert.ok(entry, `Missing ${name} variant`)
  if (name !== 'OnAccent') assert.equal(entry.appearances?.length ?? 0, Number(dark) + Number(high))
  assert.equal(Number(entry.color.components.alpha), 1)
  return ['red', 'green', 'blue'].map(c => Number(entry.color.components[c]) / 255)
}
const luminance = rgb => rgb.map(c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)
  .reduce((sum, c, i) => sum + c * [0.2126, 0.7152, 0.0722][i], 0)
const contrast = (a, b) => (Math.max(luminance(a), luminance(b)) + 0.05) / (Math.min(luminance(a), luminance(b)) + 0.05)
for (const asset of assets) {
  for (const dark of [false, true]) {
    let normal
    for (const high of [false, true]) {
      const accent = color(asset, dark, high)
      const foreground = color('OnAccent', dark, high)
      // Representative grouped surfaces, including an elevated dark card.
      const surface = dark ? [44 / 255, 44 / 255, 46 / 255] : [242 / 255, 242 / 255, 247 / 255]
      const textRatio = contrast(accent, surface)
      assert.ok(contrast(accent, foreground) >= 4.5, `${asset}: button text contrast is too low`)
      assert.ok(textRatio >= 4.5, `${asset}: accent text contrast is too low`)
      if (high) assert.ok(textRatio > normal, `${asset}: Increase Contrast must improve contrast`)
      else normal = textRatio
    }
  }
}
console.log('PASS: five themes; purple default; saved selection; unknown-value fallback; light/dark and increased-contrast colors')
