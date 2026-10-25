// Windows: WinEvent hooks report windows shown, hidden, destroyed and brought to the foreground; each one lays out
// every listed window again (a few dozen style checks), which also snaps a dragged window back on the next
// foreground change. Coordinates are physical pixels (per-monitor DPI aware), so the padding is scaled by DPI.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::ptr;

use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HWND, LPARAM, RECT};
use windows_sys::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows_sys::Win32::Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO};
use windows_sys::Win32::System::Threading::{
    CreateMutexW, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows_sys::Win32::UI::Accessibility::{SetWinEventHook, HWINEVENTHOOK};
use windows_sys::Win32::UI::HiDpi::{
    GetDpiForMonitor, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, EnumWindows, GetMessageW, GetWindow, GetWindowLongW, GetWindowRect, GetWindowTextW,
    GetWindowThreadProcessId, IsIconic, IsWindowVisible, IsZoomed, KillTimer, SetTimer, SetWindowPos, ShowWindow,
    TranslateMessage, CHILDID_SELF, EVENT_OBJECT_DESTROY, EVENT_OBJECT_HIDE,
    EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_MINIMIZEEND, EVENT_SYSTEM_MOVESIZEEND, GWL_EXSTYLE, GWL_STYLE, GW_OWNER, MSG, OBJID_WINDOW,
    SWP_NOACTIVATE, SWP_NOZORDER, SW_RESTORE, WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS, WS_CAPTION,
    WS_EX_TOOLWINDOW, WS_THICKFRAME,
};

use crate::{plan, rule_for, Rect, Rules, Screen, Win};

#[derive(Default)]
struct State {
    rules: Rules,
    first: HashMap<usize, isize>,
    /// The listed windows of the last pass, so their destruction triggers a pass and others' does not.
    known: HashSet<isize>,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::default();
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain([0]).collect()
}

/// The visible frame, without the invisible resize border Windows 10+ draws outside it.
fn visible(hwnd: HWND) -> Option<RECT> {
    let mut r: RECT = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<RECT>() as u32;
    let hr = unsafe { DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS as _, &mut r as *mut _ as _, size) };
    (hr == 0).then_some(r)
}

fn to_rect(r: RECT) -> Rect {
    Rect { x: r.left as f64, y: r.top as f64, w: (r.right - r.left) as f64, h: (r.bottom - r.top) as f64 }
}

/// A top-level window a user would call a window: visible, unowned (dialogs are owned), resizable with a title bar,
/// not a tool window, not cloaked (UWP frames, other virtual desktops), not minimised.
fn is_normal(hwnd: HWND) -> bool {
    unsafe {
        let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
        let ex = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;
        let mut cloaked = 0u32;
        DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED as _, &mut cloaked as *mut _ as _, 4);
        IsWindowVisible(hwnd) != 0
            && IsIconic(hwnd) == 0
            && GetWindow(hwnd, GW_OWNER).is_null()
            && style & WS_CAPTION == WS_CAPTION
            && style & WS_THICKFRAME != 0
            && ex & WS_EX_TOOLWINDOW == 0
            && cloaked == 0
    }
}

/// The exe file name without .exe.
fn exe(hwnd: HWND) -> String {
    unsafe {
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, &mut pid);
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return String::new();
        }
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, buf.as_mut_ptr(), &mut len);
        CloseHandle(process);
        if ok == 0 {
            return String::new();
        }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        let name = path.rsplit('\\').next().unwrap_or("");
        name.strip_suffix(".exe").or_else(|| name.strip_suffix(".EXE")).unwrap_or(name).to_string()
    }
}

fn title(hwnd: HWND) -> String {
    let mut buf = [0u16; 512];
    let n = unsafe { GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as i32) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

unsafe extern "system" fn collect_window(hwnd: HWND, list: LPARAM) -> i32 {
    (*(list as *mut Vec<HWND>)).push(hwnd);
    1
}

unsafe extern "system" fn collect_monitor(mon: HMONITOR, _: HDC, _: *mut RECT, list: LPARAM) -> i32 {
    let mut info: MONITORINFO = std::mem::zeroed();
    info.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
    if GetMonitorInfoW(mon, &mut info) != 0 {
        let (mut dpi, mut _y) = (96, 96);
        GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &mut dpi, &mut _y);
        (*(list as *mut Vec<Screen>)).push(Screen { area: to_rect(info.rcWork), scale: dpi as f64 / 96.0 });
    }
    1
}

