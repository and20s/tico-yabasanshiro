import XCTest
@testable import YabaSnashiro

final class BackupFileTests: XCTestCase {
    func testInternalFileProperties() {
        let file = BackupFile.internalMemory
        XCTAssertEqual(file.fileKey, "memory")
        XCTAssertEqual(file.cartType, 0) // CART_NONE
        XCTAssertTrue(file.path.hasSuffix("backup/memory.bin"))
    }

    func testCartridgeFileProperties() {
        XCTAssertEqual(BackupFile.cartridge4Mbit.fileKey, "backup4")
        XCTAssertEqual(BackupFile.cartridge4Mbit.cartType, 2)
        XCTAssertEqual(BackupFile.cartridge4Mbit.expectedByteSize, 0x100000)
        XCTAssertTrue(BackupFile.cartridge4Mbit.path.hasSuffix("cart/backup4.ram"))

        XCTAssertEqual(BackupFile.cartridge8Mbit.cartType, 3)
        XCTAssertEqual(BackupFile.cartridge8Mbit.expectedByteSize, 0x200000)
        XCTAssertEqual(BackupFile.cartridge16Mbit.cartType, 4)
        XCTAssertEqual(BackupFile.cartridge16Mbit.expectedByteSize, 0x400000)
        XCTAssertEqual(BackupFile.cartridge32Mbit.cartType, 5)
        XCTAssertEqual(BackupFile.cartridge32Mbit.expectedByteSize, 0x800000)
    }

    func testInternalMemoryHasNoExpectedSize() {
        XCTAssertNil(BackupFile.internalMemory.expectedByteSize)
    }

    func testDeviceIdMapping() {
        XCTAssertEqual(BackupFile.internalMemory.deviceId, 0)
        XCTAssertEqual(BackupFile.cartridge4Mbit.deviceId, 1)
        XCTAssertEqual(BackupFile.cartridge32Mbit.deviceId, 1)
    }

    func testCartridgeCaseForByteSize() {
        XCTAssertEqual(BackupFile.cartridgeCase(forByteSize: 0x100000), .cartridge4Mbit)
        XCTAssertEqual(BackupFile.cartridgeCase(forByteSize: 0x800000), .cartridge32Mbit)
        XCTAssertNil(BackupFile.cartridgeCase(forByteSize: 12345))
    }

    func testDisplayNameIsLocalizedAndDistinct() {
        let names = BackupFile.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(where: \.isEmpty))
    }
}
