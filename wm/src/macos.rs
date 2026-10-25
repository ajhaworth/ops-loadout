// macOS: the Accessibility API moves windows, AXObservers report new and closed windows per listed app, and
// NSWorkspace reports launches, quits and activations. Activating an app lays its windows out again, so a window
// dragged aside snaps back the next time you switch to it.
#![allow(unused_unsafe)]

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, c_void};
use std::ptr::{self, NonNull};
use std::time::{Duration, Instant};

use block2::RcBlock;
use objc2::{sel, MainThreadMarker};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSApplicationDidChangeScreenParametersNotification, NSImage, NSMenu,
    NSMenuItem, NSScreen, NSStatusBar, NSVariableStatusItemLength,
    NSWorkspace, NSWorkspaceDidActivateApplicationNotification, NSWorkspaceDidLaunchApplicationNotification,
    NSWorkspaceDidTerminateApplicationNotification,
};
use objc2_foundation::{NSDistributedNotificationCenter, NSNotification, NSNotificationCenter, NSString};

use crate::{app_listed, debug, gapped, pair_rects, plan, rule_for, screen_of, Rect, Rules, Screen, Win};

type CFTypeRef = *const c_void;
type AXObserverCallback = extern "C" fn(CFTypeRef, CFTypeRef, CFTypeRef, *mut c_void);

#[repr(C)]
#[derive(Default)]
struct CGPoint {
    x: f64,
    y: f64,
}

#[repr(C)]
#[derive(Default)]
struct CGSize {
    w: f64,
    h: f64,
}

const AX_VALUE_CGPOINT: u32 = 1;
const AX_VALUE_CGSIZE: u32 = 2;
const UTF8: u32 = 0x0800_0100;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    static kAXTrustedCheckOptionPrompt: CFTypeRef;
    fn AXIsProcessTrustedWithOptions(options: CFTypeRef) -> bool;
    fn AXUIElementCreateApplication(pid: i32) -> CFTypeRef;
    fn AXUIElementCopyAttributeValue(element: CFTypeRef, attr: CFTypeRef, value: *mut CFTypeRef) -> i32;
    fn AXUIElementSetAttributeValue(element: CFTypeRef, attr: CFTypeRef, value: CFTypeRef) -> i32;
    fn AXUIElementPerformAction(element: CFTypeRef, action: CFTypeRef) -> i32;
    fn AXValueCreate(kind: u32, value: *const c_void) -> CFTypeRef;
    fn AXValueGetValue(value: CFTypeRef, kind: u32, out: *mut c_void) -> bool;
    fn AXObserverCreate(pid: i32, callback: AXObserverCallback, observer: *mut CFTypeRef) -> i32;
    fn AXObserverAddNotification(observer: CFTypeRef, element: CFTypeRef, name: CFTypeRef, refcon: *mut c_void) -> i32;
    fn AXObserverGetRunLoopSource(observer: CFTypeRef) -> CFTypeRef;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    static kCFBooleanTrue: CFTypeRef;
    static kCFRunLoopDefaultMode: CFTypeRef;
    static kCFTypeDictionaryKeyCallBacks: c_void;
    static kCFTypeDictionaryValueCallBacks: c_void;
    fn CFRetain(cf: CFTypeRef) -> CFTypeRef;
    fn CFRelease(cf: CFTypeRef);
    fn CFEqual(a: CFTypeRef, b: CFTypeRef) -> bool;
    fn CFGetTypeID(cf: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFBooleanGetTypeID() -> usize;
    fn CFBooleanGetValue(b: CFTypeRef) -> bool;
    fn CFArrayGetCount(a: CFTypeRef) -> isize;
    fn CFArrayGetValueAtIndex(a: CFTypeRef, i: isize) -> CFTypeRef;
    fn CFStringCreateWithBytes(alloc: CFTypeRef, bytes: *const u8, len: isize, enc: u32, bom: bool) -> CFTypeRef;
    fn CFStringGetCString(s: CFTypeRef, buf: *mut c_char, size: isize, enc: u32) -> bool;
    fn CFDictionaryCreate(
        alloc: CFTypeRef,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        n: isize,
        key_cb: *const c_void,
        value_cb: *const c_void,
    ) -> CFTypeRef;
    fn CFRunLoopGetMain() -> CFTypeRef;
    fn CFRunLoopAddSource(rl: CFTypeRef, source: CFTypeRef, mode: CFTypeRef);
    fn CFRunLoopRemoveSource(rl: CFTypeRef, source: CFTypeRef, mode: CFTypeRef);
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventSourceButtonState(state: i32, button: u32) -> bool;
}

