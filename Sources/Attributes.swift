//
//  Attributes.swift
//  SwifSoup
//
//  Created by Nabil Chatbi on 29/09/16.
//

import Foundation

/**
 The attributes of an Element.
 
 Attributes are treated as a map: there can be only one value associated with an attribute key/name.
 
 Attribute name and value comparisons are **case sensitive**. By default for HTML, attribute names are
 normalized to lower-case on parsing. That means you should use lower-case strings when referring to attributes by
 name.
 */
public struct AttributeMutation {
    public let keep: Bool
    public let newValue: [UInt8]?
    
    @inline(__always)
    public init(keep: Bool, newValue: [UInt8]? = nil) {
        self.keep = keep
        self.newValue = newValue
    }
}


open class Attributes: NSCopying {
    public static let dataPrefix: [UInt8] = "data-".utf8Array

    @usableFromInline
    internal enum PendingAttrValue {
        case none
        case empty
        case slice(ByteSlice)
        case slices([ByteSlice], Int)
        case bytes([UInt8])
    }

    @usableFromInline
    internal struct PendingAttribute {
        var nameSlice: ByteSlice?
        var nameBytes: [UInt8]?
        var hasUppercase: Bool
        var value: PendingAttrValue

        // A one-bit prefilter avoids most full-name comparisons in small batches.
        // Equal names always yield the same bit; a collision is never proof of
        // equality. Validate exactly the whitespace rule used by ByteSlice.trim().
        @inline(__always)
        @usableFromInline
        func canonicalNameMask() -> UInt64? {
            func mask(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64? {
                guard let first = bytes.first, let last = bytes.last else { return nil }
                func whitespace(_ byte: UInt8) -> Bool { byte == 32 || (byte >= 9 && byte <= 13) }
                guard !whitespace(first), !whitespace(last) else { return nil }
                let previous = bytes.count > 1 ? bytes[bytes.count - 2] : first
                let signature = (UInt64(first) &* 31) ^ (UInt64(last) &* 17) ^
                    (UInt64(previous) &* 7) ^ (UInt64(bytes.count) &* 13)
                return UInt64(1) << (signature & 63)
            }
            if let nameBytes { return nameBytes.withUnsafeBufferPointer(mask) }
            if let nameSlice { return nameSlice.withUnsafeBytes(mask) }
            return nil
        }

        @inline(__always)
        @usableFromInline
        func hasSameName(as other: PendingAttribute) -> Bool {
            if let nameBytes {
                if let otherBytes = other.nameBytes { return nameBytes == otherBytes }
                return other.nameSlice?.elementsEqual(nameBytes) ?? false
            }
            guard let nameSlice else { return false }
            if let otherBytes = other.nameBytes { return nameSlice.elementsEqual(otherBytes) }
            return other.nameSlice == nameSlice
        }

        @usableFromInline
        func normalizedKey() -> ByteSlice? {
            let key: ByteSlice
            if let nameBytes {
                key = ByteSlice.fromArray(nameBytes).trim()
            } else if let nameSlice {
                key = nameSlice.trim()
            } else {
                return nil
            }
            return key.isEmpty ? nil : key
        }
    }

    @usableFromInline
    static let disableLowercasedKeyIndex: Bool = false

    @usableFromInline
    static let keyIndexThreshold: Int = 4
    
    
    // Stored by lowercased key, but key case is checked against the copy inside
    // the Attribute on retrieval.
    @usableFromInline
    var attributes: [Attribute] = [] {
        @inline(__always)
        didSet {
            if !isMaterializing { notifyMutationOwners() }
            invalidateLowercasedKeysCache()
            invalidateKeyIndex()
        }
    }
    
    // Representation-only materialization must not invalidate DOM caches or source reuse.
    private var isMaterializing = false

    /// Set of lower‑cased UTF‑8 keys for fast O(1) ignore‑case look‑ups
    @usableFromInline
    internal var lowercasedKeysCache: Set<ByteSlice>? = nil

    @usableFromInline
    internal var lowercasedKeyIndex: [ByteSlice: Int]? = nil

    @usableFromInline
    internal var lowercasedKeyIndexDirty: Bool = true
    
    @usableFromInline
    internal var hasUppercaseKeys: Bool = false

    @usableFromInline
    internal var keyIndex: [ByteSlice: Int]? = nil

    @usableFromInline
    internal var keyIndexDirty: Bool = true

    @usableFromInline
    internal var pendingAttributes: [PendingAttribute]? = nil {
        didSet { pendingNamesAreCanonical = false }
    }

    // Validated once per deferred batch, never once per lookup or serialization.
    private var pendingNamesAreCanonical = false
    
    @usableFromInline
    internal var pendingAttributesCount: Int = 0
    
    @usableFromInline
    internal weak var ownerNode: Node?
    internal var additionalOwnerNodes: [Weak<Node>]? = nil

    // Retain the existing single-owner fast path for targeted internal invalidation.
    @usableFromInline
    var ownerElement: SwiftSoup.Element? { ownerNode as? SwiftSoup.Element }
    
    public init() {
        attributes.reserveCapacity(16)
    }

    private init(copying attributes: [Attribute], hasUppercaseKeys: Bool) {
        self.attributes = attributes
        self.hasUppercaseKeys = hasUppercaseKeys
    }

    /// Adopts a token's deferred attributes before an element owns this collection.
    internal init(pendingAttributes: [PendingAttribute]) {
        self.pendingAttributes = pendingAttributes
        pendingAttributesCount = pendingAttributes.count
        hasUppercaseKeys = pendingAttributes.contains { $0.hasUppercase }
    }