fn place(hwnd: HWND, r: Rect) {
    unsafe {
        if IsZoomed(hwnd) != 0 {
            ShowWindow(hwnd, SW_RESTORE);
        }
        let (Some(vis), mut outer) = (visible(hwnd), std::mem::zeroed::<RECT>()) else { return };
        if to_rect(vis) == r || GetWindowRect(hwnd, &mut outer) == 0 {
            return;
        }
        // SetWindowPos takes the outer frame: widen the target by the invisible border on each side.
        let (l, t) = (vis.left - outer.left, vis.top - outer.top);
        let (rt, b) = (outer.right - vis.right, outer.bottom - vis.bottom);
        SetWindowPos(
            hwnd,
            ptr::null_mut(),
            r.x as i32 - l,
            r.y as i32 - t,
            r.w as i32 + l + rt,
            r.h as i32 + t + b,
            SWP_NOZORDER | SWP_NOACTIVATE,
        );
    }
}

/// Lays out every listed window. Skipped when already running: moving another process's window can deliver our
/// own hook callbacks re-entrantly, and the delayed pass catches up.
fn pass() {
    STATE.with(|cell| {
        let Ok(mut st) = cell.try_borrow_mut() else { return };
        let st = &mut *st;
        if st.rules.reload() {
            st.first.clear();
        }
        let mut hwnds: Vec<HWND> = Vec::new();
        let mut screens: Vec<Screen> = Vec::new();
        unsafe {
            EnumWindows(Some(collect_window), &mut hwnds as *mut _ as LPARAM);
            EnumDisplayMonitors(ptr::null_mut(), ptr::null(), Some(collect_monitor), &mut screens as *mut _ as LPARAM);
        }
        // EnumWindows goes front to back, so a `first` rule's frontmost window is the first one here.
        let wins: Vec<Win<isize>> = hwnds
            .into_iter()
            .filter(|&h| is_normal(h))
            .filter_map(|h| {
                let rule = rule_for(&st.rules.list, &[&exe(h)], &title(h))?;
                Some(Win { id: h as isize, rule, frame: to_rect(visible(h)?) })
            })
            .collect();
        st.known = wins.iter().map(|w| w.id).collect();
        for (h, r) in plan(&st.rules.list, &wins, &screens, &mut st.first) {
            place(h as HWND, r);
        }
    });
}

unsafe extern "system" fn on_timer(_: HWND, _: u32, id: usize, _: u32) {
    KillTimer(ptr::null_mut(), id);
    pass();
}

/// Lays out now and again shortly after: a new window often moves itself once more right after it appears.
fn soon() {
    pass();
    unsafe { SetTimer(ptr::null_mut(), 0, 400, Some(on_timer)) };
}

unsafe extern "system" fn on_event(_: HWINEVENTHOOK, event: u32, hwnd: HWND, object: i32, child: i32, _: u32, _: u32) {
    if object != OBJID_WINDOW || child != CHILDID_SELF as i32 || hwnd.is_null() {
        return;
    }
    let relevant = match event {
        EVENT_OBJECT_DESTROY | EVENT_OBJECT_HIDE => {
            STATE.with(|cell| cell.try_borrow().is_ok_and(|st| st.known.contains(&(hwnd as isize))))
        }
        _ => is_normal(hwnd),
    };
    if relevant {
        soon();
    }
}

pub fn run() {
    unsafe {
        CreateMutexW(ptr::null(), 0, wide("Local\\loadout-wm").as_ptr());
        if GetLastError() == ERROR_ALREADY_EXISTS {
            return;
        }
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let flags = WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS;
        for (min, max) in [
            (EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND),
            (EVENT_SYSTEM_MINIMIZEEND, EVENT_SYSTEM_MINIMIZEEND),
            // The end of a user's drag or resize (never ours: SetWindowPos does not send it), so it snaps back.
            (EVENT_SYSTEM_MOVESIZEEND, EVENT_SYSTEM_MOVESIZEEND),
            (EVENT_OBJECT_DESTROY, EVENT_OBJECT_HIDE), // destroy, show, hide
        ] {
            SetWinEventHook(min, max, ptr::null_mut(), Some(on_event), 0, 0, flags);
        }
        soon();
        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}
