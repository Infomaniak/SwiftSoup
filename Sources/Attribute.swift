//
//  Attribute.swift
//  SwifSoup
//
//  Created by Nabil Chatbi on 29/09/16.
//

import Foundation

open class Attribute {
    // Installed only when a mutable reference escapes to a caller or is shared.
    // Weak ownership preserves the lifetime of detached attributes and DOM trees.
    internal var mutationOwners: [Weak<Attributes>]? = nil

    /// The element type of a dictionary: a tuple containing an individual
    /// key-value pair.
    static let booleanAttributes = ParsingStrings([
        "allowfullscreen", "async", "autofocus", "checked", "compact", "controls", "crossorigin", "declare", "default", "defer",
        "disabled", "formnovalidate", "hidden", "inert", "ismap", "itemscope", "multiple", "muted", "nohref",
        "noresize", "noshade", "novalidate", "nowrap", "open", "readonly", "required", "reversed", "seamless",
        "selected", "sortable", "truespeed", "typemustmatch"
    ])
    
    @usableFromInline
    var keySlice: ByteSlice
    @usableFromInline
    var valueSlice: ByteSlice
    @usableFromInline
    var valueSlices: [ByteSlice]? = nil
    @usableFromInline
    var valueSlicesCount: Int = 0
    @usableFromInline
    var keyBytes: [UInt8]? = nil
    @usableFromInline
    var valueBytes: [UInt8]? = nil
    @usableFromInline
    var lowerKeySliceCache: ByteSlice? = nil
    @usableFromInline
    var lowerValueSliceCache: ByteSlice? = nil
    @usableFromInline
    var lowerTrimmedValueSliceCache: ByteSlice? = nil
    
    public init(key: [UInt8], value: [UInt8]) throws {
        let trimmedKey = ByteSlice.fromArray(key).trim()
        try Validate.notEmpty(string: trimmedKey)
        self.keySlice = trimmedKey
        self.valueSlice = ByteSlice.fromArray(value)
    }

    public convenience init(keySlice: ArraySlice<UInt8>, valueSlice: ArraySlice<UInt8>) throws {
        let key = ByteSlice.fromArraySlice(keySlice).trim()
        let value = ByteSlice.fromArraySlice(valueSlice)
        try self.init(keySlice: key, valueSlice: value)
    }

    @usableFromInline
    init(keySlice: ByteSlice, valueSlice: ByteSlice) throws {
        let trimmedKey = keySlice.trim()
        try Validate.notEmpty(string: trimmedKey)
        self.keySlice = trimmedKey
        self.valueSlice = valueSlice
    }
    
    public convenience init(key: String, value: String) throws {
        try self.init(key: key.utf8Array, value: value.utf8Array)
    }
    
    /**
     Get the attribute key.
     - returns: the attribute key
     */
    @inline(__always)
    open func getKey() -> String {
        return String(decoding: getKeyUTF8(), as: UTF8.self)
    }
    
    @inline(__always)
    open func getKeyUTF8() -> [UInt8] {
        if let keyBytes {
            return keyBytes
        }
        let bytes = keySlice.toArray()
        keyBytes = bytes
        return bytes
    }
    
    /**
     Set the attribute key; case is preserved.
     - parameter key: the new key
     */
    @inline(__always)
    open func setKey(key: [UInt8]) throws {
        let trimmedKey = ByteSlice.fromArray(key).trim()
        try Validate.notEmpty(string: trimmedKey)
        setNormalizedKey(trimmedKey)
    }

    // The caller validates or normalizes the key before entering this storage-only path.
    // Normalization must not invoke an arbitrary subclass setter.
    internal func setNormalizedKey(_ key: ByteSlice) {
        guard keySlice != key else { return }
        keySlice = key
        keyBytes = nil
        lowerKeySliceCache = nil
        notifyMutationOwners(keyChanged: true)
    }

    @inline(__always)
    open func setKey(key: String) throws {
        try setKey(key: key.utf8Array)
    }
    
    /**
     Get the attribute value.
     - returns: the attribute value
     */
    @inline(__always)
    open func getValue() -> String {
        return String(decoding: getValueUTF8(), as: UTF8.self)
    }
    
    @inline(__always)
    open func getValueUTF8() -> [UInt8] {
        if let valueBytes {
            return valueBytes
        }
        if let slices = valueSlices {
            var out: [UInt8] = []
            out.reserveCapacity(valueSlicesCount)
            for slice in slices {
                out.append(contentsOf: slice)
            }
            valueSlices = nil
            valueSlicesCount = 0
            valueBytes = out
            valueSlice = ByteSlice.fromArray(out)
            return out
        }
        let bytes = valueSlice.toArray()
        valueBytes = bytes
        return bytes
    }
    