    /// Materializes a deferred attribute, throwing if the key fails validation (e.g. an
    /// empty-after-trim key). Callers invoke this via `try?` and drop anything that fails,
    /// matching jsoup — never trapping. See #392.
    @usableFromInline
    @inline(__always)
    internal func makeMaterializedAttribute(keySlice: ByteSlice, value: PendingAttrValue) throws -> Attribute {
        switch value {
        case .none:
            return try BooleanAttribute(keySlice: keySlice)
        case .empty:
            return try Attribute(keySlice: keySlice, valueSlice: ByteSlice.empty)
        case .slice(let slice):
            return try Attribute(keySlice: keySlice, valueSlice: slice)
        case .slices(let slices, _):
            guard let first = slices.first else {
                return try Attribute(keySlice: keySlice, valueSlice: ByteSlice.empty)
            }
            let attribute = try Attribute(keySlice: keySlice, valueSlice: first)
            for slice in slices.dropFirst() {
                attribute.appendValueSlice(slice)
            }
            return attribute
        case .bytes(let bytes):
            return try Attribute(keySlice: keySlice, valueSlice: ByteSlice.fromArray(bytes))
        }
    }

    @usableFromInline
    @inline(__always)
    internal func appendPending(_ pending: PendingAttribute) {
        if !attributes.isEmpty {
            // If materialized already, fall back to regular put.
            guard let keySlice = pending.normalizedKey() else { return }
            // Drop malformed attributes (e.g. an empty-after-trim key) rather than
            // trapping; jsoup does the same. See #392.
            guard let attribute = try? makeMaterializedAttribute(keySlice: keySlice, value: pending.value) else { return }
            putMaterialized(attribute)
            return
        }

        if pendingAttributes == nil {
            pendingAttributes = []
            pendingAttributes!.reserveCapacity(16)
            pendingAttributes!.append(pending)
            pendingAttributesCount = 1
        } else {
            pendingAttributes!.append(pending)
            pendingAttributesCount &+= 1
        }
        if !hasUppercaseKeys && pending.hasUppercase {
            hasUppercaseKeys = true
        }
        invalidateLowercasedKeysCache()
        invalidateKeyIndex()
        notifyMutationOwners()
    }

