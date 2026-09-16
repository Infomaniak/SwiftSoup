// Mutable references can be shared through put/addAll and retained after removal.
// Observe weakly, and validate membership by identity before every notification.
// This avoids adding callbacks or an owner allocation to deferred parser attributes.
internal extension Attribute {
    func observeMutations(in owner: Attributes) {
        // Callers have just obtained this attribute from, or inserted it into,
        // owner. Re-reading a singly owned list must not rescan the whole list
        // once per attribute. Mutation notifications still validate membership.
        if let owners = mutationOwners, owners.count == 1, owners[0].value === owner { return }
        mutationOwners?.removeAll { reference in
            guard let existing = reference.value else { return true }
            // The caller is registering an attribute already in this owner. Avoid
            // rescanning its array for every item returned by asList / iteration.
            return existing !== owner && !existing.attributes.contains { $0 === self }
        }
        if mutationOwners?.contains(where: { $0.value === owner }) == true { return }
        if mutationOwners == nil { mutationOwners = [] }
        mutationOwners?.append(Weak(owner))
    }

    func notifyMutationOwners(keyChanged: Bool) {
        mutationOwners?.removeAll { reference in
            guard let owner = reference.value else { return true }
            return !owner.attributes.contains { $0 === self }
        }
        guard let owners = mutationOwners else { return }
        for reference in owners {
            reference.value?.attributeDidMutate(keyChanged: keyChanged)
        }
    }
}

internal extension Attributes {
    func observeAttributeMutations() {
        for attribute in attributes { attribute.observeMutations(in: self) }
    }

    func attributeDidMutate(keyChanged: Bool) {
        if keyChanged {
            invalidateKeyIndex()
            invalidateLowercasedKeysCache()
            hasUppercaseKeys = attributes.contains { Self.containsAsciiUppercase($0.keySlice) }
        }
        notifyMutationOwners()
    }

    @usableFromInline
    func addOwner(_ node: Node) {
        if ownerNode === node { return }
        additionalOwnerNodes?.removeAll { reference in
            guard let owner = reference.value else { return true }
            return owner.attributes !== self
        }
        if let first = ownerNode, first.attributes === self {
            if additionalOwnerNodes?.contains(where: { $0.value === node }) == true { return }
            if additionalOwnerNodes == nil { additionalOwnerNodes = [] }
            additionalOwnerNodes?.append(Weak(node))
        } else {
            // Remove a promoted owner from the secondary list to notify it once.
            additionalOwnerNodes?.removeAll { $0.value === node }
            ownerNode = node
        }
    }

    @usableFromInline
    func notifyMutationOwners() {
        // Shared collections may outlive their nodes. Release expired observer
        // boxes and restore the single-owner fast path when the primary expires.
        additionalOwnerNodes?.removeAll { reference in
            guard let node = reference.value else { return true }
            return node.attributes !== self
        }
        if ownerNode?.attributes !== self {
            ownerNode = nil
            if let promoted = additionalOwnerNodes?.first?.value {
                ownerNode = promoted
                additionalOwnerNodes?.removeFirst()
            }
        }
        if additionalOwnerNodes?.isEmpty == true { additionalOwnerNodes = nil }
        func notify(_ node: Node) {
            guard node.attributes === self else { return }
            if let element = node as? Element {
                element.markAttributeQueryIndexesDirty()
            } else {
                node.bumpTextMutationVersion()
            }
            node.markSourceDirty()
        }
        if let ownerNode { notify(ownerNode) }
        if let additionalOwnerNodes {
            for reference in additionalOwnerNodes {
                if let owner = reference.value { notify(owner) }
            }
        }
    }

    // Query indexes and getters must agree when keys differ only in case or a
    // direct rename introduces duplicates. Use existing key maps for large lists;
    // the fallback compares at most three preceding attributes, without a set.
    func forEachEffectiveAttribute(_ visit: (Attribute, ByteSlice) -> Void) {
        ensureMaterialized()
        if hasUppercaseKeys { ensureLowercasedKeyIndex() } else { ensureKeyIndex() }
        let index = hasUppercaseKeys ? lowercasedKeyIndex : keyIndex
        for (offset, attribute) in attributes.enumerated() {
            let key = hasUppercaseKeys ? attribute.lowerKeySlice() : attribute.keySlice
            if let index {
                guard index[key] == offset else { continue }
            } else if attributes[..<offset].contains(where: {
                Self.equalsIgnoreCase($0.keySlice, key)
            }) {
                continue
            }
            visit(attribute, key)
        }
    }
}