    /**
     Set the attribute value.
     - parameter value: the new attribute value
     */
    @discardableResult
    @inline(__always)
    open func setValue(value: [UInt8]) -> [UInt8] {
        let old = getValueUTF8()
        // An overridden getter can differ from the stored value. Only skip an
        // actual storage no-op, while preserving the public getter's return value.
        guard valueSliceMaterialized() != ByteSlice.fromArray(value) else { return old }
        valueSlice = ByteSlice.fromArray(value)
        valueSlices = nil
        valueSlicesCount = 0
        valueBytes = nil
        lowerValueSliceCache = nil
        lowerTrimmedValueSliceCache = nil
        notifyMutationOwners(keyChanged: false)
        return old
    }
    
    /**
     Get the HTML representation of this attribute; e.g. `href="index.html"`.
     - returns: HTML
     */
    @inline(__always)
    public func html() -> String {
        let accum = StringBuilder()
        html(accum: accum, out: (Document([])).outputSettings())
        return accum.toString()
    }
    
    @inline(__always)
    public func html(accum: StringBuilder, out: OutputSettings) {
        accum.append(keySlice)
        if (!shouldCollapseAttribute(out: out)) {
            accum.append(UTF8Arrays.attributeEqualsQuoteMark)
            Attribute.appendAttributeValue(accum, out, valueSliceMaterialized())
            accum.append(UTF8Arrays.quoteMark)
        }
    }
    
    /**
     Get the string representation of this attribute, implemented as ``html()``.
     - returns: string
     */
    @inline(__always)
    open func toString() -> String {
        return html()
    }
    
    /**
     Create a new Attribute from an unencoded key and a HTML attribute encoded value.
     - parameter unencodedKey: assumes the key is not encoded, as can be only run of simple `\w` chars.
     - parameter encodedValue: HTML attribute encoded value
     - returns: attribute
     */
    @inline(__always)
    public static func createFromEncoded(unencodedKey: [UInt8], encodedValue: [UInt8]) throws -> Attribute {
        let value = try Entities.unescape(string: encodedValue, strict: true)
        return try Attribute(key: unencodedKey, value: value)
    }
    
    @inline(__always)
    public func isDataAttribute() -> Bool {
        let key = keySlice
        let prefix = Attributes.dataPrefix
        if key.count <= prefix.count { return false }
        var i = 0
        while i < prefix.count {
            if key[i] != prefix[i] {
                return false
            }
            i &+= 1
        }
        return true
    }

