// Exercise the real settings persistence/migration without accessing the user's Keychain.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8')
const settings = read('PodcastLearning/Services/SettingsStore.swift').split('\nenum APIKey {')[0].replace('import PodcastCore', '')
const service = read('Sources/PodcastCore/SpeechCatalog.swift').split('public enum SpeechCatalog')[0]
const screen = read('PodcastLearning/Views/SettingsView.swift')
const synthesisScreen = read('PodcastLearning/Views/SynthesisSettingsView.swift')
const player = read('PodcastLearning/Services/AudioStore.swift')
const appStore = read('PodcastLearning/Services/AppStore.swift')
assert.equal((screen.match(/row\("Speech",/g) || []).length, 1)
assert.ok(!screen.includes('row("Generated Audio"') && !screen.includes('row("Speaking Rate"'))
assert.ok(!screen.includes('footer:') && !synthesisScreen.includes('footer:'))
assert.ok(player.includes('settings.speechService == .openRouter && !["preparing", "pending"].contains'))
assert.ok(player.includes('synthesisTask?.cancel()') && player.includes('self.playbackRequest == request'))
assert.ok(appStore.includes('service == .openRouter ? try speechSynthesizer() : nil'))
assert.ok(appStore.indexOf('guard let client else') < appStore.indexOf('try await client.generate'))
const dir = mkdtempSync(join(tmpdir(), 'podcast-speech-settings-'))
try {
  const file = join(dir, 'check.swift')
  writeFileSync(file, `${service}
${settings}
enum AccentTheme: String { case purple }
enum CEFR: String { case b2 = "B2" }
enum SpeechSynthesizer {
    static let defaultModel = "elevenlabs/eleven-v4-turbo"
    static let defaultVoice = "george"
}
enum APIKey {
    static var key = ""
    static func read(account: String) throws -> String { key }
}
let suite = "SpeechSettingsCheck-\\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let fresh = SettingsStore(defaults: defaults)
precondition(fresh.speechService == .apple)
fresh.voice = "en-GB"; fresh.rate = 0.4
fresh.ttsVoice = "sarah"; fresh.speechService = .openRouter
let reloaded = SettingsStore(defaults: defaults)
precondition(reloaded.speechService == .openRouter && reloaded.ttsVoice == "sarah")
reloaded.speechService = .apple
let apple = SettingsStore(defaults: defaults)
precondition(apple.speechService == .apple && apple.voice == "en-GB" && apple.rate == 0.4)
precondition(apple.ttsVoice == "sarah", "Switching providers must preserve both voice choices")
defaults.removePersistentDomain(forName: suite)
defaults.set("elevenlabs/existing", forKey: "ttsModel")
precondition(SettingsStore(defaults: defaults).speechService == .openRouter)
defaults.removePersistentDomain(forName: suite)
APIKey.key = "fake-key"
precondition(SettingsStore(defaults: defaults).speechService == .openRouter)
defaults.set("apple", forKey: "speechService")
precondition(SettingsStore(defaults: defaults).speechService == .apple, "An explicit choice overrides migration")
print("PASS: speech persistence, existing-key/model migration, single settings row, no footers, and routing guards")
`)
  process.stdout.write(execFileSync('swift', [file], { encoding: 'utf8' }))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