    @usableFromInline
    @inline(__always)
    internal func ensureMaterialized() {
        guard let pending = pendingAttributes, !pending.isEmpty else { return }
        DebugTrace.log("Attributes.ensureMaterialized: pending=\(pending.count)")
        pendingAttributesCount = 0
        let shouldIndex = attributes.count + pending.count >= Self.keyIndexThreshold
        var localIndex: [ByteSlice: Int]? = nil
        if shouldIndex {
            if !keyIndexDirty, let existing = keyIndex {
                localIndex = existing
            } else {
                localIndex = [:]
                localIndex?.reserveCapacity(attributes.count + pending.count)
                for (idx, attr) in attributes.enumerated() {
                    if localIndex?[attr.keySlice] == nil {
                        localIndex?[attr.keySlice] = idx
                    }
                }
            }
        }
        // Build locally so the array observer invalidates owner indexes once,
        // rather than once for every appended or replaced attribute.
        var materialized = attributes
        materialized.reserveCapacity(materialized.count + pending.count)
        for pendingAttr in pending {
            if let nameBytes = pendingAttr.nameBytes {
                DebugTrace.log("Attributes.ensureMaterialized: nameBytes=\(String(decoding: nameBytes, as: UTF8.self))")
            } else if let nameSlice = pendingAttr.nameSlice {
                DebugTrace.log("Attributes.ensureMaterialized: nameSlice count=\(nameSlice.count)")
            } else {
                DebugTrace.log("Attributes.ensureMaterialized: missing name")
            }
            guard let keySlice = pendingAttr.normalizedKey() else { continue }
            // Drop malformed attributes (e.g. an empty-after-trim key) rather than
            // trapping; jsoup does the same. This is the path #392 hits via
            // getIgnoreCase during select()'s query-index rebuild.
            guard let attribute = try? makeMaterializedAttribute(keySlice: keySlice, value: pendingAttr.value) else { continue }
            let keyForIndex = attribute.keySlice
            if Attributes.containsAsciiUppercase(keyForIndex) {
                hasUppercaseKeys = true
            }
            if let index = localIndex?[keyForIndex] {
                materialized[index] = attribute
            } else if shouldIndex {
                localIndex?[keyForIndex] = materialized.count
                materialized.append(attribute)
            } else if let index = materialized.firstIndex(where: { $0.keySlice == keyForIndex }) {
                materialized[index] = attribute
            } else {
                materialized.append(attribute)
            }
        }
        // Initial deferred storage is already the logical contents. A merge into
        // existing attributes may replace values and must still invalidate owners.
        isMaterializing = attributes.isEmpty
        attributes = materialized
        isMaterializing = false
        if let localIndex {
            keyIndex = localIndex
            keyIndexDirty = false
        } else {
            keyIndexDirty = true
        }
        pendingAttributes?.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    internal func putMaterialized(_ attribute: Attribute) {
        let keySlice = attribute.keySlice
        let hasUppercase = Attributes.containsAsciiUppercase(keySlice)
        let normalizedKey = hasUppercase ? attribute.lowerKeySlice() : keySlice
        if let ix = indexForKey(keySlice) {
            attributes[ix] = attribute
            if !keyIndexDirty, keyIndex != nil {
                keyIndex?[keySlice] = ix
            }
        } else {
            attributes.append(attribute)
            if !keyIndexDirty, keyIndex != nil {
                keyIndex?[keySlice] = attributes.count - 1
            }
        }
        if !hasUppercaseKeys && hasUppercase {
            hasUppercaseKeys = true
        }
        invalidateLowercasedKeysCache()
        if equalsSlice(normalizedKey, UTF8Arrays.class_) {
            ownerElement?.markClassQueryIndexDirty()
        }
        if equalsSlice(normalizedKey, SwiftSoup.Element.idString) {
            ownerElement?.markIdQueryIndexDirty()
        }
        ownerElement?.markAttributeQueryIndexDirty()
        ownerElement?.markAttributeValueQueryIndexDirty(for: attribute.getKeyUTF8())
    }
    
    @usableFromInline
    @inline(__always)
    internal func updateLowercasedKeysCache() {
        ensureMaterialized()
        lowercasedKeysCache = Set(attributes.map { attr in
            attr.lowerKeySlice()
        })
    }

    @usableFromInline
    @inline(__always)
    internal func ensureLowercasedKeyIndex() {
        ensureMaterialized()
        guard shouldBuildKeyIndex() else { return }
        if lowercasedKeyIndexDirty || lowercasedKeyIndex == nil {
            var rebuilt: [ByteSlice: Int] = [:]
            rebuilt.reserveCapacity(attributes.count)
            for (index, attr) in attributes.enumerated() {
                let lowerKey = attr.lowerKeySlice()
                if rebuilt[lowerKey] == nil {
                    rebuilt[lowerKey] = index
                }
            }
            lowercasedKeyIndex = rebuilt
            lowercasedKeyIndexDirty = false
        }
    }
    
    @usableFromInline
    @inline(__always)
    internal func invalidateLowercasedKeysCache() {
        lowercasedKeysCache = nil
        lowercasedKeyIndex = nil
        lowercasedKeyIndexDirty = true
    }

    @usableFromInline
    @inline(__always)
    internal func invalidateKeyIndex() {
        keyIndex = nil
        keyIndexDirty = true
    }

    @usableFromInline
    @inline(__always)
    func shouldBuildKeyIndex() -> Bool {
        return attributes.count >= Self.keyIndexThreshold
    }

    @usableFromInline
    @inline(__always)
    func ensureKeyIndex() {
        ensureMaterialized()
        guard shouldBuildKeyIndex() else { return }
        if keyIndexDirty || keyIndex == nil {
            var rebuilt: [ByteSlice: Int] = [:]
            rebuilt.reserveCapacity(attributes.count)
            for (index, attr) in attributes.enumerated() {
                if rebuilt[attr.keySlice] == nil {
                    rebuilt[attr.keySlice] = index
                }
            }
            keyIndex = rebuilt
            keyIndexDirty = false
        }
    }

    @usableFromInline
    @inline(__always)
    func indexForKey(_ key: [UInt8]) -> Int? {
        return indexForKey(ByteSlice.fromArray(key))
    }

    @usableFromInline
    @inline(__always)
    func indexForKey(_ key: ByteSlice) -> Int? {
        ensureMaterialized()
        if !Self.disableLowercasedKeyIndex, shouldBuildKeyIndex() {
            ensureKeyIndex()
            return keyIndex?[key]
        }
        return attributes.firstIndex(where: { $0.keySlice == key })
    }
    
    /**
     Get an attribute value by key.
     - parameter key: the (case-sensitive) attribute key
     - returns: the attribute value if set; or empty string if not set.
     - seealso: ``hasKey(key:)-(String)``
     */
    @inline(__always)
    open func get(key: String) -> String {
        if let lookup = UTF8Arrays.attributeLookup[key] {
            return String(decoding: get(key: lookup), as: UTF8.self)
        }
        return String(decoding: get(key: key.utf8Array), as: UTF8.self)
    }
    
    @inline(__always)
    open func get(key: [UInt8]) -> [UInt8] {
        DebugTrace.log("Attributes.get(key): \(String(decoding: key, as: UTF8.self))")
        if attributes.isEmpty {
            if let value = pendingValueCaseSensitive(key) { return value }
            // Validation may have materialized an ambiguous batch. Otherwise a
            // miss is conclusive and must not instantiate every Attribute.
            if attributes.isEmpty { return [] }
        }
        ensureMaterialized()
        if let ix = indexForKey(key) {
            return attributes[ix].getValueUTF8()
        }
        return []
    }
    
    /**
     Get an attribute's value by case-insensitive key
     - parameter key: the attribute name
     - returns: the first matching attribute value if set; or empty string if not set.
     */
    @inline(__always)
    open func getIgnoreCase(key: String) throws -> String {
        if let lookup = UTF8Arrays.attributeLookup[key] {
            return try String(decoding: getIgnoreCase(key: lookup), as: UTF8.self)
        }
        return try String(decoding: getIgnoreCase(key: key.utf8Array), as: UTF8.self)
    }
    
    @inline(__always)
    open func getIgnoreCase(key: [UInt8]) throws -> [UInt8] {
        try Validate.notEmpty(string: key)
        if attributes.isEmpty {
            if let value = pendingValueIgnoreCase(key) { return value }
            if attributes.isEmpty { return [] }
        }
        ensureMaterialized()
        let keySlice = ByteSlice.fromArray(key)
        let hasUppercase = Attributes.containsAsciiUppercase(key)
        if !Self.disableLowercasedKeyIndex, shouldBuildKeyIndex() {
            ensureLowercasedKeyIndex()
            if let lowercasedKeyIndex {
                let lookupKey = hasUppercase ? keySlice.lowercased() : keySlice
                if let ix = lowercasedKeyIndex[lookupKey] {
                    return attributes[ix].getValueUTF8()
                }
                return []
            }
        }
        if lowercasedKeysCache == nil {
            updateLowercasedKeysCache()
        }
        let normalizedKey = hasUppercase ? keySlice.lowercased() : keySlice
        guard lowercasedKeysCache?.contains(normalizedKey) ?? false else { return [] }
        if !hasUppercaseKeys {
            if let ix = indexForKey(normalizedKey) {
                return attributes[ix].getValueUTF8()
            }
            return []
        }
        if let attr = attributes.first(where: { equalsIgnoreCase($0.keySlice, key) }) {
            return attr.getValueUTF8()
        }
        return []
    }

    @inline(__always)
    @usableFromInline
    internal func getIgnoreCaseSlice(key: [UInt8]) throws -> ByteSlice {
        try Validate.notEmpty(string: key)
        if attributes.isEmpty {
            if let pendingSlice = pendingValueIgnoreCaseSlice(key) {
                return pendingSlice
            }
            if let pendingValue = pendingValueIgnoreCase(key) {
                return ByteSlice.fromArray(pendingValue)
            }
            if attributes.isEmpty { return ByteSlice.empty }
        }
        ensureMaterialized()
        let keySlice = ByteSlice.fromArray(key)
        let hasUppercase = Attributes.containsAsciiUppercase(key)
        if !Self.disableLowercasedKeyIndex, shouldBuildKeyIndex() {
            ensureLowercasedKeyIndex()
            if let lowercasedKeyIndex {
                let lookupKey = hasUppercase ? keySlice.lowercased() : keySlice
                if let ix = lowercasedKeyIndex[lookupKey] {
                    return attributes[ix].valueSliceMaterialized()
                }
                return ByteSlice.empty
            }
        }
        if lowercasedKeysCache == nil {
            updateLowercasedKeysCache()
        }
        let normalizedKey = hasUppercase ? keySlice.lowercased() : keySlice
        guard lowercasedKeysCache?.contains(normalizedKey) ?? false else { return ByteSlice.empty }
        if !hasUppercaseKeys {
            if let ix = indexForKey(normalizedKey) {
                return attributes[ix].valueSliceMaterialized()
            }
            return ByteSlice.empty
        }
        if let attr = attributes.first(where: { equalsIgnoreCase($0.keySlice, key) }) {
            return attr.valueSliceMaterialized()
        }
        return ByteSlice.empty
    }
    
    /**
     Set a new attribute, or replace an existing one by key.
     - parameter key: attribute key
     - parameter value: attribute value
     */
    @inline(__always)
    open func put(_ key: [UInt8], _ value: [UInt8]) throws {
        ensureMaterialized()
        let attr = try Attribute(key: key, value: value)
        put(attribute: attr)
    }
    
    @inline(__always)
    open func put(_ key: String, _ value: String) throws {
        if let lookup = UTF8Arrays.attributeLookup[key] {
            return try put(lookup, value.utf8Array)
        }
        return try put(key.utf8Array, value.utf8Array)
    }
    
    /**
     Set a new boolean attribute, remove attribute if value is false.
     - parameter key: attribute key
     - parameter value: attribute value
     */
    @inline(__always)
    open func put(_ key: [UInt8], _ value: Bool) throws {
        ensureMaterialized()
        if (value) {
            try put(attribute: BooleanAttribute(key: key))
        } else {
            try remove(key: key)
        }
    }
    
    /**
     Set a new attribute, or replace an existing one by (case-sensitive) key.
     - parameter attribute: attribute
     */
    @inline(__always)
    open func put(attribute: Attribute) {
        ensureMaterialized()
        putMaterialized(attribute)
        attribute.observeMutations(in: self)
    }
    
    /**
     Remove an attribute by key. <b>Case sensitive.</b>
     - parameter key: attribute key to remove
     */
    @inline(__always)
    open func remove(key: String) throws {
        ensureMaterialized()
        if let lookup = UTF8Arrays.attributeLookup[key] {
            try remove(key: lookup)
            return
        }
        try remove(key: key.utf8Array)
    }
    
    @inlinable
    open func remove(key: [UInt8]) throws {
        ensureMaterialized()
        try Validate.notEmpty(string: key)
        if let ix = indexForKey(key) {
            attributes.remove(at: ix)
            invalidateLowercasedKeysCache()
            invalidateKeyIndex()
            let normalizedKey = key.lowercased()
            if normalizedKey == UTF8Arrays.class_ {
                ownerElement?.markClassQueryIndexDirty()
            }
            if normalizedKey == SwiftSoup.Element.idString {
                ownerElement?.markIdQueryIndexDirty()
            }
            ownerElement?.markAttributeQueryIndexDirty()
            ownerElement?.markAttributeValueQueryIndexDirty(for: key)
        }
    }
    
    /**
     Remove an attribute by key. <b>Case insensitive.</b>
     - parameter key: attribute key to remove
     */
    @inlinable
    open func removeIgnoreCase(key: [UInt8]) throws {
        ensureMaterialized()
        try Validate.notEmpty(string: key)
        if let ix = attributes.firstIndex(where: { equalsIgnoreCase($0.keySlice, key) }) {
            let normalizedKey = key.lowercased()
            attributes.remove(at: ix)
            invalidateLowercasedKeysCache()
            invalidateKeyIndex()
            if normalizedKey == UTF8Arrays.class_ {
                ownerElement?.markClassQueryIndexDirty()
            }
            if normalizedKey == SwiftSoup.Element.idString {
                ownerElement?.markIdQueryIndexDirty()
            }
            ownerElement?.markAttributeQueryIndexDirty()
            ownerElement?.markAttributeValueQueryIndexDirty(for: key)
        }
    }

    /**
     Remove multiple attributes by exact key bytes in a single pass.
     - parameter keys: attribute keys to remove (case sensitive)
     */
    @inline(__always)
    open func removeAll(keys: [[UInt8]]) {
        ensureMaterialized()
        guard !keys.isEmpty else { return }
        guard !attributes.isEmpty else { return }

        var removedKeys: [[UInt8]] = []
        removedKeys.reserveCapacity(Swift.min(keys.count, attributes.count))
        var writeIndex = 0
        let originalCount = attributes.count
        for readIndex in 0..<originalCount {
            let attr = attributes[readIndex]
            var shouldRemove = false
            for removalKey in keys {
                if equalsSlice(attr.keySlice, removalKey) {
                    shouldRemove = true
                    break
                }
            }
            if shouldRemove {
                removedKeys.append(attr.getKeyUTF8())
            } else {
                if writeIndex != readIndex {
                    attributes[writeIndex] = attr
                }
                writeIndex += 1
            }
        }

        guard !removedKeys.isEmpty else { return }
        if writeIndex < originalCount {
            attributes.removeLast(originalCount - writeIndex)
        }
        invalidateLowercasedKeysCache()
        invalidateKeyIndex()

        if let ownerElement {
            for key in removedKeys {
                let normalizedKey = key.lowercased()
                if normalizedKey == UTF8Arrays.class_ {
                    ownerElement.markClassQueryIndexDirty()
                }
                if normalizedKey == SwiftSoup.Element.idString {
                    ownerElement.markIdQueryIndexDirty()
                }
                ownerElement.markAttributeValueQueryIndexDirty(for: key)
            }
            ownerElement.markAttributeQueryIndexDirty()
        }
    }

    /**
     Compact the attribute list in one pass, allowing in-place mutation of values.
     - parameter body: return whether to keep the attribute and optionally a new value.
     */
    @inline(__always)
    open func compactAndMutate(_ body: (Attribute) -> AttributeMutation) {
        ensureMaterialized()
        guard !attributes.isEmpty else { return }

        let ownerElement = self.ownerElement
        var didMutate = false
        var dirtyClass = false
        var dirtyId = false

        @inline(__always)
        func markDirty(for key: [UInt8]) {
            let normalizedKey = key.lowercased()
            if normalizedKey == UTF8Arrays.class_ {
                dirtyClass = true
            }
            if normalizedKey == SwiftSoup.Element.idString {
                dirtyId = true
            }
            ownerElement?.markAttributeValueQueryIndexDirty(for: key)
        }

        var writeIndex = 0
        let originalCount = attributes.count
        for readIndex in 0..<originalCount {
            let attr = attributes[readIndex]
            attr.observeMutations(in: self)
            let decision = body(attr)
            if let newValue = decision.newValue {
                _ = attr.setValue(value: newValue)
                if ownerElement != nil {
                    markDirty(for: attr.getKeyUTF8())
                }
                didMutate = true
            }
            if decision.keep {
                if writeIndex != readIndex {
                    attributes[writeIndex] = attr
                }
                writeIndex += 1
            } else {
                if ownerElement != nil {
                    markDirty(for: attr.getKeyUTF8())
                }
                didMutate = true
            }
        }

        if writeIndex < originalCount {
            attributes.removeLast(originalCount - writeIndex)
            didMutate = true
        }

        guard didMutate else { return }

        invalidateLowercasedKeysCache()
        if writeIndex < originalCount {
            invalidateKeyIndex()
        }

        if let ownerElement {
            if dirtyClass {
                ownerElement.markClassQueryIndexDirty()
            }
            if dirtyId {
                ownerElement.markIdQueryIndexDirty()
            }
            ownerElement.markAttributeQueryIndexDirty()
        }
    }

    @usableFromInline
    @inline(__always)
    internal func appendValueSlice(key: [UInt8], slice: ByteSlice) {
        ensureMaterialized()
        guard !key.isEmpty else { return }
        if let ix = indexForKey(key) {
            attributes[ix].observeMutations(in: self)
            attributes[ix].appendValueSlice(slice)
            let normalizedKey = key.lowercased()
            if normalizedKey == UTF8Arrays.class_ {
                ownerElement?.markClassQueryIndexDirty()
            }
            if normalizedKey == SwiftSoup.Element.idString {
                ownerElement?.markIdQueryIndexDirty()
            }
            ownerElement?.markAttributeValueQueryIndexDirty(for: key)
            ownerElement?.markSourceDirty()
            return
        }
        let keySlice = ByteSlice.fromArray(key).trim()
        // Drop a malformed key rather than trapping; jsoup does the same. See #392.
        guard let attribute = try? Attribute(keySlice: keySlice, valueSlice: slice) else { return }
        putMaterialized(attribute)
        ownerElement?.markSourceDirty()
    }

    
    /**
     Tests if these attributes contain an attribute with this key.
     - parameter key: case-sensitive key to check for
     - returns: true if key exists, false otherwise
     */
    @inline(__always)
    open func hasKey(key: String) -> Bool {
        if let lookup = UTF8Arrays.attributeLookup[key] {
            return hasKey(key: lookup)
        }
        return hasKey(key: key.utf8Array)
    }
    
    @inline(__always)
    open func hasKey(key: [UInt8]) -> Bool {
        if attributes.isEmpty {
            if pendingHasKeyCaseSensitive(key) { return true }
            if attributes.isEmpty { return false }
        }
        ensureMaterialized()
        return indexForKey(key) != nil
    }
    
    /**
     Tests if these attributes contain an attribute with this key.
     - parameter key: key to check for
     - returns: true if key exists, false otherwise
     */
    @inline(__always)
    open func hasKeyIgnoreCase(key: String) -> Bool {
        if let lookup = UTF8Arrays.attributeLookup[key] {
            return hasKeyIgnoreCase(key: lookup)
        }
        return hasKeyIgnoreCase(key: key.utf8Array)
    }

    @inline(__always)
    open func hasKeyIgnoreCase(key: [UInt8]) -> Bool {
        if attributes.isEmpty {
            if pendingHasKeyIgnoreCase(key) { return true }
            if attributes.isEmpty { return false }
        }
        ensureMaterialized()
        guard !key.isEmpty else { return false }
        let keySlice = ByteSlice.fromArray(key)
        let hasUppercase = Attributes.containsAsciiUppercase(key)
        if shouldBuildKeyIndex() {
            ensureLowercasedKeyIndex()
            if let lowercasedKeyIndex {
                let lookupKey = hasUppercase ? keySlice.lowercased() : keySlice
                return lowercasedKeyIndex[lookupKey] != nil
            }
        }
        if lowercasedKeysCache == nil {
            updateLowercasedKeysCache()
        }
        let normalizedKey = hasUppercase ? keySlice.lowercased() : keySlice
        return lowercasedKeysCache!.contains(normalizedKey)
    }

    @inline(__always)
    @usableFromInline
    internal static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        return (byte >= 65 && byte <= 90) ? (byte + 32) : byte
    }

    
    @inlinable
    open func hasKeyIgnoreCase<T: Collection>(key: T) -> Bool where T.Element == UInt8 {
        if attributes.isEmpty {
            if pendingHasKeyIgnoreCase(key) { return true }
            if attributes.isEmpty { return false }
        }
        ensureMaterialized()
        guard !key.isEmpty else { return false }
        if shouldBuildKeyIndex() {
            ensureLowercasedKeyIndex()
            if let lowercasedKeyIndex {
                if let key = key as? [UInt8], key.allSatisfy({ $0 < 65 || $0 > 90 }) {
                    return lowercasedKeyIndex[ByteSlice.fromArray(key)] != nil
                }
                var lowerQuery: [UInt8] = []
                lowerQuery.reserveCapacity(key.count)
                for b in key {
                    lowerQuery.append(Self.asciiLowercase(b))
                }
                return lowercasedKeyIndex[ByteSlice.fromArray(lowerQuery)] != nil
            }
        }
        if lowercasedKeysCache == nil {
            updateLowercasedKeysCache()
        }
        if let key = key as? [UInt8], key.allSatisfy({ $0 < 65 || $0 > 90 }) {
            return lowercasedKeysCache!.contains(ByteSlice.fromArray(key))
        }
        var lowerQuery: [UInt8] = []
        lowerQuery.reserveCapacity(key.count)
        for b in key {
            lowerQuery.append(Self.asciiLowercase(b))
        }
        return lowercasedKeysCache!.contains(ByteSlice.fromArray(lowerQuery))
    }

