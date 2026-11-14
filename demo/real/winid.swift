import CoreGraphics
import Foundation
// Prints the window id of every on-screen Alacritty window, one per line.
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list {
  guard let owner = w[kCGWindowOwnerName as String] as? String, owner.lowercased() == "alacritty" else { continue }
  print(w[kCGWindowNumber as String]!)
}
