import Foundation
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

/// The settings split: which settings follow the person through iCloud and which stay on the device, and how the synced
/// ones become iCloud key-value entries and back.
struct SettingsSplitTests {
    typealias SavedKey = PrompterSettings.CodingKeys

    /// The approved split, written out so a change to it is a deliberate edit here too.
    static let approvedSynced: Set<String> = [
        "scrollMode", "speedLevel", "wordsPerMinute", "finishInSeconds", "countdownSeconds", "countdownBeep",
        "scheme", "fontWeight", "lineSpacing", "dimmedOpacity", "markdown",
    ]
    static let approvedThisDevice: Set<String> = [
        "mirrorHorizontal", "flipVertical", "rotation", "lockLandscape", "fontSize", "sideMargin", "readingLinePosition",
    ]

    /// Every synced setting changed from its default.
    static var tunedReading: PrompterSettings {
        var settings = PrompterSettings()
        settings.scrollMode = .finishIn
        settings.speedLevel = 4.2
        settings.wordsPerMinute = 155
        settings.finishInSeconds = 600
        settings.countdownSeconds = 10
        settings.countdownBeep = false
        settings.scheme = .yellowOnBlack
        settings.fontWeight = .semibold
        settings.lineSpacing = 1.25
        settings.dimmedOpacity = 0.5
        settings.markdown = false
        return settings
    }

    /// Every setting that stays on the device changed from its default, some of them outside their ranges (a value that
    /// isn't clamped must still come through untouched).
    static var tunedScreen: PrompterSettings {
        var settings = PrompterSettings()
        settings.mirrorHorizontal = false
        settings.flipVertical = true
        settings.rotation = .half
        settings.lockLandscape = false
        settings.fontSize = 500
        settings.sideMargin = 0.9
        settings.readingLinePosition = 0.95
        return settings
    }

    /// The settings that stay on the device, by name.
    static func thisDeviceFields(_ settings: PrompterSettings) -> [String: AnyHashable] {
        [
            "mirrorHorizontal": settings.mirrorHorizontal,
            "flipVertical": settings.flipVertical,
            "rotation": settings.rotation,
            "lockLandscape": settings.lockLandscape,
            "fontSize": settings.fontSize,
            "sideMargin": settings.sideMargin,
            "readingLinePosition": settings.readingLinePosition,
        ]
    }

    /// Entries written to a property list and read back, the way the iCloud key-value store keeps them.
    static func throughPropertyList(
        _ entries: [String: SettingsCloudValue],
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws -> [String: Any] {
        let objects = entries.mapValues(\.propertyListObject)
        let data = try PropertyListSerialization.data(fromPropertyList: objects, format: format, options: 0)
        return try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    // MARK: The rule book

    @Test func everySavedSettingIsClassifiedExactlyOnce() throws {
        let names = SavedKey.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)

        // The coding keys are every stored setting: a new property without a key fails here.
        let stored = Mirror(reflecting: PrompterSettings()).children.compactMap(\.label)
        #expect(stored.count == names.count)
        #expect(Set(stored) == Set(names))

        // The saved blob holds exactly these keys.
        let blob = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(PrompterSettings())) as? [String: Any]
        )
        #expect(Set(blob.keys) == Set(names))

