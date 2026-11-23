import Testing
@testable import MiscKitCore

@Suite("存储路径隔离")
struct AppStoragePathsTests {
    @Test("正式版、开发版与 CLI 使用独立的应用数据目录")
    func directoryNamesAreIsolated() {
        #expect(AppStoragePaths.directoryName(forBundleID: "app.misckit.MiscKit") == "MiscKit")
        #expect(AppStoragePaths.directoryName(forBundleID: "app.misckit.MiscKit.dev") == "MiscKit-Dev")
        #expect(AppStoragePaths.directoryName(forBundleID: "com.apple.dt.xctest.tool") == "MiscKit-CLI")
        #expect(AppStoragePaths.directoryName(forBundleID: nil) == "MiscKit-CLI")
    }
}
