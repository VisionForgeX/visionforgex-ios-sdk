import Foundation

/// The banner size ladder, the same as the Android SDK's (1.0.2 there): Google's large anchored adaptive size, the
/// standard anchored adaptive one and 320x50 in one request; on "no fill" (or a unit that takes none of those
/// sizes) the standard size alone, then 320x50 alone, all in the same load. The size that filled is kept for the
/// banner's refreshes. Pure, so it is tested without Google.
public enum BannerLadder {
    public static let last = 2
    /// 0: large, standard and 320x50 together; 1: standard alone; 2: 320x50 alone.
    public static func tier<T>(_ t: Int, large: T, standard: T, small: T) -> [T] {
        switch t {
        case 0: return [large, standard, small]
        case 1: return [standard]
        default: return [small]
        }
    }
    /// The next tier after a failure, or nil to report it: only "no fill" (1 on iOS) and "invalid request" (0 on iOS)
    /// step down; a network error or a timeout is not about the size.
    public static func next(_ t: Int, code: Int) -> Int? { (code == 1 || code == 0) && t < last ? t + 1 : nil }
}