        // Each key lands in one group, and the synced group is exactly the keys iCloud can carry.
        let synced = Set(SavedKey.allCases.filter { $0.syncScope == .synced }.map(\.rawValue))
        let thisDevice = Set(SavedKey.allCases.filter { $0.syncScope == .thisDevice }.map(\.rawValue))
        #expect(synced.isDisjoint(with: thisDevice))
        #expect(synced.union(thisDevice) == Set(names))
        #expect(synced.count + thisDevice.count == names.count)
        #expect(SyncedSettingKey.allCases.count == synced.count)
        #expect(Set(SyncedSettingKey.allCases.map(\.rawValue)) == synced)
    }

    @Test func theApprovedSplit() {
        let synced = Set(SavedKey.allCases.filter { $0.syncScope == .synced }.map(\.rawValue))
        let thisDevice = Set(SavedKey.allCases.filter { $0.syncScope == .thisDevice }.map(\.rawValue))
        #expect(synced == Self.approvedSynced)
        #expect(thisDevice == Self.approvedThisDevice)
        #expect(Set(Self.thisDeviceFields(PrompterSettings()).keys) == Self.approvedThisDevice)
    }

    /// The iCloud key names are a format other devices read: once shipped they never change.
    @Test func cloudKeyNamesArePinned() {
        let expected: Set<String> = [
            "settings.v1.scrollMode", "settings.v1.speedLevel", "settings.v1.wordsPerMinute",
            "settings.v1.finishInSeconds", "settings.v1.countdownSeconds", "settings.v1.countdownBeep",
            "settings.v1.scheme", "settings.v1.fontWeight", "settings.v1.lineSpacing", "settings.v1.dimmedOpacity",
            "settings.v1.markdown",
        ]
        #expect(Set(SyncedSettingKey.allCases.map(\.cloudKey)) == expected)
        for key in SyncedSettingKey.allCases {
            #expect(SyncedSettingKey(cloudKey: key.cloudKey) == key)
        }
    }

    // MARK: Round trips

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.binary, .xml])
    func everySyncedSettingRoundTrips(format: PropertyListSerialization.PropertyListFormat) throws {
        let tuned = Self.tunedReading
        let entries = SettingsSync.cloudEntries(for: tuned)
        #expect(entries.count == SyncedSettingKey.allCases.count)

        let remote = SettingsSync.remoteValues(from: try Self.throughPropertyList(entries, format: format))
        #expect(remote.count == SyncedSettingKey.allCases.count)
        for key in SyncedSettingKey.allCases {
            #expect(remote[key] == key.cloudValue(in: tuned), "\(key)")
        }
        // A fresh device picks up every reading setting.
        #expect(SettingsSync.applying(remote, to: PrompterSettings()) == tuned)
        // A device with its own screen setup keeps it.
        var expected = Self.tunedScreen
        for key in SyncedSettingKey.allCases {
            expected = try #require(key.applying(key.cloudValue(in: tuned), to: expected))
        }
        let applied = SettingsSync.applying(remote, to: Self.tunedScreen)
        #expect(applied == expected)
        #expect(Self.thisDeviceFields(applied) == Self.thisDeviceFields(Self.tunedScreen))
        #expect(SettingsSync.changedSyncedKeys(from: tuned, to: applied).isEmpty)
    }

    @Test func everyEnumCaseRoundTrips() throws {
        for mode in PrompterSettings.ScrollMode.allCases {
            var settings = PrompterSettings()
            settings.scrollMode = mode
            let remote = SettingsSync.remoteValues(from: try Self.throughPropertyList(SettingsSync.cloudEntries(for: settings)))
            #expect(SettingsSync.applying(remote, to: Self.tunedReading).scrollMode == mode)
        }
        for scheme in PrompterSettings.Scheme.allCases {
            var settings = PrompterSettings()
            settings.scheme = scheme
            let remote = SettingsSync.remoteValues(from: try Self.throughPropertyList(SettingsSync.cloudEntries(for: settings)))
            #expect(SettingsSync.applying(remote, to: Self.tunedReading).scheme == scheme)
        }
        for weight in PrompterSettings.Weight.allCases {
            var settings = PrompterSettings()
            settings.fontWeight = weight
            let remote = SettingsSync.remoteValues(from: try Self.throughPropertyList(SettingsSync.cloudEntries(for: settings)))
            #expect(SettingsSync.applying(remote, to: Self.tunedReading).fontWeight == weight)
        }
    }

    @Test func entriesForChosenKeysOnly() {
        let entries = SettingsSync.cloudEntries(for: Self.tunedReading, keys: [.speedLevel, .markdown])
        #expect(entries == ["settings.v1.speedLevel": .double(4.2), "settings.v1.markdown": .bool(false)])
    }

    // MARK: The store's objects

    /// The store hands back `NSNumber` for flags and numbers alike; the number's own type must survive.
    @Test(arguments: [PropertyListSerialization.PropertyListFormat.binary, .xml])
    func storeObjectsKeepTheirType(format: PropertyListSerialization.PropertyListFormat) throws {
        let values: [String: SettingsCloudValue] = [
            "true": .bool(true), "false": .bool(false),
            "zero": .int(0), "one": .int(1), "five": .int(5), "negative": .int(-3),
            "whole": .double(300), "fraction": .double(4.2), "tiny": .double(0.35),
            "text": .string("wpm"), "empty": .string(""),
        ]
        let objects = try Self.throughPropertyList(values, format: format)
        for (name, value) in values {
            let object = try #require(objects[name])
            #expect(SettingsCloudValue(propertyListObject: object) == value, "\(name)")
        }
    }

    @Test func numbersAreTypedByTheirOwnKind() {
        #expect(SettingsCloudValue(propertyListObject: NSNumber(value: true)) == .bool(true))
        #expect(SettingsCloudValue(propertyListObject: NSNumber(value: 1)) == .int(1))
        #expect(SettingsCloudValue(propertyListObject: NSNumber(value: UInt64(5))) == .int(5))
        #expect(SettingsCloudValue(propertyListObject: NSNumber(value: Int64.min)) == .int(.min))
        #expect(SettingsCloudValue(propertyListObject: NSNumber(value: 1.0)) == .double(1))
        #expect(SettingsCloudValue(propertyListObject: NSString(string: "speed")) == .string("speed"))
    }

    @Test func objectsThatArentSettingsAreDropped() {
        let objects: [Any] = [Data([1, 2]), [1, 2], ["a": 1], Date(), NSNull(), NSNumber(value: UInt64.max)]
        for object in objects {
            #expect(SettingsCloudValue(propertyListObject: object) == nil, "\(object)")
        }
        let entries: [String: Any] = ["settings.v1.speedLevel": [5.0], "settings.v1.markdown": Data()]
        #expect(SettingsSync.remoteValues(from: entries).isEmpty)
    }

    // MARK: Settings that stay on the device

    /// The guarantee checked where it can actually break: raw store keys. Keys of settings that stay on the device,
    /// other format versions and unrelated keys are all dropped, so nothing changes.
    @Test func storeKeysForThisDeviceAndOtherFormatsAreIgnored() {
        let entries: [String: Any] = [
            "settings.v1.mirrorHorizontal": false, "settings.v1.flipVertical": true, "settings.v1.rotation": 90,
            "settings.v1.lockLandscape": false, "settings.v1.fontSize": 30.0, "settings.v1.sideMargin": 0.2,
            "settings.v1.readingLinePosition": 0.5,
            "fontSize": 30.0, "mirrorHorizontal": true, "speedLevel": 9.0,
            "settings.v2.speedLevel": 9.0, "settings.speedLevel": 9.0, "settings.v1.": 9.0,
            "settings.v1.speedLevel.extra": 9.0, "settings.v1.SpeedLevel": 9.0, "SETTINGS.V1.SPEEDLEVEL": 9.0,
            "prompterSettings": Data(), "unrelated": "value",
        ]
        let remote = SettingsSync.remoteValues(from: entries)
        #expect(remote.isEmpty)
        let local = Self.tunedScreen
        #expect(SettingsSync.applying(remote, to: local) == local)
    }

    @Test func applyingEveryRemoteSettingLeavesTheScreenSetupAlone() {
        var remote: [SyncedSettingKey: SettingsCloudValue] = [:]
        for key in SyncedSettingKey.allCases { remote[key] = key.cloudValue(in: Self.tunedReading) }
        let applied = SettingsSync.applying(remote, to: Self.tunedScreen)
        #expect(Self.thisDeviceFields(applied) == Self.thisDeviceFields(Self.tunedScreen))
        #expect(applied.fontSize == 500)   // not clamped to 200: it isn't the remote's to touch
        #expect(SettingsSync.changedSyncedKeys(from: Self.tunedReading, to: applied).isEmpty)
    }

    /// 500 random store dictionaries (any key, any object): the screen setup never moves, and every synced setting that
    /// did change holds a value this build would keep.
    @Test func randomRemoteEntriesNeverMoveTheScreenSetup() {
        var random = SeededRandom(seed: 0x5E77_1295)
        let local = Self.tunedScreen
        for _ in 0..<500 {
            let entries = Self.randomEntries(using: &random)
            let applied = SettingsSync.applying(SettingsSync.remoteValues(from: entries), to: local)
            #expect(Self.thisDeviceFields(applied) == Self.thisDeviceFields(local))
            for key in SettingsSync.changedSyncedKeys(from: local, to: applied) {
                let value = key.cloudValue(in: applied)
                #expect(key.decode(value) == value, "\(key) \(value)")
            }
        }
    }

    // MARK: Values this build can't use

    @Test func anUnknownEnumValueIsIgnoredNotReset() {
        var local = PrompterSettings()
        local.scrollMode = .finishIn
        local.scheme = .yellowOnBlack
        local.fontWeight = .bold
        #expect(SyncedSettingKey.scrollMode.decode(.string("teleprompt2")) == nil)
        #expect(SyncedSettingKey.scrollMode.decode(.string("WPM")) == nil)   // raw values are case sensitive
        #expect(SyncedSettingKey.scheme.decode(.string("greenOnBlack")) == nil)
        #expect(SyncedSettingKey.fontWeight.decode(.string("ultra")) == nil)
        let remote: [SyncedSettingKey: SettingsCloudValue] = [
            .scrollMode: .string("teleprompt2"), .scheme: .string("greenOnBlack"), .fontWeight: .string("ultra"),
        ]
        // Not the defaults (.wpm, .whiteOnBlack, .heavy): the local choice stays.
        #expect(SettingsSync.applying(remote, to: local) == local)
    }

    @Test(arguments: [
        (SyncedSettingKey.speedLevel, SettingsCloudValue.string("fast")),
        (.speedLevel, .bool(true)),
        (.wordsPerMinute, .string("140")),
        (.finishInSeconds, .bool(false)),
        (.lineSpacing, .string("1.6")),
        (.dimmedOpacity, .bool(true)),
        (.countdownSeconds, .double(5.5)),
        (.countdownSeconds, .double(.nan)),
        (.countdownSeconds, .double(.infinity)),
        (.countdownSeconds, .bool(true)),
        (.countdownSeconds, .string("5")),
        (.countdownBeep, .int(1)),
        (.countdownBeep, .double(0)),
        (.countdownBeep, .string("true")),
        (.markdown, .int(0)),
        (.markdown, .string("false")),
        (.scrollMode, .int(0)),
        (.scheme, .bool(true)),
        (.fontWeight, .double(700)),
    ])
    func aValueOfTheWrongTypeIsIgnored(key: SyncedSettingKey, value: SettingsCloudValue) {
        #expect(key.decode(value) == nil)
        #expect(key.applying(value, to: Self.tunedReading) == nil)
        #expect(SettingsSync.applying([key: value], to: Self.tunedReading) == Self.tunedReading)
    }

    @Test func goodValuesApplyAndBadOnesAreSkippedInTheSameBatch() {
        let remote: [SyncedSettingKey: SettingsCloudValue] = [
            .speedLevel: .double(5), .scrollMode: .string("teleprompt2"),
            .markdown: .bool(true), .countdownSeconds: .string("x"),
        ]
        let applied = SettingsSync.applying(remote, to: Self.tunedReading)
        #expect(applied.speedLevel == 5)
        #expect(applied.markdown)
        #expect(applied.scrollMode == Self.tunedReading.scrollMode)
        #expect(applied.countdownSeconds == Self.tunedReading.countdownSeconds)
        #expect(SettingsSync.changedSyncedKeys(from: Self.tunedReading, to: applied) == [.speedLevel, .markdown])
    }

    @Test func aNumberOfTheOtherKindIsAccepted() {
        #expect(SyncedSettingKey.wordsPerMinute.decode(.int(200)) == .double(200))
        #expect(SyncedSettingKey.speedLevel.decode(.int(5)) == .double(5))
        #expect(SyncedSettingKey.countdownSeconds.decode(.double(10)) == .int(10))
        #expect(SyncedSettingKey.countdownSeconds.decode(.double(-0.0)) == .int(0))
    }

    // MARK: NaN, infinity and out-of-range numbers

    @Test(arguments: [SyncedSettingKey.speedLevel, .wordsPerMinute, .finishInSeconds, .lineSpacing, .dimmedOpacity])
    func nanIsIgnoredSoTheLocalValueStays(key: SyncedSettingKey) {
        #expect(key.decode(.double(.nan)) == nil)
        #expect(key.decode(.double(-.nan)) == nil)
        // Not reset to the default, which is what PrompterSettings.clamped() would do with NaN.
        #expect(SettingsSync.applying([key: .double(.nan)], to: Self.tunedReading) == Self.tunedReading)
    }

    @Test func infinityAndOutOfRangeNumbersAreClamped() {
        let cases: [(SyncedSettingKey, SettingsCloudValue, SettingsCloudValue)] = [
            (.speedLevel, .double(.infinity), .double(10)),
            (.speedLevel, .double(-.infinity), .double(1)),
            (.speedLevel, .double(50), .double(10)),
            (.speedLevel, .int(0), .double(1)),
            (.wordsPerMinute, .double(10), .double(60)),
            (.wordsPerMinute, .int(1000), .double(300)),
            (.finishInSeconds, .double(1e9), .double(7200)),
            (.finishInSeconds, .double(.greatestFiniteMagnitude), .double(7200)),
            (.lineSpacing, .double(9), .double(3)),
            (.lineSpacing, .double(0.2), .double(1)),
            (.dimmedOpacity, .double(-1), .double(0)),
            (.dimmedOpacity, .double(2), .double(1)),
            (.countdownSeconds, .int(7), .int(5)),
            (.countdownSeconds, .int(12), .int(10)),
            (.countdownSeconds, .int(1000), .int(15)),
            (.countdownSeconds, .int(-3), .int(0)),
            (.countdownSeconds, .int(.max), .int(15)),
            (.countdownSeconds, .int(.min), .int(0)),
            (.countdownSeconds, .double(1e300), .int(15)),
            (.countdownSeconds, .double(-1e300), .int(0)),
        ]
        for (key, value, expected) in cases {
            #expect(key.decode(value) == expected, "\(key) \(value)")
        }
    }

    /// The same numbers through the codec and through `PrompterSettings.clamped()` end up the same.
    @Test(arguments: [SyncedSettingKey.speedLevel, .wordsPerMinute, .finishInSeconds, .lineSpacing, .dimmedOpacity])
    func numbersAreClampedLikeTheSavedBlob(key: SyncedSettingKey) throws {
        let field = Self.decimalField(key)
        let numbers: [Double] = [-.infinity, -1e9, -1, 0, 0.1, 0.5, 1, 1.6, 2.5, 3, 9.9, 10, 10.5, 59, 61, 140, 299, 301,
                                 7199, 7201, 1e9, .infinity]
        for number in numbers {
            var expected = PrompterSettings()
            expected[keyPath: field] = number
            let applied = try #require(key.applying(.double(number), to: Self.tunedScreen))
            #expect(applied[keyPath: field] == expected.clamped()[keyPath: field], "\(key) \(number)")
        }
    }

    @Test(arguments: [-100, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 30, 3600])
    func countdownSnapsLikeTheSavedBlob(seconds: Int) throws {
        var expected = PrompterSettings()
        expected.countdownSeconds = seconds
        let applied = try #require(SyncedSettingKey.countdownSeconds.applying(.int(seconds), to: Self.tunedScreen))
        #expect(applied.countdownSeconds == expected.clamped().countdownSeconds)
        #expect(PrompterSettings.countdownOptions.contains(applied.countdownSeconds))
    }

    // MARK: What changed

    @Test func changedSyncedKeysIgnoresTheScreenSetup() {
        let base = PrompterSettings()
        #expect(SettingsSync.changedSyncedKeys(from: base, to: base).isEmpty)
        #expect(SettingsSync.changedSyncedKeys(from: base, to: Self.tunedScreen).isEmpty)

        var changed = base
        changed.speedLevel = 6
        changed.scheme = .blackOnWhite
        changed.fontSize = 96
        changed.mirrorHorizontal = false
        #expect(SettingsSync.changedSyncedKeys(from: base, to: changed) == [.speedLevel, .scheme])
        #expect(SettingsSync.changedSyncedKeys(from: changed, to: base) == [.speedLevel, .scheme])
        #expect(SettingsSync.changedSyncedKeys(from: base, to: Self.tunedReading) == Set(SyncedSettingKey.allCases))
    }

    @Test func changedSyncedKeysSeesEachSettingOnItsOwn() throws {
        for key in SyncedSettingKey.allCases {
            let changed = try #require(key.applying(key.cloudValue(in: Self.tunedReading), to: PrompterSettings()))
            #expect(SettingsSync.changedSyncedKeys(from: PrompterSettings(), to: changed) == [key])
        }
    }

    // MARK: Helpers

    static func decimalField(_ key: SyncedSettingKey) -> WritableKeyPath<PrompterSettings, Double> {
        switch key {
        case .speedLevel: \.speedLevel
        case .wordsPerMinute: \.wordsPerMinute
        case .finishInSeconds: \.finishInSeconds
        case .lineSpacing: \.lineSpacing
        case .dimmedOpacity: \.dimmedOpacity
        default: fatalError("\(key) isn't a decimal setting")
        }
    }

    /// A store dictionary with a few random keys (synced, this device's, other versions, junk) holding random objects
    /// (flags, numbers including NaN and infinity, enum names known and unknown, junk strings, data, arrays).
    static func randomEntries(using random: inout SeededRandom) -> [String: Any] {
        let names = Array(approvedSynced) + Array(approvedThisDevice)
        let prefixes = ["settings.v1.", "settings.v1.", "settings.v1.", "settings.v2.", "", "settings."]
        let strings = PrompterSettings.ScrollMode.allCases.map(\.rawValue) + PrompterSettings.Scheme.allCases.map(\.rawValue)
            + PrompterSettings.Weight.allCases.map(\.rawValue) + ["teleprompt2", "", "ultra", "WPM", "5", "true"]
        let numbers: [Double] = [.nan, .infinity, -.infinity, -1, 0, 0.35, 1, 1.6, 3, 4.2, 5, 10, 15, 140, 300, 1e12]
        var entries: [String: Any] = [:]
        for _ in 0..<Int.random(in: 1...8, using: &random) {
            let key = prefixes.randomElement(using: &random)! + names.randomElement(using: &random)!
            let object: Any = switch Int.random(in: 0..<6, using: &random) {
            case 0: Bool.random(using: &random)
            case 1: Int.random(in: -20...4000, using: &random)
            case 2: numbers.randomElement(using: &random)!
            case 3: strings.randomElement(using: &random)!
            case 4: Data([1, 2, 3])
            default: [1.0, 2.0]
            }
            entries[key] = object
        }
        return entries
    }

    /// A repeatable random source (SplitMix64), so a failure can be replayed.
    struct SeededRandom: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
