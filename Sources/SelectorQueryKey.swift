// CSS matches code points, not Swift's canonically equivalent String values.
// Keep the original String storage; equality compares UTF-8 without allocating a
// second copy. Canonically equivalent strings may share a hash, which is safe:
// the byte-exact equality check still keeps their cache entries distinct.
@usableFromInline
struct SelectorQueryKey: Hashable, Sendable {
    private let query: String

    @usableFromInline
    init(_ query: String) {
        self.query = query
    }

    @usableFromInline
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.query.utf8.elementsEqual(rhs.query.utf8)
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        hasher.combine(query)
    }
}
