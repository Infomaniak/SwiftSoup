import XCTest
@testable import SwiftSoup

final class AttributeObserverRegistrationTest: XCTestCase {
    func testRepeatedSnapshotsAndIteratorsKeepExactlyOneRegistrationPerOwner() throws {
        let attributes = Attributes()
        for index in 0..<128 { try attributes.put("k\(index)", "v\(index)") }
        let original = attributes.asList()
        for _ in 0..<32 {
            let snapshot = attributes.asList()
            XCTAssertEqual(snapshot.count, original.count)
            for (index, attribute) in attributes.enumerated() {
                XCTAssertTrue(attribute === original[index])
                XCTAssertEqual(attribute.mutationOwners?.count, 1)
                XCTAssertTrue(attribute.mutationOwners?.first?.value === attributes)
            }
        }
    }

    func testRegistrationStillPrunesOtherRemovedAndExpiredOwners() throws {
        let shared = try Attribute(key: "class", value: "old")
        let active = Attributes()
        let removed = Attributes()
        var expired: Attributes? = Attributes()
        active.put(attribute: shared)
        removed.put(attribute: shared)
        expired?.put(attribute: shared)
        XCTAssertEqual(shared.mutationOwners?.count, 3)
        try removed.remove(key: "class")
        expired = nil
        _ = active.asList()
        XCTAssertEqual(shared.mutationOwners?.count, 1)
        XCTAssertTrue(shared.mutationOwners?.first?.value === active)
    }

    func testSharedMutationsAfterReregistrationReachBothDocuments() throws {
        let first = try SwiftSoup.parse("<p class='before'></p>")
        let second = try SwiftSoup.parse("<p></p>")
        let a = try XCTUnwrap(first.body()?.child(0).getAttributes())
        let b = try XCTUnwrap(second.body()?.child(0).getAttributes())
        let shared = try XCTUnwrap(a.asList().first)
        b.put(attribute: shared)
        for _ in 0..<16 { _ = a.asList(); _ = b.asList() }
        XCTAssertEqual(try first.select(".before").size(), 1)
        XCTAssertEqual(try second.select(".before").size(), 1)
        shared.setValue(value: Array("after".utf8))
        for doc in [first, second] {
            XCTAssertEqual(try doc.select(".before").size(), 0)
            XCTAssertEqual(try doc.select(".after").size(), 1)
        }
        XCTAssertEqual(shared.mutationOwners?.count, 2)
    }
}
