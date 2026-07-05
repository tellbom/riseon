import XCTest
@testable import RiseOn

/// Covers task.md S3.2's verification point: key behavior is well-defined
/// (save/load/delete round-trip; Keychain items — unlike `UserDefaults` —
/// survive app delete/reinstall on the same device by default, which is the
/// expected behavior here).
///
/// NOTE: Keychain access from a unit-test bundle can require the test target
/// to run hosted inside the app (or have a keychain-access-group
/// entitlement), depending on how the test target is configured in Xcode.
/// If these fail with `errSecMissingEntitlement` / status `-34018`, that's an
/// Xcode target-configuration issue, not a logic bug in `LLMAPIKeyStore`.
final class LLMAPIKeyStoreTests: XCTestCase {

    override func tearDownWithError() throws {
        try LLMAPIKeyStore.delete()
    }

    func test_saveThenLoad_roundTrips() throws {
        try LLMAPIKeyStore.save("sk-test-12345")
        XCTAssertEqual(try LLMAPIKeyStore.load(), "sk-test-12345")
    }

    func test_save_overwritesPreviousValue() throws {
        try LLMAPIKeyStore.save("sk-old-value")
        try LLMAPIKeyStore.save("sk-new-value")
        XCTAssertEqual(try LLMAPIKeyStore.load(), "sk-new-value")
    }

    func test_load_returnsNilWhenNothingStored() throws {
        try LLMAPIKeyStore.delete()
        XCTAssertNil(try LLMAPIKeyStore.load())
    }

    func test_delete_removesTheKey() throws {
        try LLMAPIKeyStore.save("sk-test")
        try LLMAPIKeyStore.delete()
        XCTAssertNil(try LLMAPIKeyStore.load())
    }

    func test_delete_isIdempotent() throws {
        try LLMAPIKeyStore.delete()
        try LLMAPIKeyStore.delete() // must not throw the second time either
    }

    func test_exists_reflectsCurrentPresence() throws {
        try LLMAPIKeyStore.delete()
        XCTAssertFalse(try LLMAPIKeyStore.exists())

        try LLMAPIKeyStore.save("sk-test")
        XCTAssertTrue(try LLMAPIKeyStore.exists())

        try LLMAPIKeyStore.delete()
        XCTAssertFalse(try LLMAPIKeyStore.exists())
    }
}
