// macOS: the Accessibility API moves windows, AXObservers report new and closed windows per listed app, and
// NSWorkspace reports launches, quits and activations. Activating an app lays its windows out again, so a window
// dragged aside snaps back the next time you switch to it.
#![allow(unused_unsafe)]

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, c_void};
use std::ptr::{self, NonNull};
use std::time::Duration;

use block2::RcBlock;
use objc2::MainThreadMarker;
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSApplicationDidChangeScreenParametersNotification, NSScreen,
    NSWorkspace, NSWorkspaceDidActivateApplicationNotification, NSWorkspaceDidLaunchApplicationNotification,
    NSWorkspaceDidTerminateApplicationNotification,
};
use objc2_foundation::{NSNotification, NSNotificationCenter};

use crate::{app_listed, plan, rule_for, Rect, Rules, Screen, Win};

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

/// A listed app being watched: its AX element, its observer, and the names rules match against.
struct App {
    element: Ref,
    observer: Ref,
    names: [String; 2],
}

impl Drop for App {
    fn drop(&mut self) {
        unsafe {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(self.observer.0), kCFRunLoopDefaultMode)
        }
    }
}

#[derive(Default)]
struct State {
    rules: Rules,
    apps: HashMap<i32, App>,
    first: HashMap<usize, Ref>,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::default();
}

extern "C" fn on_ax(_observer: CFTypeRef, _element: CFTypeRef, _name: CFTypeRef, pid: *mut c_void) {
    soon(pid as isize as i32);
}

fn watch(pid: i32, names: [String; 2]) -> Option<App> {
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
        return None;
    }
    unsafe {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer.0), kCFRunLoopDefaultMode);
    }
    Some(App { element, observer, names })
}

/// Rereads the rules and starts watching listed apps not yet watched. Returns the pids to lay out: new apps, or
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
        if st.apps.contains_key(&pid) {
            continue;
        }
        let id = unsafe { app.bundleIdentifier() }.map(|s| s.to_string()).unwrap_or_default();
        let name = unsafe { app.localizedName() }.map(|s| s.to_string()).unwrap_or_default();
        if !app_listed(&st.rules.list, &[&id, &name]) {
            continue;
        }
        if let Some(watched) = watch(pid, [id, name]) {
            st.apps.insert(pid, watched);
            fresh.push(pid);
        }
    }
    st.apps.retain(|pid, _| alive.contains(pid));
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

fn layout(pid: i32) {
    STATE.with_borrow_mut(|st| {
        let Some(app) = st.apps.get(&pid) else { return };
        let names = [app.names[0].as_str(), app.names[1].as_str()];
        let mut wins = Vec::new();
        if let Some(list) = attr(app.element.0, "AXWindows") {
            for i in 0..unsafe { CFArrayGetCount(list.0) } {
                let w = Ref(unsafe { CFRetain(CFArrayGetValueAtIndex(list.0, i)) });
                // Dialogs, sheets, panels and picture-in-picture have other subroles, so they float.
                if string_attr(w.0, "AXSubrole") != "AXStandardWindow"
                    || bool_attr(w.0, "AXMinimized")
                    || bool_attr(w.0, "AXFullScreen")
                {
                    continue;
                }
                let Some(rule) = rule_for(&st.rules.list, &names, &string_attr(w.0, "AXTitle")) else { continue };
                let Some(frame) = frame(w.0) else { continue };
                // Closing it then lays the app out again (split rebalances, first hands over). Already registered
                // is an error AX returns and we ignore.
                unsafe {
                    AXObserverAddNotification(app.observer.0, w.0, cfstr("AXUIElementDestroyed").0, pid as isize as *mut c_void);
                }
                wins.push(Win { id: w, rule, frame });
            }
        }
        for (w, r) in plan(&st.rules.list, &wins, &screens(), &mut st.first) {
            if frame(w.0) != Some(r) {
                set_frame(w.0, r);
            }
        }
    });
}

extern "C" fn later(pid: *mut c_void) {
    match pid as isize as i32 {
        0 => refresh(),
        pid => layout(pid),
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
    layout(pid);
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
            soon(unsafe { front.processIdentifier() });
        }
    });
    let screens_changed = RcBlock::new(|_: NonNull<NSNotification>| {
        refresh();
        for pid in STATE.with_borrow(|st| st.apps.keys().copied().collect::<Vec<_>>()) {
            soon(pid);
        }
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
        ]
    };

    refresh();
    app.run();
}