    @inline(__always)
    @usableFromInline
    internal func pendingHasKeyCaseSensitive(_ key: [UInt8]) -> Bool {
        return pendingAttributeCaseSensitive(key) != nil
    }

    @inline(__always)
    @usableFromInline
    internal func pendingHasKeyIgnoreCase<T: Collection>(_ key: T) -> Bool where T.Element == UInt8 {
        return pendingAttributeIgnoreCase(key) != nil
    }

    // Deferred reads can stop at the first match only when names are valid,
    // normalized, and unique. Ambiguous batches use the existing materializer,
    // which keeps the first position and the last value of an exact duplicate.
    // Ordinary parser batches stay deferred, and validation is amortized once.
    @usableFromInline
    internal func ensureCanonicalPendingNames() {
        guard !pendingNamesAreCanonical, attributes.isEmpty else { return }
        guard let pending = pendingAttributes, !pending.isEmpty else {
            pendingNamesAreCanonical = true
            return
        }
        // Keep worst-case collision work bounded. Larger batches use an exact
        // hash set; small parser batches avoid its allocation and name wrapping.
        if pending.count <= 32 {
            let canonical = withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 32) { masks in
                masks.initialize(repeating: 0)
                defer { masks.deinitialize() }
                var seen: UInt64 = 0
                for index in pending.indices {
                    let attr = pending[index]
                    guard let mask = attr.canonicalNameMask() else { return false }
                    if seen & mask != 0 {
                        // Scan cheap stored masks, not whole PendingAttribute values.
                        for previous in 0..<index where masks[previous] == mask {
                            if attr.hasSameName(as: pending[previous]) { return false }
                        }
                    }
                    masks[index] = mask
                    seen |= mask
                }
                return true
            }
            if !canonical { ensureMaterialized() }
            pendingNamesAreCanonical = true
            return
        }
        var seen = Set<ByteSlice>()
        seen.reserveCapacity(pending.count)
        for attr in pending {
            guard attr.canonicalNameMask() != nil else {
                ensureMaterialized()
                pendingNamesAreCanonical = true
                return
            }
            // Names are already validated; do not trim them a second time.
            let key = attr.nameBytes.map { ByteSlice.fromArray($0) } ?? attr.nameSlice!
            guard seen.insert(key).inserted else {
                ensureMaterialized()
                pendingNamesAreCanonical = true
                return
            }
        }
        pendingNamesAreCanonical = true
    }

