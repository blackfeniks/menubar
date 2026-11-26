import AppKit
import SwiftUI

struct ScrollSteps {
	var pitch: CGFloat = 28
	private var carry: CGFloat = 0

	mutating func steps(_ event: NSEvent) -> Int {
		if event.phase == .began || event.phase == .mayBegin { carry = 0 }
		let dy = event.scrollingDeltaY
		guard dy != 0 else { return 0 }
		if !event.hasPreciseScrollingDeltas {
			carry = 0
			return dy > 0 ? -1 : 1
		}
		carry += dy
		let n = Int((carry / pitch).rounded(.towardZero))
		carry -= CGFloat(n) * pitch
		return -n
	}
}
