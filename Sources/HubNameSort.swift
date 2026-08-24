import Foundation

enum HubNameSort {
    private static let locale = Locale(identifier: "zh@collation=pinyin")

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.caseInsensitive, .numeric], locale: locale)
    }

    static func sorted<T>(_ items: [T], key: (T) -> String) -> [T] {
        items.sorted { compare(key($0), key($1)) == .orderedAscending }
    }
}

extension RStudioInstance {
    var sortName: String {
        projectName ?? "RStudio"
    }

    static func sortedByName(_ instances: [RStudioInstance]) -> [RStudioInstance] {
        instances.sorted { lhs, rhs in
            let nameOrder = HubNameSort.compare(lhs.sortName, rhs.sortName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.pid < rhs.pid
        }
    }
}