    @inline(__always)
    @usableFromInline
    internal func pendingAttributeCaseSensitive(_ key: [UInt8]) -> PendingAttribute? {
        ensureCanonicalPendingNames()
        guard !key.isEmpty, attributes.isEmpty, let pending = pendingAttributes else { return nil }
        for attr in pending {
            if let nameBytes = attr.nameBytes {
                if nameBytes == key { return attr }
            } else if let nameSlice = attr.nameSlice, equalsSlice(nameSlice, key) {
                return attr
            }
        }
        return nil
    }

    @inline(__always)
    @usableFromInline
    internal func pendingAttributeIgnoreCase<T: Collection>(_ key: T) -> PendingAttribute? where T.Element == UInt8 {
        ensureCanonicalPendingNames()
        guard !key.isEmpty, attributes.isEmpty, let pending = pendingAttributes else { return nil }
        for attr in pending {
            if let nameBytes = attr.nameBytes {
                if equalsIgnoreCase(nameBytes, key) { return attr }
            } else if let nameSlice = attr.nameSlice, equalsIgnoreCase(nameSlice, key) {
                return attr
            }
        }
        return nil
    }

    @inline(__always)
    @usableFromInline
    internal func pendingValueCaseSensitive(_ key: [UInt8]) -> [UInt8]? {
        return pendingAttributeCaseSensitive(key).map { materializePendingValue($0.value) }
    }