extern "C" {
    static _dispatch_main_q: c_void;
    fn dispatch_time(when: u64, delta: i64) -> u64;
    fn dispatch_after_f(when: u64, queue: *const c_void, ctx: *mut c_void, work: extern "C" fn(*mut c_void));
}

/// An owned CF object, released on drop; equality is CFEqual, which is how AX elements compare.
struct Ref(CFTypeRef);

impl Drop for Ref {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

impl Clone for Ref {
    fn clone(&self) -> Self {
        Ref(unsafe { CFRetain(self.0) })
    }
}

impl PartialEq for Ref {
    fn eq(&self, other: &Self) -> bool {
        unsafe { CFEqual(self.0, other.0) }
    }
}

fn cfstr(s: &str) -> Ref {
    Ref(unsafe { CFStringCreateWithBytes(ptr::null(), s.as_ptr(), s.len() as isize, UTF8, false) })
}

fn attr(element: CFTypeRef, name: &str) -> Option<Ref> {
    let mut out = ptr::null();
    let err = unsafe { AXUIElementCopyAttributeValue(element, cfstr(name).0, &mut out) };
    (err == 0 && !out.is_null()).then(|| Ref(out))
}

fn string_attr(element: CFTypeRef, name: &str) -> String {
    let Some(s) = attr(element, name) else { return String::new() };
    let mut buf = vec![0 as c_char; 4096];
    unsafe {
        if CFGetTypeID(s.0) != CFStringGetTypeID() || !CFStringGetCString(s.0, buf.as_mut_ptr(), 4096, UTF8) {
            return String::new();
        }
        std::ffi::CStr::from_ptr(buf.as_ptr()).to_string_lossy().into_owned()
    }
}

fn bool_attr(element: CFTypeRef, name: &str) -> bool {
    attr(element, name).is_some_and(|b| unsafe { CFGetTypeID(b.0) == CFBooleanGetTypeID() && CFBooleanGetValue(b.0) })
}

fn frame(element: CFTypeRef) -> Option<Rect> {
    let (mut p, mut s) = (CGPoint::default(), CGSize::default());
    unsafe {
        let ok = AXValueGetValue(attr(element, "AXPosition")?.0, AX_VALUE_CGPOINT, &mut p as *mut _ as *mut c_void)
            && AXValueGetValue(attr(element, "AXSize")?.0, AX_VALUE_CGSIZE, &mut s as *mut _ as *mut c_void);
        ok.then_some(Rect { x: p.x, y: p.y, w: s.w, h: s.h })
    }
}

/// Size, then position, then size again: an app that clamps a size that would not fit at the old position gets the
/// full size once it has moved.
fn set_frame(element: CFTypeRef, r: Rect) {
    let p = CGPoint { x: r.x, y: r.y };
    let s = CGSize { w: r.w, h: r.h };
    unsafe {
        let size = Ref(AXValueCreate(AX_VALUE_CGSIZE, &s as *const _ as *const c_void));
        let pos = Ref(AXValueCreate(AX_VALUE_CGPOINT, &p as *const _ as *const c_void));
        let (size_attr, pos_attr) = (cfstr("AXSize"), cfstr("AXPosition"));
        AXUIElementSetAttributeValue(element, size_attr.0, size.0);
        AXUIElementSetAttributeValue(element, pos_attr.0, pos.0);
        AXUIElementSetAttributeValue(element, size_attr.0, size.0);
    }
}

/// A watched app: its AX element, its observer, and the names rules match against. Every regular app is watched,
/// listed or not, so a window snapped flush by Swish gets the padding too.
struct App {
    element: Ref,
    observer: Ref,
    names: [String; 2],
    listed: bool,
}

impl Drop for App {
    fn drop(&mut self) {
        unsafe {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(self.observer.0), kCFRunLoopDefaultMode)
        }
    }
}