    @usableFromInline
    @inline(__always)
    static func appendAttributeValue(_ accum: StringBuilder, _ out: OutputSettings, _ value: [UInt8]) {
        if value.isEmpty {
            return
        }
        let escapeMode = out.escapeMode()
        let encoder = out.encoder()
        let encoderIsAscii = encoder == .ascii
        var needsEscape = false
        value.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let len = buf.count
            var i = 0
            while i < len {
                let b = base[i]
                if encoderIsAscii && b >= Entities.asciiUpperLimitByte {
                    needsEscape = true
                    return
                }
                if b == TokeniserStateVars.ampersandByte || b == TokeniserStateVars.quoteByte {
                    needsEscape = true
                    return
                }
                if escapeMode == .xhtml && b == TokeniserStateVars.lessThanByte {
                    needsEscape = true
                    return
                }
                if b == StringUtil.utf8NBSPLead, i + 1 < len, base[i + 1] == StringUtil.utf8NBSPTrail {
                    needsEscape = true
                    return
                }
                i += 1
            }
        }
        if !needsEscape {
            accum.append(value)
            return
        }
        Entities.escape(accum, value, out, true, false, false)
    }

    @usableFromInline
    @inline(__always)
    static func appendAttributeValue(_ accum: StringBuilder, _ out: OutputSettings, _ value: ByteSlice) {
        if value.isEmpty {
            return
        }
        let escapeMode = out.escapeMode()
        let encoder = out.encoder()
        let encoderIsAscii = encoder == .ascii
        var needsEscape = false
        value.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            let len = buf.count
            var i = 0
            while i < len {
                let b = base[i]
                if encoderIsAscii && b >= Entities.asciiUpperLimitByte {
                    needsEscape = true
                    return
                }
                if b == TokeniserStateVars.ampersandByte || b == TokeniserStateVars.quoteByte {
                    needsEscape = true
                    return
                }
                if escapeMode == .xhtml && b == TokeniserStateVars.lessThanByte {
                    needsEscape = true
                    return
                }
                if b == StringUtil.utf8NBSPLead, i + 1 < len, base[i + 1] == StringUtil.utf8NBSPTrail {
                    needsEscape = true
                    return
                }
                i += 1
            }
        }
        if !needsEscape {
            accum.append(value)
            return
        }
        Entities.escape(accum, value, out, true, false, false)
    }

    
    /**
     Collapsible if it's a boolean attribute and value is empty or same as name
     
     - parameter out: Outputsettings
     - returns:  Returns whether collapsible or not
     */
    @inline(__always)
    public final func shouldCollapseAttribute(out: OutputSettings) -> Bool {
        return isValueEmpty()
        && out.syntax() == OutputSettings.Syntax.html
        && isBooleanAttribute()
    }
    
    @inline(__always)
    public func isBooleanAttribute() -> Bool {
        return Attribute.booleanAttributes.contains(lowerKeySlice())
    }

    @usableFromInline
    @inline(__always)
    func isValueEmpty() -> Bool {
        if let valueBytes {
            return valueBytes.isEmpty
        }
        if valueSlices != nil {
            return valueSlicesCount == 0
        }
        return valueSlice.isEmpty
    }

    @usableFromInline
    @inline(__always)
    func valueSliceMaterialized() -> ByteSlice {
        if valueSlices == nil {
            if !valueSlice.isEmpty {
                return valueSlice
            }
            if let valueBytes {
                let slice = ByteSlice.fromArray(valueBytes)
                valueSlice = slice
                return slice
            }
            return valueSlice
        }
        let slices = valueSlices ?? []
        var out: [UInt8] = []
        out.reserveCapacity(valueSlicesCount)
        for slice in slices {
            out.append(contentsOf: slice)
        }
        valueSlices = nil
        valueSlicesCount = 0
        valueBytes = out
        let slice = ByteSlice.fromArray(out)
        valueSlice = slice
        return slice
    }

    @usableFromInline
    @inline(__always)
    func appendValueSlice(_ slice: ByteSlice) {
        guard !slice.isEmpty else { return }
        defer { notifyMutationOwners(keyChanged: false) }
        valueBytes = nil
        lowerValueSliceCache = nil
        lowerTrimmedValueSliceCache = nil
        if valueSlices != nil {
            valueSlices!.append(slice)
            valueSlicesCount += slice.count
            return
        }
        if !valueSlice.isEmpty {
            valueSlices = [valueSlice, slice]
            valueSlicesCount = valueSlice.count + slice.count
            valueSlice = ByteSlice.empty
        } else {
            valueSlices = [slice]
            valueSlicesCount = slice.count
        }
    }

    @usableFromInline
    @inline(__always)
    func lowerKeySlice() -> ByteSlice {
        if let cached = lowerKeySliceCache {
            return cached
        }
        let lowered = keySlice.lowercased()
        lowerKeySliceCache = lowered
        return lowered
    }

    @usableFromInline
    @inline(__always)
    func lowerValueSlice() -> ByteSlice {
        if let cached = lowerValueSliceCache {
            return cached
        }
        let lowered = valueSliceMaterialized().lowercased()
        lowerValueSliceCache = lowered
        return lowered
    }

    @usableFromInline
    @inline(__always)
    func lowerTrimmedValueSlice() -> ByteSlice {
        if let cached = lowerTrimmedValueSliceCache {
            return cached
        }
        let lowered = valueSliceMaterialized().trim().lowercased()
        lowerTrimmedValueSliceCache = lowered
        return lowered
    }
    
    @inline(__always)
    public func hashCode() -> Int {
        var result = keySlice.hashValue
        // Hash mixing intentionally wraps at the machine word boundary.
        result = (31 &* result) &+ valueSliceMaterialized().hashValue
        return result
    }
    
    // Copy immutable byte storage without sharing the mutable Attribute object or observers.
    internal init(copying other: Attribute) {
        keySlice = other.keySlice
        valueSlice = other.valueSlice
        valueSlices = other.valueSlices
        valueSlicesCount = other.valueSlicesCount
    }

    @inline(__always)
    public func clone() -> Attribute {
        if type(of: self) == BooleanAttribute.self {
            return BooleanAttribute(copying: self)
        }
        if type(of: self) != Attribute.self,
           let projected = try? Attribute(key: getKeyUTF8(), value: getValueUTF8()) {
            // Preserve the existing clone contract for custom getter overrides.
            // Invalid projected keys fall back to the already-validated storage.
            return projected
        }
        return Attribute(copying: self)
    }

}

extension Attribute: Equatable {
    @inline(__always)
    static public func == (lhs: Attribute, rhs: Attribute) -> Bool {
        return lhs.keySlice == rhs.keySlice && lhs.valueSliceMaterialized() == rhs.valueSliceMaterialized()
    }
    
}


extension Attribute: CustomStringConvertible {
    @inline(__always)
    public var description: String {
        return "\(getKey())=\"\(getValue())\""
    }
}

extension Attribute: CustomDebugStringConvertible {
    private static let space = " "
    public var debugDescription: String {
        return "<\(String(describing: type(of: self))): \(Unmanaged.passUnretained(self).toOpaque()) \(self.description)>"
    }
}
