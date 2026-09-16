import XCTest
@testable import SwiftSoup

final class AttributeObservationReadTest: XCTestCase {
    func testRepeatedSnapshotsAndIteratorsKeepOneWeakObserver() throws {
        let attrs = Attributes()
        for index in 0..<128 { try attrs.put("k\(index)", "v") }
        let snapshot = attrs.asList()
        for _ in 0..<16 {
            _ = attrs.asList()
            _ = Array(attrs)
        }
        for attribute in snapshot {
            XCTAssertEqual(attribute.mutationOwners?.count, 1)
            XCTAssertTrue(attribute.mutationOwners?.first?.value === attrs)
        }
        try snapshot[17].setKey(key: "changed")
        XCTAssertFalse(attrs.hasKey(key: "k17"))
        XCTAssertEqual(attrs.get(key: "changed"), "v")
    }

    func testRepeatedObservationStillPrunesRemovedAndDeadSecondaryOwners() throws {
        let primary = Attributes()
        let removed = Attributes()
        let shared = try Attribute(key: "id", value: "old")
        primary.put(attribute: shared)
        removed.put(attribute: shared)
        var expired: Attributes? = Attributes()
        expired?.put(attribute: shared)
        weak var weakExpired = expired
        expired = nil
        XCTAssertNil(weakExpired)
        try removed.remove(key: "id")
        _ = primary.asList()
        XCTAssertEqual(shared.mutationOwners?.count, 1)
        XCTAssertTrue(shared.mutationOwners?.first?.value === primary)
        shared.setValue(value: Array("new".utf8))
        XCTAssertEqual(primary.get(key: "id"), "new")
        XCTAssertFalse(removed.hasKey(key: "id"))
    }

    func testRetainedSnapshotCanMoveToAnotherOwnerAndBeReinserted() throws {
        let first = Attributes()
        try first.put("id", "old")
        let saved = try XCTUnwrap(first.asList().first)
        _ = first.asList()
        try first.remove(key: "id")
        let second = Attributes()
        second.put(attribute: saved)
        XCTAssertEqual(saved.mutationOwners?.count, 1)
        XCTAssertTrue(saved.mutationOwners?.first?.value === second)
        _ = second.asList()
        first.put(attribute: saved)
        saved.setValue(value: Array("new".utf8))
        XCTAssertEqual(first.get(key: "id"), "new")
        XCTAssertEqual(second.get(key: "id"), "new")
        XCTAssertEqual(saved.mutationOwners?.count, 2)
    }
}
