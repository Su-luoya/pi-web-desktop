/// Trims a string and treats the empty result as absent.

import Foundation

// MARK: - 小工具

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
