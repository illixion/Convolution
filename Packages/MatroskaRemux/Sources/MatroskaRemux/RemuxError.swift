/*
 MatroskaRemux - why a file can't be remuxed

 `declined` is the expected "no": a codec or feature this remuxer doesn't
 carry into MP4 (VP8, Vorbis, an encrypted track, a remote file without
 Cues). The caller keeps its existing fallback. `notMatroska` is the cheap
 "not ours" from the first bytes. `malformed` is a file that claims to be
 Matroska and isn't readable as one.

 Every message is code-defined (codec ids, element ids, counts), so it is
 safe to log publicly; none carries a file name or URL.
 */

import Foundation

public enum RemuxError: Error, Equatable, CustomStringConvertible {
    case notMatroska
    case declined(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .notMatroska: "not a Matroska file"
        case .declined(let reason): "declined: \(reason)"
        case .malformed(let detail): "malformed: \(detail)"
        }
    }
}