/// Two apps' main windows side by side, from `loadout-wm pair` (Blender's Claude Code button: Ghostty left, Blender
/// right). Their rules step aside for those two windows until one closes or its app quits.
struct Pair {
    pids: [i32; 2],
    fraction: f64,
    /// Each side's window once it has been placed; switching to one app raises the other's.
    windows: [Option<Ref>; 2],
}

/// The distributed notification `loadout-wm pair` posts to the running instance.
const PAIR: &str = "dev.alx.loadout-wm.pair";

#[derive(Default)]
struct State {
    pair: Option<Pair>,
    rules: Rules,
    apps: HashMap<i32, App>,
    first: HashMap<usize, Ref>,
    /// When each app's windows were last moved by us, so the move notifications that causes are not taken for a drag.
    placed: HashMap<i32, Instant>,
    /// Apps with a drag being waited out (so a drag's stream of move notifications schedules one check), and the
    /// window being dragged.
    dragging: HashMap<i32, Ref>,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::default();
}

extern "C" fn on_ax(_observer: CFTypeRef, element: CFTypeRef, name: CFTypeRef, pid: *mut c_void) {
    let pid = pid as isize as i32;
    let moved = [cfstr("AXWindowMoved"), cfstr("AXWindowResized")].iter().any(|n| unsafe { CFEqual(name, n.0) });
    if !moved {
        return soon(pid);
    }
    // A move or resize we did not cause (an app clamping our size also lands inside this window) is the user
    // dragging or Swish snapping: once the mouse is up, a listed window snaps back and another gets the padding.
    let start = STATE.with_borrow_mut(|st| {
        let ours = st.placed.get(&pid).is_some_and(|t| t.elapsed() < Duration::from_millis(500));
        if ours || st.dragging.contains_key(&pid) {
            return false;
        }
        st.dragging.insert(pid, Ref(unsafe { CFRetain(element) }));
        true
    });
    if start {
        after(Duration::from_millis(100), -pid);
    }
}

fn mouse_down() -> bool {
    // kCGEventSourceStateCombinedSessionState, left button.
    unsafe { CGEventSourceButtonState(0, 0) }
}

fn watch(pid: i32, names: [String; 2], listed: bool) -> Option<App> {
    let element = Ref(unsafe { AXUIElementCreateApplication(pid) });
    let mut observer = ptr::null();
    if unsafe { AXObserverCreate(pid, on_ax, &mut observer) } != 0 {
        return None;
    }
    let observer = Ref(observer);
    // A just-launched app can refuse this for a moment; returning None retries on the next sync.
    let err = unsafe {
        AXObserverAddNotification(observer.0, element.0, cfstr("AXWindowCreated").0, pid as isize as *mut c_void)
    };
    if err != 0 {
        debug(|| format!("cannot watch {} yet (AX error {err})", names[0]));
        return None;
    }
    unsafe {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer.0), kCFRunLoopDefaultMode);
    }
    Some(App { element, observer, names, listed })
}

/// Rereads the rules and starts watching regular apps not yet watched. Returns the pids to lay out: new apps, or
/// every app when the rules changed.
fn sync(st: &mut State) -> Vec<i32> {
    if st.rules.reload() {
        st.apps.clear();
        st.first.clear();
    }
    let mut alive = HashSet::new();
    let mut fresh = Vec::new();
    for app in unsafe { NSWorkspace::sharedWorkspace().runningApplications() }.iter() {
        let pid = unsafe { app.processIdentifier() };
        alive.insert(pid);
        if st.apps.contains_key(&pid) || unsafe { app.activationPolicy() } != NSApplicationActivationPolicy::Regular {
            continue;
        }
        let id = unsafe { app.bundleIdentifier() }.map(|s| s.to_string()).unwrap_or_default();
        let name = unsafe { app.localizedName() }.map(|s| s.to_string()).unwrap_or_default();
        let listed = app_listed(&st.rules.list, &[&id, &name]);
        if let Some(watched) = watch(pid, [id, name], listed) {
            st.apps.insert(pid, watched);
            fresh.push(pid);
        }
    }
    st.apps.retain(|pid, _| alive.contains(pid));
    // A paired app quit: unpair, and its partner goes back to its rule.
    if let Some(pair) = st.pair.take_if(|p| p.pids.iter().any(|pid| !alive.contains(pid))) {
        fresh.extend(pair.pids.iter().filter(|pid| alive.contains(pid)));
    }
    fresh
}

