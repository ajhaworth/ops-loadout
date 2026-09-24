// Centers an app's windows at full height, inside the same 8 px gaps aerospace.toml uses. AeroSpace tiles a window by
// asking for the whole workspace, and one with a max width (Digest, Loadout) stops short against the left edge, so
// aerospace.toml floats those and runs this instead; a width narrows an app that has no max width of its own (Messages).
// Usage: osascript -l JavaScript center.js <bundle-id> [width] [title]
ObjC.import('AppKit')

function run([bid, ...rest]) {
    const gap = 8
    const vf = $.NSScreen.mainScreen.visibleFrame
    let width = vf.size.width - 2 * gap, title
    for (const a of rest) /^\d+$/.test(a) ? width = Math.min(width, +a) : title = a
    // NSScreen is bottom-left origin, System Events top-left, hence the flip against the primary screen's height.
    const top = $.NSScreen.screens.objectAtIndex(0).frame.size.height - (vf.origin.y + vf.size.height) + gap
    const app = Application('System Events').processes.whose({ bundleIdentifier: bid })[0]
    for (const w of app.windows()) {
        if (title && w.name() !== title) continue
        w.size = [width, vf.size.height - 2 * gap]   // macOS clamps this to the window's max width
        w.position = [vf.origin.x + (vf.size.width - w.size()[0]) / 2, top]
    }
}
