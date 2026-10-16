/*
 Hypnos - Remote Post Model

 One item in a slideshow: a picture or video from the app's own library,
 in the shape the slideshow engine queues and displays.
 */

import Foundation

struct RemotePost: Codable, Identifiable, Hashable {
    let _id: Int
    let file_ext: String
    let tags: [String]
    let rating: String?
    let image_width: Int?
    let image_height: Int?
    let fav_count: Int?
    let md5: String?
    let parent_id: Int?
    let score: Int?
    let ratio: Double?
    let path: String?
    let duration: Double?

    var id: Int { _id }

    private enum CodingKeys: String, CodingKey {
        case _id, file_ext, tags, rating, image_width, image_height
        case fav_count, md5, parent_id, score, ratio, path, duration
    }
}