fn screens() -> Vec<Screen> {
    let Some(mtm) = MainThreadMarker::new() else { return Vec::new() };
    let all = NSScreen::screens(mtm);
    // Cocoa's origin is the primary screen's bottom-left, y up; AX's is its top-left, y down.
    let Some(primary) = all.firstObject() else { return Vec::new() };
    let top = primary.frame().size.height;
    all.iter()
        .map(|s| {
            let v = s.visibleFrame();
            Screen {
                area: Rect { x: v.origin.x, y: top - v.origin.y - v.size.height, w: v.size.width, h: v.size.height },
                scale: 1.0,
            }
        })
        .collect()
}

/// Places a listed app's windows. With `dropped` (the window whose move just ended), a split puts it in the column
/// it was dropped in, and an unlisted window lying flush on screen fractions gets the padding.
fn layout(pid: i32, dropped: Option<Ref>) {
    let snapped = dropped.is_some();
    STATE.with_borrow_mut(|st| {
        let Some(app) = st.apps.get(&pid) else { return };
        let names = [app.names[0].as_str(), app.names[1].as_str()];
        let screens = screens();
        let mut wins = Vec::new();
        let mut moves = Vec::new();
        let mut first_main = None;
        if let Some(list) = attr(app.element.0, "AXWindows") {
            for i in 0..unsafe { CFArrayGetCount(list.0) } {
                let w = Ref(unsafe { CFRetain(CFArrayGetValueAtIndex(list.0, i)) });
                // Closing it lays the app out again (split rebalances, first hands over); moving it snaps it back
                // or pads it. Already registered is an error AX returns and we ignore.
                for n in ["AXUIElementDestroyed", "AXWindowMoved", "AXWindowResized"] {
                    unsafe { AXObserverAddNotification(app.observer.0, w.0, cfstr(n).0, pid as isize as *mut c_void) };
                }
                let Some(frame) = frame(w.0) else { continue };
                let title = string_attr(w.0, "AXTitle");
                // Dialogs, sheets, panels and picture-in-picture have other subroles, so they float. Some main
                // windows call themselves dialogs (Mail's viewer is AXDialog); those still have a full-screen button,
                // which real dialogs (System Settings) do not.
                let subrole = string_attr(w.0, "AXSubrole");
                let main = subrole == "AXStandardWindow"
                    || (subrole == "AXDialog" && attr(w.0, "AXFullScreenButton").is_some());
                let main = main && !bool_attr(w.0, "AXMinimized") && !bool_attr(w.0, "AXFullScreen");
                if main && first_main.is_none() {
                    first_main = Some((w.clone(), frame));
                }
                let rule = if main { rule_for(&st.rules.list, &names, &title) } else { None };
                debug(|| format!("{} {subrole} {title:?} {frame:?} rule {rule:?}", names[0]));
                match rule {
                    Some(rule) => wins.push(Win { id: w, rule, frame }),
                    None if snapped && !screens.is_empty() => {
                        let pad = st.rules.padding();
                        if let Some(r) = gapped(frame, screens[screen_of(frame, &screens)].area, pad) {
                            moves.push((w, r));
                        }
                    }
                    None => {}
                }
            }
        }
        let mut unpair = None;
        if let Some(pair) = st.pair.as_mut().filter(|_| !screens.is_empty()) {
            if let Some(side) = pair.pids.iter().position(|&p| p == pid) {
                // The app's ruled main window if it has one (Blender's, not its Preferences), else its first.
                match wins.first().map(|w| (w.id.clone(), w.frame)).or(first_main) {
                    Some((w, frame)) => {
                        wins.retain(|x| x.id != w);
                        let s = &screens[screen_of(frame, &screens)];
                        moves.push((w.clone(), pair_rects(s.area, st.rules.padding() * s.scale, pair.fraction)[side]));
                        pair.windows[side] = Some(w);
                    }
                    // Its window has closed: the partner goes back to its rule. (None yet just means not open yet.)
                    None if pair.windows[side].is_some() => unpair = Some(pair.pids[1 - side]),
                    None => {}
                }
            }
        }
        if let Some(partner) = unpair {
            st.pair = None;
            after(Duration::from_millis(1), partner);
        }
        if app.listed {
            moves.extend(plan(&st.rules.list, &wins, &screens, &mut st.first, dropped.as_ref()));
        }
        for (w, r) in moves {
            if frame(w.0) != Some(r) {
                debug(|| format!("{} -> {r:?}", names[0]));
                st.placed.insert(pid, Instant::now());
                set_frame(w.0, r);
            }
        }
    });
}