    @inline(__always)
    @usableFromInline
    internal func pendingValueCaseSensitiveSlice(_ key: [UInt8]) -> ByteSlice? {
        return pendingAttributeCaseSensitive(key).flatMap { pendingValueSlice($0.value) }
    }

    @inline(__always)
    @usableFromInline
    internal func valueSliceCaseSensitive(_ key: [UInt8]) -> ByteSlice? {
        ensureCanonicalPendingNames()
        if attributes.isEmpty {
            if let pendingSlice = pendingValueCaseSensitiveSlice(key) {
                return pendingSlice
            }
            if let pendingValue = pendingValueCaseSensitive(key) {
                return ByteSlice.fromArray(pendingValue)
            }
            return nil
        }
        ensureMaterialized()
        if let ix = indexForKey(key) {
            return attributes[ix].valueSliceMaterialized()
        }
        return nil
    }

    @inline(__always)
    @usableFromInline
    internal func pendingValueIgnoreCase<T: Collection>(_ key: T) -> [UInt8]? where T.Element == UInt8 {
        return pendingAttributeIgnoreCase(key).map { materializePendingValue($0.value) }
    }

    @inline(__always)
    @usableFromInline
    internal func pendingValueIgnoreCaseSlice<T: Collection>(_ key: T) -> ByteSlice? where T.Element == UInt8 {
        return pendingAttributeIgnoreCase(key).flatMap { pendingValueSlice($0.value) }
    }

