import CoreGraphics
import Testing
@testable import KerfKit

struct IslandGeometryTests {
    let notch = IslandGeometry(style: .notch(CGSize(width: 185, height: 32)))
    let floating = IslandGeometry(style: .floating)

    @Test func idleHidesBehindTheNotch() {
        #expect(notch.idle == CGSize(width: 183, height: 31))
        #expect(floating.idle.height == 0)
    }

    @Test func compactAddsTwoWings() {
        #expect(notch.compact() == CGSize(width: 265, height: 32))
        #expect(notch.compact(wings: 60).width == 305)
        #expect(floating.compact().height == IslandGeometry.floatingCompactHeight)
    }

    @Test func cornersGrowWithHeight() {
        #expect(notch.cornerRadius(height: 32, openHeight: 186) == 8)
        #expect(notch.cornerRadius(height: 186, openHeight: 186) == 24)
        #expect(notch.cornerRadius(height: 109, openHeight: 186) == 16)
        #expect(floating.cornerRadius(height: 26, openHeight: 186) == 13)
    }

    @Test func earsOnlyOnceWiderThanTheNotch() {
        #expect(notch.ear(width: 183) == 0)
        #expect(notch.ear(width: 189) == 2)
        #expect(notch.ear(width: 265) == 6)
        #expect(floating.ear(width: 400) == 0)
    }

    @Test func contentOnOneSideLeavesTheOtherBehindTheNotch() {
        // Rings on the right only: the left edge stays a point inside the notch.
        let right = notch.compact(leading: 0, trailing: 80)
        #expect(right.size == CGSize(width: 264, height: 32))
        #expect(right.shift == 40.5)
        let left = notch.compact(leading: 80, trailing: 0)
        #expect(left.size.width == 264)
        #expect(left.shift == -40.5)
        // With wings on both sides as well.
        let both = notch.compact(leading: 40, trailing: 120)
        #expect(both.size.width == 345)
        #expect(both.shift == 40)
        // The same as two wings.
        #expect(notch.compact(leading: 40, trailing: 40).size == notch.compact())
        #expect(notch.compact(leading: 40, trailing: 40).shift == 0)
        #expect(floating.compact(leading: 0, trailing: 80).size.width == 200)
    }

    @Test func earsOnlyOnTheSideThatReachesOut() {
        let right = notch.compact(leading: 0, trailing: 80)
        let ears = notch.ears(width: right.size.width, shift: right.shift)
        #expect(ears.leading == 0)
        #expect(ears.trailing == 6)
        #expect(notch.ears(width: 265, shift: 0).leading == 6)
        #expect(notch.ears(width: 265, shift: 0).trailing == 6)
        // Halfway there: the flare grows in with the side.
        #expect(notch.ears(width: 191, shift: 2).trailing == 5)
        #expect(notch.ears(width: 191, shift: 2).leading == 1)
        #expect(floating.ears(width: 400, shift: 30).trailing == 0)
    }
}

struct MenuBarRoomTests {
    // A 14" MacBook Pro: the notch from x 663 to 848.
    let notch = (min: CGFloat(663), max: CGFloat(848))

    @Test func fewMenusLeaveRoom() {
        let finder = [CGRect(x: 10, y: 0, width: 40, height: 24), CGRect(x: 60, y: 0, width: 50, height: 24),
                      CGRect(x: 1300, y: 0, width: 30, height: 24)]
        let room = MenuBarRoom.free(notchMinX: notch.min, notchMaxX: notch.max, items: finder)
        #expect(room == 452)
        #expect(MenuBarRoom.fits(wings: 40, in: room))
    }

    struct WindowVisibilityTests {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

        @Test func maximizedChromeDoesNotHideTheIsland() {
            let chrome = CGRect(x: 0, y: 33, width: 1512, height: 949)
            #expect(!WindowVisibility.hidesIsland(window: chrome, display: display, isFullScreen: nil))
            #expect(!WindowVisibility.hidesIsland(window: chrome, display: display, isFullScreen: false))
        }

        @Test func trueFullScreenBelowTheNotchStillHides() {
            let fullScreen = CGRect(x: 0, y: 32, width: 1512, height: 950)
            #expect(WindowVisibility.hidesIsland(window: fullScreen, display: display, isFullScreen: true))
            // Without Accessibility: a full-screen space has no Dock.
            #expect(WindowVisibility.hidesIsland(window: fullScreen, display: display, notch: 32, isFullScreen: nil, dockShown: false))
            #expect(!WindowVisibility.hidesIsland(window: fullScreen, display: display, notch: 32, isFullScreen: nil, dockShown: true))
        }

        @Test func fallbackRequiresTheWholeDisplay() {
            #expect(WindowVisibility.hidesIsland(window: display, display: display, isFullScreen: nil))
            #expect(!WindowVisibility.hidesIsland(window: display, display: display, isFullScreen: false))
            let normal = CGRect(x: 60, y: 100, width: 1000, height: 700)
            #expect(!WindowVisibility.hidesIsland(window: normal, display: display, isFullScreen: nil))
        }

        @Test func otherDisplaysAreIndependent() {
            let external = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
            #expect(!WindowVisibility.hidesIsland(window: external, display: display, isFullScreen: true))
            #expect(WindowVisibility.hidesIsland(window: external, display: external, isFullScreen: nil))
            let maximized = CGRect(x: -1920, y: -1055, width: 1920, height: 1055)
            #expect(!WindowVisibility.hidesIsland(window: maximized, display: external, isFullScreen: nil))
        }
    }

    @Test func manyMenusRunUpToTheNotch() {
        // DaVinci Resolve: "Fusion" ends 4 pt before the notch, "Color" starts 6 pt after it.
        let resolve = [CGRect(x: 580, y: 0, width: 79, height: 24), CGRect(x: 854, y: 0, width: 60, height: 24)]
        let room = MenuBarRoom.free(notchMinX: notch.min, notchMaxX: notch.max, items: resolve)
        #expect(room == 4)
        #expect(!MenuBarRoom.fits(wings: 40, in: room))
    }

    @Test func eachSideHasItsOwnRoom() {
        // Safari's menus end 95 pt before the notch; the status items start 320 pt after it.
        let safari = [CGRect(x: 520, y: 0, width: 48, height: 24), CGRect(x: 1168, y: 0, width: 30, height: 24)]
        let room = MenuBarRoom.sides(notchMinX: notch.min, notchMaxX: notch.max, items: safari)
        #expect(room == MenuBarRoom.Sides(left: 95, right: 320))
        #expect(MenuBarRoom.fits(wings: 80, in: room.left))
        #expect(!MenuBarRoom.fits(wings: 120, in: room.left))
        #expect(MenuBarRoom.fits(wings: 120, in: room.right))
        #expect(MenuBarRoom.sides(notchMinX: notch.min, notchMaxX: notch.max, items: []) == .open)
    }

    @Test func itemsBehindTheNotchDontCount() {
        let hidden = [CGRect(x: 700, y: 0, width: 30, height: 24), CGRect(x: 1000, y: 0, width: 30, height: 24)]
        #expect(MenuBarRoom.free(notchMinX: notch.min, notchMaxX: notch.max, items: hidden) == 152)
        #expect(MenuBarRoom.free(notchMinX: notch.min, notchMaxX: notch.max, items: []) == .infinity)
    }
}
