import Foundation

extension Int {
    /// "1 photo", "123,456 photos": the count grouped for the user's locale, and the noun agreeing with it
    /// (Foundation's automatic grammar agreement). `noun` is the singular.
    func counted(_ noun: String) -> String {
        String(AttributedString(localized: "^[\(self) \(noun)](inflect: true)").characters)
    }
}
