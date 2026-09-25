import Foundation

extension Tag {
    /// Splits a file keyword into a tag's category and name, the inverse of `fullName`:
    /// `"category:name"` → `("category", "name")`, and a keyword without a category part → `("", keyword)`.
    ///
    /// The first `:` separates, so a name may contain colons (`"a::b"` → `("a", ":b")`). When the part before
    /// or after that `:` is empty (`":a"`, `"a:"`, `":a:b"`), the whole keyword is an uncategorised name.
    /// Either way, `fullName` of the result is the keyword again.
    static func parse(keyword: String) -> (category: String, name: String) {
        if let colon = keyword.firstIndex(of: ":") {
            let category = keyword[..<colon]
            let name = keyword[keyword.index(after: colon)...]
            if !category.isEmpty && !name.isEmpty {
                return (String(category), String(name))
            }
        }
        return ("", keyword)
    }
}