    @inline(__always)
    @usableFromInline
    internal func pendingValueSlice(_ value: PendingAttrValue) -> ByteSlice? {
        switch value {
        case .none, .empty:
            return ByteSlice.empty
        case .slice(let slice):
            return slice
        case .bytes(let bytes):
            return ByteSlice.fromArray(bytes)
        case .slices:
            // The byte-returning fallback joins fragmented storage only when needed.
            return nil
        }
    }

    @inline(__always)
    @usableFromInline
    internal func materializePendingValue(_ value: PendingAttrValue) -> [UInt8] {
        switch value {
        case .none:
            return []
        case .empty:
            return []
        case .slice(let slice):
            return Array(slice)
        case .slices(let slices, let count):
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            for slice in slices {
                bytes.append(contentsOf: slice)
            }
            return bytes
        case .bytes(let bytes):
            return bytes
        }
    }

    @inline(__always)
    @usableFromInline
    internal func equalsSlice(_ slice: ByteSlice, _ key: [UInt8]) -> Bool {
        if slice.count != key.count {
            return false
        }
        var i = key.startIndex
        var j = slice.startIndex
        let end = key.endIndex
        while i < end {
            if key[i] != slice[j] {
                return false
            }
            i = key.index(after: i)
            j = slice.index(after: j)
        }
        return true
    }

    @inline(__always)
    @usableFromInline
    internal func equalsIgnoreCase<T: Collection>(_ bytes: [UInt8], _ key: T) -> Bool where T.Element == UInt8 {
        if bytes.count != key.count {
            return false
        }
        var i = bytes.startIndex
        for b in key {
            if Self.asciiLowercase(bytes[i]) != Self.asciiLowercase(b) {
                return false
            }
            i = bytes.index(after: i)
        }
        return true
    }

    @inline(__always)
    @usableFromInline
    internal func equalsIgnoreCase<T: Collection>(_ slice: ByteSlice, _ key: T) -> Bool where T.Element == UInt8 {
        if slice.count != key.count {
            return false
        }
        var i = slice.startIndex
        for b in key {
            if Self.asciiLowercase(slice[i]) != Self.asciiLowercase(b) {
                return false
            }
            i = slice.index(after: i)
        }
        return true
    }
    
    /**
     Get the number of attributes in this set.
     - returns: size
     */
    @inline(__always)
    open func size() -> Int {
        ensureMaterialized()
        return attributes.count
    }
    
    /**
     Add all the attributes from the incoming set to this set.
     - parameter incoming: attributes to add to these attributes.
     */
    @inline(__always)
    open func addAll(incoming: Attributes?) {
        ensureMaterialized()
        guard let incoming = incoming else { return }
        incoming.ensureMaterialized()
        for attr in incoming.attributes {
            attr.observeMutations(in: incoming)
            put(attribute: attr)
        }
    }
    
    /**
     Get a snapshot of the attribute list containing live, mutable attribute references.
     Key and value changes update the containing collections; editing the returned array does not.
     - returns: a snapshot of the attribute references in insertion order.
     */
    @inline(__always)
    open func asList() -> [Attribute] {
        ensureMaterialized()
        observeAttributeMutations()
        return attributes
    }
    
    /**
     Retrieves a filtered view of attributes that are HTML5 custom data attributes; that is, attributes with keys
     starting with `data-`.
     - returns: map of custom data attributes.
     */
    @inline(__always)
    open func dataset() -> [String: String] {
        ensureMaterialized()
        let prefixLength = Attributes.dataPrefix.count
        var result: [String: String] = [:]
        result.reserveCapacity(attributes.count)
        for attr in attributes where attr.isDataAttribute() {
            let key = attr.getKey().substring(prefixLength)
            let value = String(decoding: attr.valueSliceMaterialized(), as: UTF8.self)
            result[key] = value
        }
        return result
    }
    
