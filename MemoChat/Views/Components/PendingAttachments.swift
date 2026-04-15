import UIKit

struct PendingImage: Identifiable {
    let id = UUID()
    let image: UIImage
    var uploadedURL: String? = nil
    var isUploading: Bool = true
}

struct PendingFile: Identifiable {
    let id = UUID()
    let filename: String
    var uploadedURL: String? = nil
    var isUploading: Bool = true
}