extern "C" fn later(pid: *mut c_void) {
    match pid as isize as i32 {
        0 => refresh(),
        // A drag: check again until the mouse is up, then snap back.
        drag if drag < 0 && mouse_down() => after(Duration::from_millis(100), drag),
        drag if drag < 0 => {
            let dropped = STATE.with_borrow_mut(|st| st.dragging.remove(&-drag));
            layout(-drag, dropped);
        }
        pid => layout(pid, None),
    }
}

fn after(delay: Duration, pid: i32) {
    unsafe {
        let when = dispatch_time(0, delay.as_nanos() as i64);
        dispatch_after_f(when, &_dispatch_main_q, pid as isize as *mut c_void, later);
    }
}

/// Lays an app out now and again shortly after: a new window often moves itself once more right after it appears.
fn soon(pid: i32) {
    layout(pid, None);
    after(Duration::from_millis(400), pid);
}

fn refresh() {
    for pid in STATE.with_borrow_mut(sync) {
        soon(pid);
    }
}

pub fn run() {
    let mtm = MainThreadMarker::new().expect("loadout-wm must start on the main thread");
    unsafe {
        let key = kAXTrustedCheckOptionPrompt;
        let value = kCFBooleanTrue;
        let options = CFDictionaryCreate(
            ptr::null(),
            &key,
            &value,
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        );
        if !AXIsProcessTrustedWithOptions(options) {
            eprintln!("loadout-wm: waiting for Privacy & Security > Accessibility");
            while !AXIsProcessTrustedWithOptions(ptr::null()) {
                std::thread::sleep(Duration::from_secs(2));
            }
        }
        CFRelease(options);
    }

    let app = NSApplication::sharedApplication(mtm);
    app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);

    let changed = RcBlock::new(|_: NonNull<NSNotification>| {
        refresh();
        // AX may not accept a just-launched app's observer yet; sync again once it has settled.
        after(Duration::from_secs(1), 0);
    });
    let activated = RcBlock::new(|_: NonNull<NSNotification>| {
        refresh();
        if let Some(front) = unsafe { NSWorkspace::sharedWorkspace().frontmostApplication() } {
            let pid = unsafe { front.processIdentifier() };
            soon(pid);
            // Switching to one of a pair brings its partner up too, right under it, without activating it.
            let partner = STATE.with_borrow(|st| {
                let pair = st.pair.as_ref()?;
                let side = pair.pids.iter().position(|&p| p == pid)?;
                pair.windows[1 - side].clone()
            });
            if let Some(w) = partner {
                unsafe { AXUIElementPerformAction(w.0, cfstr("AXRaise").0) };
            }
        }
    });
    let screens_changed = RcBlock::new(|_: NonNull<NSNotification>| {
        refresh();
        for pid in STATE.with_borrow(|st| st.apps.keys().copied().collect::<Vec<_>>()) {
            soon(pid);
        }
    });
    let paired = RcBlock::new(|n: NonNull<NSNotification>| {
        let text = unsafe { n.as_ref().object() }.and_then(|o| o.downcast::<NSString>().ok());
        let Some(pair) = text.and_then(|t| parse_pair(&t.to_string())) else { return };
        debug(|| format!("pair {:?} at {}", pair.pids, pair.fraction));
        let pids = pair.pids;
        STATE.with_borrow_mut(|st| st.pair = Some(pair));
        refresh();
        pids.into_iter().for_each(soon);
    });
    let workspace = unsafe { NSWorkspace::sharedWorkspace().notificationCenter() };
    // The centers hold the blocks for as long as the observer tokens live, which is the life of the process.
    let _tokens = unsafe {
        [
            workspace.addObserverForName_object_queue_usingBlock(
                Some(NSWorkspaceDidLaunchApplicationNotification),
                None,
                None,
                &changed,
            ),
            workspace.addObserverForName_object_queue_usingBlock(
                Some(NSWorkspaceDidTerminateApplicationNotification),
                None,
                None,
                &changed,
            ),
            workspace.addObserverForName_object_queue_usingBlock(
                Some(NSWorkspaceDidActivateApplicationNotification),
                None,
                None,
                &activated,
            ),
            NSNotificationCenter::defaultCenter().addObserverForName_object_queue_usingBlock(
                Some(NSApplicationDidChangeScreenParametersNotification),
                None,
                None,
                &screens_changed,
            ),
            NSDistributedNotificationCenter::defaultCenter().addObserverForName_object_queue_usingBlock(
                Some(&NSString::from_str(PAIR)),
                None,
                None,
                &paired,
            ),
        ]
    };

    // Menu bar icon, the only way to see it is running and to quit it. Quit is NSApp's terminate:, so it needs no
    // target class; a clean exit is not restarted by the LaunchAgent (KeepAlive is crash-only).
    let status = unsafe { NSStatusBar::systemStatusBar().statusItemWithLength(NSVariableStatusItemLength) };
    unsafe {
        if let Some(button) = status.button(mtm) {
            let name = NSString::from_str("rectangle.split.2x1");
            let image = NSImage::imageWithSystemSymbolName_accessibilityDescription(&name, Some(&NSString::from_str("Loadout WM")));
            button.setImage(image.as_deref());
        }
        let menu = NSMenu::new(mtm);
        let title = format!("Loadout WM {}", env!("CARGO_PKG_VERSION"));
        let about = NSMenuItem::initWithTitle_action_keyEquivalent(mtm.alloc(), &NSString::from_str(&title), None, &NSString::new());
        about.setEnabled(false);
        menu.addItem(&about);
        menu.addItem(&NSMenuItem::separatorItem(mtm));
        menu.addItem(&NSMenuItem::initWithTitle_action_keyEquivalent(
            mtm.alloc(),
            &NSString::from_str("Quit Loadout WM"),
            Some(sel!(terminate:)),
            &NSString::from_str("q"),
        ));
        menu.setAutoenablesItems(false);
        status.setMenu(Some(&menu));
    }

    refresh();
    app.run();
}

/// `<left pid> <right pid> <fraction of the width for the left>`.
fn parse_pair(text: &str) -> Option<Pair> {
    let f: Vec<&str> = text.split_whitespace().collect();
    let [l, r, frac] = f[..] else { return None };
    let fraction: f64 = frac.parse().ok().filter(|f| *f > 0.0 && *f < 1.0)?;
    Some(Pair { pids: [l.parse().ok()?, r.parse().ok()?], fraction, windows: [None, None] })
}

/// `loadout-wm pair <left pid> <right pid> <fraction>`: hands the pair to the running instance and exits.
pub fn post_pair(args: Vec<String>) {
    let text = args.join(" ");
    if parse_pair(&text).is_none() {
        eprintln!("usage: loadout-wm pair <left pid> <right pid> <fraction, 0-1>");
        std::process::exit(2);
    }
    unsafe {
        NSDistributedNotificationCenter::defaultCenter().postNotificationName_object_userInfo_deliverImmediately(
            &NSString::from_str(PAIR),
            Some(&NSString::from_str(&text)),
            None,
            true,
        );
    }
}