    /**
     Get the HTML representation of these attributes.
     - returns: HTML
     */
    @inline(__always)
    open func html() throws -> String {
        let accum = StringBuilder()
        try html(accum: accum, out: Document([]).outputSettings()) // output settings a bit funky, but this html() seldom used
        return accum.toString()
    }
    
    /**
     Get the HTML representation of these attributes.
     - returns: HTML
     */
    @inline(__always)
    open func htmlUTF8() throws -> [UInt8] {
        let accum = StringBuilder()
        try html(accum: accum, out: Document([]).outputSettings()) // output settings a bit funky, but this html() seldom used
        return Array(accum.buffer)
    }

    @usableFromInline
    @inline(__always)
    internal func appendPendingHtml(_ attr: PendingAttribute, _ accum: StringBuilder, _ out: OutputSettings) {
        guard let keySlice = attr.normalizedKey() else { return }
        accum.append(keySlice)

        var valueSlice: ByteSlice? = nil
        var hasValue = false
        switch attr.value {
        case .none:
            hasValue = false
        case .empty:
            hasValue = true
            valueSlice = ByteSlice.empty
        case .slice(let slice):
            hasValue = true
            valueSlice = slice
        case .slices(let slices, let count):
            hasValue = true
            var combined: [UInt8] = []
            combined.reserveCapacity(count)
            for slice in slices {
                combined.append(contentsOf: slice)
            }
            valueSlice = ByteSlice.fromArray(combined)
        case .bytes(let bytes):
            hasValue = true
            valueSlice = ByteSlice.fromArray(bytes)
        }
        let keyLower = keySlice.lowercased()
        let isImplicitBoolean = {
            switch attr.value {
            case .none: return true
            default: return false
            }
        }()
        let isBoolean = isImplicitBoolean || Attribute.booleanAttributes.contains(keyLower)

        var shouldCollapse = false
        if out.syntax() == OutputSettings.Syntax.html && isBoolean {
            if !hasValue {
                shouldCollapse = true
            } else if let valueSlice {
                shouldCollapse = valueSlice.isEmpty
            }
        }

        if !shouldCollapse {
            accum.append(UTF8Arrays.attributeEqualsQuoteMark)
            if let valueSlice {
                Attribute.appendAttributeValue(accum, out, valueSlice)
            }
            accum.append(UTF8Arrays.quoteMark)
        }
    }
    
    @inlinable
    public func html(accum: StringBuilder, out: OutputSettings ) throws {
        ensureCanonicalPendingNames()
        if attributes.isEmpty, let pending = pendingAttributes, !pending.isEmpty {
            for attr in pending {
                accum.append(UTF8Arrays.whitespace)
                appendPendingHtml(attr, accum, out)
            }
            return
        }
        ensureMaterialized()
        for attr in attributes {
            accum.append(UTF8Arrays.whitespace)
            attr.html(accum: accum, out: out)
        }
    }
    
    @inline(__always)
    open func toString()throws -> String {
        return try html()
    }

    @usableFromInline
    @inline(__always)
    internal static func equalsIgnoreCase(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var i = lhs.startIndex
        var j = rhs.startIndex
        while i < lhs.endIndex {
            let b1 = lhs[i]
            let b2 = rhs[j]
            let lower1 = (b1 >= 65 && b1 <= 90) ? (b1 &+ 32) : b1
            let lower2 = (b2 >= 65 && b2 <= 90) ? (b2 &+ 32) : b2
            if lower1 != lower2 { return false }
            i = lhs.index(after: i)
            j = rhs.index(after: j)
        }
        return true
    }
    
    /**
     Checks if these attributes are equal to another set of attributes, by comparing the two sets
     - parameter o: attributes to compare with
     - returns: if both sets of attributes have the same content
     */
    @inline(__always)
    open func equals(o: AnyObject?) -> Bool {
        if(o == nil) {return false}
        if (self === o.self) {return true}
        guard let that = o as? Attributes else {return false}
        ensureMaterialized()
        that.ensureMaterialized()
        return (attributes == that.attributes)
    }
    
    @inline(__always)
    open func lowercaseAllKeys() {
        ensureMaterialized()
        guard hasUppercaseKeys else { return }
        for attribute in attributes {
            // Notify shared owners, preserving normalization's storage-only behavior.
            attribute.setNormalizedKey(attribute.lowerKeySlice())
        }
        hasUppercaseKeys = false
        invalidateLowercasedKeysCache()
        invalidateKeyIndex()
        notifyMutationOwners()
    }
    
    @inline(__always)
    public func copy(with zone: NSZone? = nil) -> Any {
        ensureMaterialized()
        let copied = attributes.map { $0.clone() }
        return Attributes(copying: copied, hasUppercaseKeys: copied.contains { Self.containsAsciiUppercase($0.keySlice) })
    }
    
    @inline(__always)
    open func clone() -> Attributes {
        ensureMaterialized()
        return self.copy() as! Attributes
    }
    
    @inline(__always)
    fileprivate static func dataKey(key: [UInt8]) -> [UInt8] {
        return dataPrefix + key
    }
    
    @inline(__always)
    internal static func containsAsciiUppercase(_ key: [UInt8]) -> Bool {
        for b in key {
            if b >= 65 && b <= 90 {
                return true
            }
        }
        return false
    }


    @inline(__always)
    internal static func containsAsciiUppercase(_ key: ByteSlice) -> Bool {
        return key.withUnsafeBytes { bytes in
            bytes.contains { $0 >= 65 && $0 <= 90 }
        }
    }
    
}

extension Attributes: Sequence {
    public func makeIterator() -> AnyIterator<Attribute> {
        ensureMaterialized()
        observeAttributeMutations()
        return AnyIterator(attributes.makeIterator())
    }
}
