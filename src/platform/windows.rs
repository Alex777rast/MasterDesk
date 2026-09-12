use super::{CursorData, ResultType};
use crate::{
    common::PORTABLE_APPNAME_RUNTIME_ENV_KEY,
    custom_server::*,
    ipc,
    privacy_mode::win_topmost_window::{self, WIN_TOPMOST_INJECTED_PROCESS_EXE},
};
use hbb_common::{
    allow_err,
    anyhow::anyhow,
    bail,
    config::{self, Config},
    libc::{c_int, wchar_t},
    log,
    message_proto::{DisplayInfo, Resolution, WindowsSession},
    sleep,
    sysinfo::{Pid, System},
    timeout, tokio,
};
use std::{
    collections::HashMap,
    ffi::{CString, OsStr, OsString},
    fs,
    io::{self, prelude::*},
    mem,
    os::{
        raw::c_ulong,
        windows::{
            ffi::{OsStrExt, OsStringExt},
            process::CommandExt,
        },
    },
    path::*,
    ptr::null_mut,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Condvar, Mutex,
    },
    time::{Duration, Instant},
};
use wallpaper;
#[cfg(not(debug_assertions))]
use winapi::um::libloaderapi::{LoadLibraryExW, LOAD_LIBRARY_SEARCH_USER_DIRS};
use winapi::{
    ctypes::c_void,
    shared::{minwindef::*, ntdef::NULL, windef::*, winerror::*},
    um::{
        errhandlingapi::GetLastError,
        handleapi::{CloseHandle, INVALID_HANDLE_VALUE},
        libloaderapi::{
            GetProcAddress, LoadLibraryA, LoadLibraryExA, LOAD_LIBRARY_SEARCH_SYSTEM32,
        },
        minwinbase::STILL_ACTIVE,
        processthreadsapi::{
            GetCurrentProcess, GetCurrentProcessId, GetCurrentThreadId, GetExitCodeProcess,
            GetProcessId, OpenProcess, OpenProcessToken, ProcessIdToSessionId, TerminateProcess,
            PROCESS_INFORMATION, STARTUPINFOW,
        },
        securitybaseapi::{
            AllocateAndInitializeSid, DuplicateToken, EqualSid, FreeSid, GetTokenInformation,
        },
        shellapi::ShellExecuteW,
        synchapi::{CreateEventW, OpenEventW, SetEvent, WaitForSingleObject},
        sysinfoapi::{GetNativeSystemInfo, SYSTEM_INFO},
        winbase::*,
        wingdi::*,
        winnt::{
            SecurityImpersonation, TokenElevation, TokenGroups, TokenImpersonation, TokenType,
            DOMAIN_ALIAS_RID_ADMINS, ES_AWAYMODE_REQUIRED, ES_CONTINUOUS, ES_DISPLAY_REQUIRED,
            ES_SYSTEM_REQUIRED, EVENT_MODIFY_STATE, HANDLE, PROCESS_ALL_ACCESS,
            PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE, PSID,
            SECURITY_BUILTIN_DOMAIN_RID, SECURITY_NT_AUTHORITY, SID_IDENTIFIER_AUTHORITY,
            SYNCHRONIZE, TOKEN_ELEVATION, TOKEN_GROUPS, TOKEN_QUERY, TOKEN_TYPE,
        },
        winreg::HKEY_CURRENT_USER,
        winspool::{
            EnumPrintersW, GetDefaultPrinterW, PRINTER_ENUM_CONNECTIONS, PRINTER_ENUM_LOCAL,
            PRINTER_INFO_1W,
        },
        winuser::*,
    },
};
use windows::Win32::{
    Foundation::{CloseHandle as WinCloseHandle, HANDLE as WinHANDLE},
    Security::{
        GetTokenInformation as WinGetTokenInformation, IsWellKnownSid, TokenUser,
        WinLocalSystemSid, TOKEN_QUERY as WIN_TOKEN_QUERY, TOKEN_USER,
    },
    System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    },
    System::Threading::{
        OpenProcess as WinOpenProcess, OpenProcessToken as WinOpenProcessToken,
        QueryFullProcessImageNameW as WinQueryFullProcessImageNameW,
        PROCESS_QUERY_LIMITED_INFORMATION as WIN_PROCESS_QUERY_LIMITED_INFORMATION,
    },
};
use windows_service::{
    define_windows_service,
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
};
use winreg::{enums::*, RegKey};

mod acl;
pub(crate) use acl::current_process_user_sid_string;
pub use acl::{
    set_path_permission, set_path_permission_for_machine_secret,
    set_path_permission_for_portable_service_shmem_dir,
    set_path_permission_for_portable_service_shmem_file,
    validate_path_for_portable_service_shmem_dir,
};

pub const FLUTTER_RUNNER_WIN32_WINDOW_CLASS: &'static str = "FLUTTER_RUNNER_WIN32_WINDOW"; // main window, install window
pub const EXPLORER_EXE: &'static str = "explorer.exe";
pub const SET_FOREGROUND_WINDOW: &'static str = "SET_FOREGROUND_WINDOW";

const REG_NAME_INSTALL_DESKTOPSHORTCUTS: &str = "DESKTOPSHORTCUTS";
const REG_NAME_INSTALL_STARTMENUSHORTCUTS: &str = "STARTMENUSHORTCUTS";
pub const REG_NAME_INSTALL_PRINTER: &str = "PRINTER";
const SERVER_HANDOFF_ARG: &str = "--handoff-events";
const SERVER_HANDOFF_READY_TIMEOUT_MS: DWORD = 5_000;
const SERVER_HANDOFF_GO_TIMEOUT_MS: DWORD = 10_000;
const SAFE_MODE_NETWORK_REG_PATH: &str = r"SYSTEM\CurrentControlSet\Control\SafeBoot\Network";
const SAFE_MODE_REBOOT_MARKER_PATH: &str = r"SOFTWARE\MasterDesk\SafeModeReboot";
const SAFE_MODE_REBOOT_PHASE_ARMED: u32 = 1;
const SAFE_MODE_REBOOT_PHASE_STARTED: u32 = 2;

pub fn get_focused_display(displays: Vec<DisplayInfo>) -> Option<usize> {
    unsafe {
        let hwnd = GetForegroundWindow();
        let mut rect: RECT = mem::zeroed();
        if GetWindowRect(hwnd, &mut rect as *mut RECT) == 0 {
            return None;
        }
        displays.iter().position(|display| {
            let center_x = rect.left + (rect.right - rect.left) / 2;
            let center_y = rect.top + (rect.bottom - rect.top) / 2;
            center_x >= display.x
                && center_x < display.x + display.width
                && center_y >= display.y
                && center_y < display.y + display.height
        })
    }
}

pub fn get_cursor_pos() -> Option<(i32, i32)> {
    unsafe {
        let mut out = mem::MaybeUninit::<POINT>::uninit();
        if GetCursorPos(out.as_mut_ptr()) == FALSE {
            return None;
        }
        let out = out.assume_init();
        Some((out.x, out.y))
    }
}

pub fn set_cursor_pos(x: i32, y: i32) -> bool {
    unsafe {
        if SetCursorPos(x, y) == FALSE {
            let err = GetLastError();
            log::warn!("SetCursorPos failed: x={}, y={}, error_code={}", x, y, err);
            return false;
        }
        true
    }
}

#[repr(C)]
struct ClipboardDropFiles {
    files_offset: DWORD,
    drop_point: POINT,
    non_client: BOOL,
    wide: BOOL,
}

struct ViewerDropCacheWait {
    serial: u64,
    transfer_id: Option<String>,
    result: Option<bool>,
}

static NEXT_VIEWER_DROP_CACHE_SERIAL: AtomicU64 = AtomicU64::new(1);

lazy_static::lazy_static! {
    static ref VIEWER_DROP_CACHE_WAIT: (Mutex<Option<ViewerDropCacheWait>>, Condvar) =
        (Mutex::new(None), Condvar::new());
}

struct ViewerDropCacheGuard {
    serial: u64,
}

impl ViewerDropCacheGuard {
    fn register() -> ResultType<Self> {
        let (state, changed) = &*VIEWER_DROP_CACHE_WAIT;
        let mut state = state.lock().unwrap_or_else(|err| err.into_inner());
        if state.is_some() {
            bail!("Another Viewer file drop is already being prepared");
        }
        let serial = NEXT_VIEWER_DROP_CACHE_SERIAL.fetch_add(1, Ordering::Relaxed);
        *state = Some(ViewerDropCacheWait {
            serial,
            transfer_id: None,
            result: None,
        });
        changed.notify_all();
        Ok(Self { serial })
    }

    fn wait(&self) -> ResultType<()> {
        let deadline = Instant::now() + Duration::from_secs(30 * 60);
        let (state, changed) = &*VIEWER_DROP_CACHE_WAIT;
        let mut state = state.lock().unwrap_or_else(|err| err.into_inner());
        loop {
            let Some(pending) = state.as_ref() else {
                bail!("Viewer file drop cache wait was cancelled");
            };
            if pending.serial != self.serial {
                bail!("Viewer file drop was superseded by another drop");
            }
            if let Some(success) = pending.result {
                if success {
                    return Ok(());
                }
                bail!("Viewer file drop cache transfer failed");
            }
            let now = Instant::now();
            if now >= deadline {
                bail!("Viewer file drop cache transfer timed out");
            }
            let timeout = deadline.saturating_duration_since(now);
            let waited = changed
                .wait_timeout(state, timeout)
                .unwrap_or_else(|err| err.into_inner());
            state = waited.0;
        }
    }
}

impl Drop for ViewerDropCacheGuard {
    fn drop(&mut self) {
        let (state, changed) = &*VIEWER_DROP_CACHE_WAIT;
        let mut state = state.lock().unwrap_or_else(|err| err.into_inner());
        if state.as_ref().map(|pending| pending.serial) == Some(self.serial) {
            *state = None;
            changed.notify_all();
        }
    }
}

pub fn begin_viewer_drop_cache(transfer_id: &str) {
    let (state, changed) = &*VIEWER_DROP_CACHE_WAIT;
    let mut state = state.lock().unwrap_or_else(|err| err.into_inner());
    if let Some(pending) = state.as_mut() {
        if pending.transfer_id.is_none() {
            pending.transfer_id = Some(transfer_id.to_owned());
            changed.notify_all();
        }
    }
}

pub fn complete_viewer_drop_cache(transfer_id: &str, success: bool) {
    let (state, changed) = &*VIEWER_DROP_CACHE_WAIT;
    let mut state = state.lock().unwrap_or_else(|err| err.into_inner());
    if let Some(pending) = state.as_mut() {
        if pending.transfer_id.as_deref() == Some(transfer_id) {
            pending.result = Some(success);
            changed.notify_all();
        }
    }
}

pub fn fail_pending_viewer_drop_cache() {
    let (state, changed) = &*VIEWER_DROP_CACHE_WAIT;
    let mut state = state.lock().unwrap_or_else(|err| err.into_inner());
    if let Some(pending) = state.as_mut() {
        if pending.transfer_id.is_none() {
            pending.result = Some(false);
            changed.notify_all();
        }
    }
}

static VIEWER_DROP_PASTE_PENDING: AtomicBool = AtomicBool::new(false);

fn arm_viewer_drop_paste() {
    VIEWER_DROP_PASTE_PENDING.store(true, Ordering::Release);
}

pub fn take_viewer_drop_paste() -> bool {
    VIEWER_DROP_PASTE_PENDING.swap(false, Ordering::AcqRel)
}

#[cfg(test)]
mod viewer_drop_cache_tests {
    use super::*;

    #[test]
    fn viewer_drop_wait_matches_the_registered_transfer() {
        let completed = ViewerDropCacheGuard::register().unwrap();
        assert!(ViewerDropCacheGuard::register().is_err());
        begin_viewer_drop_cache("completed-transfer");
        complete_viewer_drop_cache("different-transfer", false);
        complete_viewer_drop_cache("completed-transfer", true);
        assert!(completed.wait().is_ok());
        drop(completed);

        let failed = ViewerDropCacheGuard::register().unwrap();
        begin_viewer_drop_cache("failed-transfer");
        complete_viewer_drop_cache("failed-transfer", false);
        assert!(failed.wait().is_err());
    }

    #[test]
    fn viewer_drop_paste_is_armed_for_exactly_one_shortcut() {
        arm_viewer_drop_paste();
        assert!(take_viewer_drop_paste());
        assert!(!take_viewer_drop_paste());
    }
}

/// Put local files on the Windows clipboard as a standard CF_HDROP payload.
///
/// The active clipboard channel observes the resulting clipboard update and
/// advertises the files through the same CLIPRDR path used by Explorer
/// Ctrl+C/Ctrl+V. Ownership of the global allocation is transferred to the
/// system only after SetClipboardData succeeds.
pub fn set_file_clipboard(paths: Vec<String>) -> ResultType<()> {
    if paths.is_empty() {
        bail!("No files were dropped");
    }

    // A drop can be the first file-clipboard generation after login or after
    // the user changed the global stream selector. Apply the current selector
    // before SetClipboardData triggers the synchronous native format snapshot.
    crate::client::io_loop::refresh_parallel_clipboard_cache_mode();

    let mut encoded_paths = Vec::with_capacity(paths.len());
    let mut utf16_units = 1usize; // final list terminator
    for value in paths {
        let path = Path::new(&value);
        if !path.is_absolute() || !path.exists() {
            bail!("Dropped path is not an existing absolute path: {}", value);
        }
        let encoded: Vec<u16> = OsStr::new(&value).encode_wide().collect();
        if encoded.is_empty() || encoded.contains(&0) {
            bail!("Dropped path is not valid for the Windows clipboard");
        }
        utf16_units = utf16_units
            .checked_add(encoded.len() + 1)
            .ok_or_else(|| anyhow!("Dropped file list is too large"))?;
        encoded_paths.push(encoded);
    }

    let payload_bytes = utf16_units
        .checked_mul(mem::size_of::<u16>())
        .and_then(|size| size.checked_add(mem::size_of::<ClipboardDropFiles>()))
        .ok_or_else(|| anyhow!("Dropped file list is too large"))?;

    let drop_cache = ViewerDropCacheGuard::register()?;
    let format_generation = clipboard::platform::windows::file_clipboard_format_generation();
    unsafe {
        let memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, payload_bytes);
        if memory.is_null() {
            bail!("GlobalAlloc failed: {}", GetLastError());
        }

        let locked = GlobalLock(memory);
        if locked.is_null() {
            let error = GetLastError();
            GlobalFree(memory);
            bail!("GlobalLock failed: {}", error);
        }

        let drop_files = locked as *mut ClipboardDropFiles;
        (*drop_files).files_offset = mem::size_of::<ClipboardDropFiles>() as DWORD;
        (*drop_files).wide = TRUE;
        let mut target = (locked as *mut u8).add(mem::size_of::<ClipboardDropFiles>()) as *mut u16;
        for encoded in &encoded_paths {
            std::ptr::copy_nonoverlapping(encoded.as_ptr(), target, encoded.len());
            target = target.add(encoded.len());
            *target = 0;
            target = target.add(1);
        }
        *target = 0;
        GlobalUnlock(memory);

        let mut clipboard_open = false;
        for _ in 0..20 {
            if OpenClipboard(null_mut()) != FALSE {
                clipboard_open = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        if !clipboard_open {
            let error = GetLastError();
            GlobalFree(memory);
            bail!("OpenClipboard failed: {}", error);
        }

        if EmptyClipboard() == FALSE {
            let error = GetLastError();
            CloseClipboard();
            GlobalFree(memory);
            bail!("EmptyClipboard failed: {}", error);
        }
        if SetClipboardData(CF_HDROP, memory).is_null() {
            let error = GetLastError();
            CloseClipboard();
            GlobalFree(memory);
            bail!("SetClipboardData failed: {}", error);
        }
        if CloseClipboard() == FALSE {
            bail!("CloseClipboard failed: {}", GetLastError());
        }
    }

    let deadline = Instant::now() + Duration::from_secs(3);
    while clipboard::platform::windows::file_clipboard_format_generation() == format_generation {
        if Instant::now() >= deadline {
            bail!("Clipboard file channel did not advertise the dropped files");
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    let (_, parallel_cache_required) = clipboard::platform::windows::file_clipboard_format_state();
    if parallel_cache_required {
        drop_cache.wait()?;
    }

    arm_viewer_drop_paste();

    Ok(())
}

/// Clip cursor to a rectangle. Pass None to unclip.
pub fn clip_cursor(rect: Option<(i32, i32, i32, i32)>) -> bool {
    unsafe {
        let result = match rect {
            Some((left, top, right, bottom)) => {
                let r = RECT {
                    left,
                    top,
                    right,
                    bottom,
                };
                ClipCursor(&r)
            }
            None => ClipCursor(std::ptr::null()),
        };
        if result == FALSE {
            let err = GetLastError();
            log::warn!("ClipCursor failed: rect={:?}, error_code={}", rect, err);
            return false;
        }
        true
    }
}

pub fn reset_input_cache() {}

pub fn get_cursor() -> ResultType<Option<u64>> {
    unsafe {
        #[allow(invalid_value)]
        let mut ci: CURSORINFO = mem::MaybeUninit::uninit().assume_init();
        ci.cbSize = std::mem::size_of::<CURSORINFO>() as _;
        if crate::portable_service::client::get_cursor_info(&mut ci) == FALSE {
            return Err(io::Error::last_os_error().into());
        }
        if ci.flags & CURSOR_SHOWING == 0 {
            Ok(None)
        } else {
            Ok(Some(ci.hCursor as _))
        }
    }
}

struct IconInfo(ICONINFO);

impl IconInfo {
    fn new(icon: HICON) -> ResultType<Self> {
        unsafe {
            #[allow(invalid_value)]
            let mut ii = mem::MaybeUninit::uninit().assume_init();
            if GetIconInfo(icon, &mut ii) == FALSE {
                Err(io::Error::last_os_error().into())
            } else {
                let ii = Self(ii);
                if ii.0.hbmMask.is_null() {
                    bail!("Cursor bitmap handle is NULL");
                }
                return Ok(ii);
            }
        }
    }

    fn is_color(&self) -> bool {
        !self.0.hbmColor.is_null()
    }
}

impl Drop for IconInfo {
    fn drop(&mut self) {
        unsafe {
            if !self.0.hbmColor.is_null() {
                DeleteObject(self.0.hbmColor as _);
            }
            if !self.0.hbmMask.is_null() {
                DeleteObject(self.0.hbmMask as _);
            }
        }
    }
}

// https://github.com/TurboVNC/tightvnc/blob/a235bae328c12fd1c3aed6f3f034a37a6ffbbd22/vnc_winsrc/winvnc/vncEncoder.cpp
// https://github.com/TigerVNC/tigervnc/blob/master/win/rfb_win32/DeviceFrameBuffer.cxx
pub fn get_cursor_data(hcursor: u64) -> ResultType<CursorData> {
    unsafe {
        let mut ii = IconInfo::new(hcursor as _)?;
        let bm_mask = get_bitmap(ii.0.hbmMask)?;
        let mut width = bm_mask.bmWidth;
        let mut height = if ii.is_color() {
            bm_mask.bmHeight
        } else {
            bm_mask.bmHeight / 2
        };
        let cbits_size = width * height * 4;
        if cbits_size < 16 {
            bail!("Invalid icon: too small"); // solve some crash
        }
        let mut cbits: Vec<u8> = Vec::new();
        cbits.resize(cbits_size as _, 0);
        let mut mbits: Vec<u8> = Vec::new();
        mbits.resize((bm_mask.bmWidthBytes * bm_mask.bmHeight) as _, 0);
        let r = GetBitmapBits(ii.0.hbmMask, mbits.len() as _, mbits.as_mut_ptr() as _);
        if r == 0 {
            bail!("Failed to copy bitmap data");
        }
        if r != (mbits.len() as i32) {
            bail!(
                "Invalid mask cursor buffer size, got {} bytes, expected {}",
                r,
                mbits.len()
            );
        }
        let do_outline;
        if ii.is_color() {
            get_rich_cursor_data(ii.0.hbmColor, width, height, &mut cbits)?;
            do_outline = fix_cursor_mask(
                &mut mbits,
                &mut cbits,
                width as _,
                height as _,
                bm_mask.bmWidthBytes as _,
            );
        } else {
            do_outline = handleMask(
                cbits.as_mut_ptr(),
                mbits.as_ptr(),
                width,
                height,
                bm_mask.bmWidthBytes,
                bm_mask.bmHeight,
            ) > 0;
        }
        if do_outline {
            let mut outline = Vec::new();
            outline.resize(((width + 2) * (height + 2) * 4) as _, 0);
            drawOutline(
                outline.as_mut_ptr(),
                cbits.as_ptr(),
                width,
                height,
                outline.len() as _,
            );
            cbits = outline;
            width += 2;
            height += 2;
            ii.0.xHotspot += 1;
            ii.0.yHotspot += 1;
        }

        Ok(CursorData {
            id: hcursor,
            colors: cbits.into(),
            hotx: ii.0.xHotspot as _,
            hoty: ii.0.yHotspot as _,
            width: width as _,
            height: height as _,
            ..Default::default()
        })
    }
}

#[inline]
fn get_bitmap(handle: HBITMAP) -> ResultType<BITMAP> {
    unsafe {
        let mut bm: BITMAP = mem::zeroed();
        if GetObjectA(
            handle as _,
            std::mem::size_of::<BITMAP>() as _,
            &mut bm as *mut BITMAP as *mut _,
        ) == FALSE
        {
            return Err(io::Error::last_os_error().into());
        }
        if bm.bmPlanes != 1 {
            bail!("Unsupported multi-plane cursor");
        }
        if bm.bmBitsPixel != 1 {
            bail!("Unsupported cursor mask format");
        }
        Ok(bm)
    }
}

struct DC(HDC);

impl DC {
    fn new() -> ResultType<Self> {
        unsafe {
            let dc = GetDC(0 as _);
            if dc.is_null() {
                bail!("Failed to get a drawing context");
            }
            Ok(Self(dc))
        }
    }
}

impl Drop for DC {
    fn drop(&mut self) {
        unsafe {
            if !self.0.is_null() {
                ReleaseDC(0 as _, self.0);
            }
        }
    }
}

struct CompatibleDC(HDC);

impl CompatibleDC {
    fn new(existing: HDC) -> ResultType<Self> {
        unsafe {
            let dc = CreateCompatibleDC(existing);
            if dc.is_null() {
                bail!("Failed to get a compatible drawing context");
            }
            Ok(Self(dc))
        }
    }
}

impl Drop for CompatibleDC {
    fn drop(&mut self) {
        unsafe {
            if !self.0.is_null() {
                DeleteDC(self.0);
            }
        }
    }
}

struct BitmapDC(CompatibleDC, HBITMAP);

impl BitmapDC {
    fn new(hdc: HDC, hbitmap: HBITMAP) -> ResultType<Self> {
        unsafe {
            let dc = CompatibleDC::new(hdc)?;
            let oldbitmap = SelectObject(dc.0, hbitmap as _) as HBITMAP;
            if oldbitmap.is_null() {
                bail!("Failed to select CompatibleDC");
            }
            Ok(Self(dc, oldbitmap))
        }
    }

    fn dc(&self) -> HDC {
        (self.0).0
    }
}

impl Drop for BitmapDC {
    fn drop(&mut self) {
        unsafe {
            if !self.1.is_null() {
                SelectObject((self.0).0, self.1 as _);
            }
        }
    }
}

#[inline]
fn get_rich_cursor_data(
    hbm_color: HBITMAP,
    width: i32,
    height: i32,
    out: &mut Vec<u8>,
) -> ResultType<()> {
    unsafe {
        let dc = DC::new()?;
        let bitmap_dc = BitmapDC::new(dc.0, hbm_color)?;
        if get_di_bits(out.as_mut_ptr(), bitmap_dc.dc(), hbm_color, width, height) > 0 {
            bail!("Failed to get di bits: {}", io::Error::last_os_error());
        }
    }
    Ok(())
}

fn fix_cursor_mask(
    mbits: &mut Vec<u8>,
    cbits: &mut Vec<u8>,
    width: usize,
    height: usize,
    bm_width_bytes: usize,
) -> bool {
    let mut pix_idx = 0;
    for _ in 0..height {
        for _ in 0..width {
            if cbits[pix_idx + 3] != 0 {
                return false;
            }
            pix_idx += 4;
        }
    }

    let packed_width_bytes = (width + 7) >> 3;
    let bm_size = mbits.len();
    let c_size = cbits.len();

    // Pack and invert bitmap data (mbits)
    // borrow from tigervnc
    for y in 0..height {
        for x in 0..packed_width_bytes {
            let a = y * packed_width_bytes + x;
            let b = y * bm_width_bytes + x;
            if a < bm_size && b < bm_size {
                mbits[a] = !mbits[b];
            }
        }
    }

    // Replace "inverted background" bits with black color to ensure
    // cross-platform interoperability. Not beautiful but necessary code.
    // borrow from tigervnc
    let bytes_row = width << 2;
    for y in 0..height {
        let mut bitmask: u8 = 0x80;
        for x in 0..width {
            let mask_idx = y * packed_width_bytes + (x >> 3);
            if mask_idx < bm_size {
                let pix_idx = y * bytes_row + (x << 2);
                if (mbits[mask_idx] & bitmask) == 0 {
                    for b1 in 0..4 {
                        let a = pix_idx + b1;
                        if a < c_size {
                            if cbits[a] != 0 {
                                mbits[mask_idx] ^= bitmask;
                                for b2 in b1..4 {
                                    let b = pix_idx + b2;
                                    if b < c_size {
                                        cbits[b] = 0x00;
                                    }
                                }
                                break;
                            }
                        }
                    }
                }
            }
            bitmask >>= 1;
            if bitmask == 0 {
                bitmask = 0x80;
            }
        }
    }

    // borrow from noVNC
    let mut pix_idx = 0;
    for y in 0..height {
        for x in 0..width {
            let mask_idx = y * packed_width_bytes + (x >> 3);
            let mut alpha = 255;
            if mask_idx < bm_size {
                if (mbits[mask_idx] << (x & 0x7)) & 0x80 == 0 {
                    alpha = 0;
                }
            }
            let a = cbits[pix_idx + 2];
            let b = cbits[pix_idx + 1];
            let c = cbits[pix_idx];
            cbits[pix_idx] = a;
            cbits[pix_idx + 1] = b;
            cbits[pix_idx + 2] = c;
            cbits[pix_idx + 3] = alpha;
            pix_idx += 4;
        }
    }
    return true;
}

define_windows_service!(ffi_service_main, service_main);

fn service_main(arguments: Vec<OsString>) {
    if let Err(e) = run_service(arguments) {
        log::error!("run_service failed: {}", e);
    }
}

pub fn start_os_service() {
    if let Err(e) =
        windows_service::service_dispatcher::start(crate::get_app_name(), ffi_service_main)
    {
        log::error!("start_service failed: {}", e);
    }
}

const SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;
const SERVER_PROCESS_EXIT_GRACE: Duration = Duration::from_secs(5);

extern "C" {
    fn get_current_session(rdp: BOOL) -> DWORD;
    fn is_session_locked(session_id: DWORD) -> BOOL;
    fn LaunchProcessWin(
        cmd: *const u16,
        session_id: DWORD,
        as_user: BOOL,
        show: BOOL,
        token_pid: &mut DWORD,
    ) -> HANDLE;
    fn GetSessionUserTokenWin(
        lphUserToken: LPHANDLE,
        dwSessionId: DWORD,
        as_user: BOOL,
        token_pid: &mut DWORD,
    ) -> BOOL;
    fn selectInputDesktop() -> BOOL;
    fn inputDesktopSelected() -> BOOL;
    fn is_windows_server() -> BOOL;
    fn is_windows_10_or_greater() -> BOOL;
    fn handleMask(
        out: *mut u8,
        mask: *const u8,
        width: i32,
        height: i32,
        bmWidthBytes: i32,
        bmHeight: i32,
    ) -> i32;
    fn drawOutline(out: *mut u8, in_: *const u8, width: i32, height: i32, out_size: i32);
    fn get_di_bits(out: *mut u8, dc: HDC, hbmColor: HBITMAP, width: i32, height: i32) -> i32;
    fn blank_screen(v: BOOL);
    fn win32_enable_lowlevel_keyboard(hwnd: HWND) -> i32;
    fn win32_disable_lowlevel_keyboard(hwnd: HWND);
    fn win_stop_system_key_propagate(v: BOOL);
    fn is_win_down() -> BOOL;
    fn is_local_system() -> BOOL;
    fn alloc_console_and_redirect();
    fn is_service_running_w(svc_name: *const u16) -> bool;
}

pub fn get_current_session_id(share_rdp: bool) -> DWORD {
    unsafe { get_current_session(if share_rdp { TRUE } else { FALSE }) }
}

#[inline]
fn resolve_expected_active_session_id_for_service(session_id: u32) -> Option<u32> {
    let share_rdp_enabled = is_share_rdp();
    if get_available_sessions(false)
        .iter()
        .any(|e| e.sid == session_id)
    {
        return Some(session_id);
    }
    let current_active_session =
        unsafe { get_current_session(if share_rdp_enabled { TRUE } else { FALSE }) };
    if current_active_session == u32::MAX {
        None
    } else {
        Some(current_active_session)
    }
}

#[inline]
fn authorize_service_scoped_ipc_connection(
    stream: &ipc::Connection,
    expected_active_session_id: Option<u32>,
) -> bool {
    let (authorized, peer_pid, peer_session_id, peer_is_system) =
        stream.service_authorization_status_for_session(expected_active_session_id);
    if !authorized {
        ipc::log_rejected_windows_ipc_connection(
            crate::POSTFIX_SERVICE,
            peer_pid,
            peer_session_id,
            expected_active_session_id,
            peer_is_system,
            None,
            None,
        );
        return false;
    }
    if let Err(err) =
        ipc::ensure_peer_executable_matches_current_by_pid_opt(peer_pid, crate::POSTFIX_SERVICE)
    {
        log::warn!(
                "Rejected unauthorized connection on protected service-scoped IPC channel due to executable mismatch: postfix={}, peer_pid={:?}, err={}",
                crate::POSTFIX_SERVICE,
                peer_pid,
                err
            );
        return false;
    }
    true
}

extern "system" {
    fn BlockInput(v: BOOL) -> BOOL;
}

#[tokio::main(flavor = "current_thread")]
async fn run_service(_arguments: Vec<OsString>) -> ResultType<()> {
    let event_handler = move |control_event| -> ServiceControlHandlerResult {
        log::info!("Got service control event: {:?}", control_event);
        match control_event {
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            ServiceControl::Stop | ServiceControl::Preshutdown | ServiceControl::Shutdown => {
                send_close(crate::POSTFIX_SERVICE).ok();
                ServiceControlHandlerResult::NoError
            }
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    };

    // Register system service event handler
    let status_handle = service_control_handler::register(crate::get_app_name(), event_handler)?;

    let next_status = ServiceStatus {
        // Should match the one from system service registry
        service_type: SERVICE_TYPE,
        // The new state
        current_state: ServiceState::Running,
        // Accept stop events when running
        controls_accepted: ServiceControlAccept::STOP,
        // Used to report an error when starting or stopping only, otherwise must be zero
        exit_code: ServiceExitCode::Win32(0),
        // Only used for pending states, otherwise must be zero
        checkpoint: 0,
        // Only used for pending states, otherwise must be zero
        wait_hint: Duration::default(),
        process_id: None,
    };

    // Tell the system that the service is running now
    status_handle.set_service_status(next_status)?;

    // A Safe Mode reboot is one-shot. As soon as the service is alive in the
    // Safe Mode with Networking boot, remove the BCD flag so the next reboot
    // returns to normal Windows. Custom SafeBoot entries are removed after
    // that following normal startup, not while this service still needs them.
    if let Err(err) = reconcile_safe_mode_reboot_state() {
        log::error!("Failed to reconcile Safe Mode reboot state: {err}");
    }

    let mut session_id = unsafe { get_current_session(share_rdp()) };
    log::info!("session id {}", session_id);
    // Bind the protected service endpoint before launching `--server`; beta 7
    // synchronizes the machine password verifier during server startup.
    let mut incoming = ipc::new_listener(crate::POSTFIX_SERVICE).await?;
    let mut h_process = NULL;
    if let Err(err) = replace_server_process(&mut h_process, session_id).await {
        log::error!(
            "Failed to launch initial --server process in session {}: {}",
            session_id,
            err
        );
    }
    let mut stored_usid = None;
    loop {
        let sids: Vec<_> = get_available_sessions(false)
            .iter()
            .map(|e| e.sid)
            .collect();
        if !sids.contains(&session_id) || !is_share_rdp() {
            let current_active_session = unsafe { get_current_session(share_rdp()) };
            if session_id != current_active_session {
                session_id = current_active_session;
                // https://github.com/rustdesk/rustdesk/discussions/10039
                let count = ipc::get_port_forward_session_count(1000).await.unwrap_or(0);
                if count == 0 {
                    if let Err(err) = replace_server_process(&mut h_process, session_id).await {
                        log::error!(
                            "Failed to switch --server process to automatically selected session {}: {}",
                            session_id,
                            err
                        );
                    }
                }
            }
        }
        let res = timeout(super::SERVICE_INTERVAL, incoming.next()).await;
        match res {
            Ok(res) => match res {
                Some(Ok(stream)) => {
                    let mut stream = ipc::Connection::new(stream);
                    // Keep IPC authorization consistent with the session we are currently serving.
                    // Recompute expected session right before authorization to avoid using a stale
                    // session_id after awaiting incoming.next().
                    let expected_active_session_id =
                        resolve_expected_active_session_id_for_service(session_id);
                    if !authorize_service_scoped_ipc_connection(&stream, expected_active_session_id)
                    {
                        continue;
                    }
                    if let Ok(Some(data)) = stream.next_timeout(1000).await {
                        match data {
                            ipc::Data::Close => {
                                log::info!("close received");
                                break;
                            }
                            ipc::Data::SAS => {
                                send_sas();
                            }
                            ipc::Data::SafeModeRestart(None) => {
                                let error = match restart_in_safe_mode() {
                                    Ok(()) => String::new(),
                                    Err(err) => {
                                        log::error!(
                                            "Failed to restart in Safe Mode from the service: {err}"
                                        );
                                        err.to_string()
                                    }
                                };
                                allow_err!(
                                    stream.send(&ipc::Data::SafeModeRestart(Some(error))).await
                                );
                            }
                            ipc::Data::UserSid(usid) => {
                                if let Some(usid) = usid {
                                    if session_id != usid {
                                        log::info!(
                                            "session changed from {} to {}",
                                            session_id,
                                            usid
                                        );
                                        session_id = usid;
                                        stored_usid = Some(session_id);
                                        if let Err(err) =
                                            replace_server_process(&mut h_process, session_id).await
                                        {
                                            log::error!(
                                                "Failed to switch --server process to requested RDP session {}: {}",
                                                session_id,
                                                err
                                            );
                                        }
                                    }
                                }
                            }
                            ipc::Data::Config((name, value))
                                if name == "machine-permanent-password-state" =>
                            {
                                let state = match crate::machine_password::load() {
                                    Ok(Some(payload)) => match payload.h1() {
                                        Ok(Some(_)) => "Y",
                                        Ok(None) => "N",
                                        Err(err) => {
                                            log::error!(
                                                "Failed to validate machine permanent password state: {err}"
                                            );
                                            "E"
                                        }
                                    },
                                    Ok(None) => "N",
                                    Err(err) => {
                                        log::error!(
                                            "Failed to load machine permanent password state: {err}"
                                        );
                                        "E"
                                    }
                                };
                                allow_err!(
                                    stream
                                        .send(&ipc::Data::Config((name, Some(state.to_owned()))))
                                        .await
                                );
                            }
                            ipc::Data::Config((name, Some(password)))
                                if name == "machine-permanent-password-set" =>
                            {
                                let accepted = match crate::machine_password::set_plain(&password) {
                                    Ok(_) => true,
                                    Err(err) => {
                                        log::error!(
                                            "Failed to update machine permanent password store: {err}"
                                        );
                                        false
                                    }
                                };
                                allow_err!(
                                    stream
                                        .send(&ipc::Data::Config((
                                            name,
                                            Some(if accepted { "Y" } else { "N" }.to_owned())
                                        )))
                                        .await
                                );
                            }
                            ipc::Data::Config((name, Some(request)))
                                if name == "machine-permanent-password-sync" =>
                            {
                                let response = (|| -> ResultType<String> {
                                    let legacy: Option<
                                        crate::machine_password::MachinePasswordPayload,
                                    > = serde_json::from_str(&request)?;
                                    let payload =
                                        crate::machine_password::initialize_if_missing(legacy)?;
                                    Ok(serde_json::to_string(&payload)?)
                                })();
                                match response {
                                    Ok(response) => {
                                        allow_err!(
                                            stream
                                                .send(&ipc::Data::Config((name, Some(response))))
                                                .await
                                        );
                                    }
                                    Err(err) => {
                                        log::error!(
                                            "Failed to synchronize machine permanent password: {err}"
                                        );
                                        allow_err!(
                                            stream.send(&ipc::Data::Config((name, None))).await
                                        );
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            },
            Err(_) => {
                // timeout
                unsafe {
                    let tmp = get_current_session(share_rdp());
                    if tmp == 0xFFFFFFFF {
                        continue;
                    }
                    if tmp != session_id && stored_usid != Some(session_id) {
                        log::info!("session changed from {} to {}", session_id, tmp);
                        session_id = tmp;
                        let count = ipc::get_port_forward_session_count(1000).await.unwrap_or(0);
                        if count == 0 {
                            if let Err(err) =
                                replace_server_process(&mut h_process, session_id).await
                            {
                                log::error!(
                                    "Failed to switch --server process to active session {}: {}",
                                    session_id,
                                    err
                                );
                            }
                        }
                    }
                    let mut exit_code: DWORD = 0;
                    let process_stopped = h_process.is_null()
                        || GetExitCodeProcess(h_process, &mut exit_code) != TRUE
                        || exit_code != STILL_ACTIVE;
                    if process_stopped {
                        if let Err(err) = replace_server_process(&mut h_process, session_id).await {
                            log::error!(
                                "Failed to restart --server process in session {}: {}",
                                session_id,
                                err
                            );
                        }
                    }
                }
            }
        }
    }

    stop_server_process(&mut h_process).await;

    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Stopped,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })?;

    Ok(())
}

async fn launch_server(
    session_id: DWORD,
    close_first: bool,
    handoff_events: Option<(&str, &str)>,
) -> ResultType<HANDLE> {
    if close_first {
        // in case started some elsewhere
        send_close_async("").await.ok();
    }
    let cmd = if let Some((ready_event, go_event)) = handoff_events {
        format!(
            "\"{}\" --server {} \"{}\" \"{}\"",
            std::env::current_exe()?.to_str().unwrap_or(""),
            SERVER_HANDOFF_ARG,
            ready_event,
            go_event
        )
    } else {
        format!(
            "\"{}\" --server",
            std::env::current_exe()?.to_str().unwrap_or("")
        )
    };
    launch_privileged_process(session_id, &cmd)
}

async fn stop_server_process(h_process: &mut HANDLE) {
    if let Err(err) = send_close_async("").await {
        log::debug!("No running --server IPC endpoint to close: {}", err);
    }

    if h_process.is_null() {
        return;
    }

    let started = Instant::now();
    loop {
        let mut exit_code: DWORD = 0;
        let status_ok = unsafe { GetExitCodeProcess(*h_process, &mut exit_code) == TRUE };
        if !status_ok {
            log::warn!(
                "Failed to query old --server process status: {}",
                io::Error::last_os_error()
            );
            break;
        }
        if exit_code != STILL_ACTIVE {
            log::info!("Old --server process exited with code {}", exit_code);
            break;
        }
        if started.elapsed() >= SERVER_PROCESS_EXIT_GRACE {
            log::warn!(
                "Old --server process did not exit within {:?}; terminating the service-owned child before RDP handover",
                SERVER_PROCESS_EXIT_GRACE
            );
            if unsafe { TerminateProcess(*h_process, 1) } == FALSE {
                log::error!(
                    "Failed to terminate stale --server process: {}",
                    io::Error::last_os_error()
                );
            } else {
                sleep(0.1).await;
            }
            break;
        }
        sleep(0.05).await;
    }

    unsafe {
        CloseHandle(*h_process);
    }
    *h_process = NULL;
}

async fn replace_server_process(h_process: &mut HANDLE, session_id: DWORD) -> ResultType<()> {
    let old_process_running = if h_process.is_null() {
        false
    } else {
        let mut exit_code: DWORD = 0;
        unsafe {
            GetExitCodeProcess(*h_process, &mut exit_code) == TRUE && exit_code == STILL_ACTIVE
        }
    };
    if !old_process_running {
        stop_server_process(h_process).await;
    }
    let event_suffix = format!(
        "{}-{:08x}",
        std::process::id(),
        hbb_common::rand::random::<u32>()
    );
    let ready_event_name = format!("Global\\MasterDeskServerReady-{event_suffix}");
    let go_event_name = format!("Global\\MasterDeskServerGo-{event_suffix}");
    let (ready_event, go_event) = if old_process_running {
        let ready_name = wide_string(&ready_event_name);
        let go_name = wide_string(&go_event_name);
        let ready = unsafe { CreateEventW(null_mut(), TRUE, FALSE, ready_name.as_ptr()) };
        let go = unsafe { CreateEventW(null_mut(), TRUE, FALSE, go_name.as_ptr()) };
        if ready.is_null() || go.is_null() {
            if !ready.is_null() {
                unsafe { CloseHandle(ready) };
            }
            if !go.is_null() {
                unsafe { CloseHandle(go) };
            }
            bail!("Failed to create protected --server handoff events");
        }
        (ready, go)
    } else {
        (NULL, NULL)
    };

    let handoff_names =
        old_process_running.then_some((ready_event_name.as_str(), go_event_name.as_str()));
    let new_process = match launch_server(session_id, false, handoff_names).await {
        Ok(process) => process,
        Err(err) => {
            if !ready_event.is_null() {
                unsafe { CloseHandle(ready_event) };
            }
            if !go_event.is_null() {
                unsafe { CloseHandle(go_event) };
            }
            return Err(err);
        }
    };
    if new_process.is_null() {
        if !ready_event.is_null() {
            unsafe { CloseHandle(ready_event) };
        }
        if !go_event.is_null() {
            unsafe { CloseHandle(go_event) };
        }
        bail!("CreateProcessAsUserW returned a null process handle");
    }

    let process_id = unsafe { GetProcessId(new_process) };
    let mut actual_session_id = DWORD::MAX;
    let actual_session_known = process_id != 0
        && unsafe { ProcessIdToSessionId(process_id, &mut actual_session_id) == TRUE };
    if !actual_session_known || actual_session_id != session_id {
        unsafe {
            TerminateProcess(new_process, 1);
            CloseHandle(new_process);
            if !ready_event.is_null() {
                CloseHandle(ready_event);
            }
            if !go_event.is_null() {
                CloseHandle(go_event);
            }
        }
        bail!(
            "launched --server pid {} in session {:?}, expected session {}",
            process_id,
            actual_session_known.then_some(actual_session_id),
            session_id
        );
    }

    if old_process_running {
        let ready = unsafe { WaitForSingleObject(ready_event, SERVER_HANDOFF_READY_TIMEOUT_MS) };
        if ready != WAIT_OBJECT_0 {
            unsafe {
                TerminateProcess(new_process, 1);
                CloseHandle(new_process);
                CloseHandle(ready_event);
                CloseHandle(go_event);
            }
            bail!(
                "replacement --server did not reach handoff standby in {} ms",
                SERVER_HANDOFF_READY_TIMEOUT_MS
            );
        }
        stop_server_process(h_process).await;
        if unsafe { SetEvent(go_event) } == FALSE {
            unsafe {
                TerminateProcess(new_process, 1);
                CloseHandle(new_process);
                CloseHandle(ready_event);
                CloseHandle(go_event);
            }
            bail!("Failed to release replacement --server from handoff standby");
        }
        unsafe {
            CloseHandle(ready_event);
            CloseHandle(go_event);
        }
    }

    log::info!(
        "Started --server pid {} in Windows session {} on winsta0\\default",
        process_id,
        actual_session_id
    );
    *h_process = new_process;
    Ok(())
}

/// Called by a prelaunched replacement `--server` before it opens the main IPC
/// listener. It proves that the process reached the correct executable branch,
/// then waits until the service has retired the previous desktop server.
pub fn wait_for_server_handoff_if_requested(args: &[String]) -> ResultType<()> {
    if args.len() < 4 || args[1] != SERVER_HANDOFF_ARG {
        return Ok(());
    }
    let ready_name = wide_string(&args[2]);
    let go_name = wide_string(&args[3]);
    let ready = unsafe { OpenEventW(EVENT_MODIFY_STATE, FALSE, ready_name.as_ptr()) };
    let go = unsafe { OpenEventW(SYNCHRONIZE, FALSE, go_name.as_ptr()) };
    if ready.is_null() || go.is_null() {
        if !ready.is_null() {
            unsafe { CloseHandle(ready) };
        }
        if !go.is_null() {
            unsafe { CloseHandle(go) };
        }
        bail!("Failed to open service-created --server handoff events");
    }
    if unsafe { SetEvent(ready) } == FALSE {
        unsafe {
            CloseHandle(ready);
            CloseHandle(go);
        }
        bail!("Failed to signal --server handoff readiness");
    }
    let released = unsafe { WaitForSingleObject(go, SERVER_HANDOFF_GO_TIMEOUT_MS) };
    unsafe {
        CloseHandle(ready);
        CloseHandle(go);
    }
    if released != WAIT_OBJECT_0 {
        bail!(
            "Service did not release --server handoff within {} ms",
            SERVER_HANDOFF_GO_TIMEOUT_MS
        );
    }
    Ok(())
}

pub fn launch_privileged_process(session_id: DWORD, cmd: &str) -> ResultType<HANDLE> {
    use std::os::windows::ffi::OsStrExt;
    let wstr: Vec<u16> = std::ffi::OsStr::new(&cmd)
        .encode_wide()
        .chain(Some(0).into_iter())
        .collect();
    let wstr = wstr.as_ptr();
    let mut token_pid = 0;
    let h = unsafe { LaunchProcessWin(wstr, session_id, FALSE, FALSE, &mut token_pid) };
    if h.is_null() {
        log::error!(
            "Failed to launch privileged process: {}",
            io::Error::last_os_error()
        );
        if token_pid == 0 {
            log::error!("No process winlogon.exe");
        }
    }
    Ok(h)
}

pub fn run_as_user(arg: Vec<&str>) -> ResultType<Option<std::process::Child>> {
    run_exe_in_cur_session(std::env::current_exe()?.to_str().unwrap_or(""), arg, false)
}

pub fn run_exe_direct(
    exe: &str,
    arg: Vec<&str>,
    show: bool,
) -> ResultType<Option<std::process::Child>> {
    let mut cmd = std::process::Command::new(exe);
    for a in arg {
        cmd.arg(a);
    }
    if !show {
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    match cmd.spawn() {
        Ok(child) => Ok(Some(child)),
        Err(e) => bail!("Failed to start process: {}", e),
    }
}

pub fn run_exe_in_cur_session(
    exe: &str,
    arg: Vec<&str>,
    show: bool,
) -> ResultType<Option<std::process::Child>> {
    if is_root() {
        let Some(session_id) = get_current_process_session_id() else {
            bail!("Failed to get current process session id");
        };
        run_exe_in_session(exe, arg, session_id, show)
    } else {
        run_exe_direct(exe, arg, show)
    }
}

pub fn run_exe_in_session(
    exe: &str,
    arg: Vec<&str>,
    session_id: DWORD,
    show: bool,
) -> ResultType<Option<std::process::Child>> {
    use std::os::windows::ffi::OsStrExt;
    let cmd = format!("\"{}\" {}", exe, arg.join(" "),);
    let wstr: Vec<u16> = std::ffi::OsStr::new(&cmd)
        .encode_wide()
        .chain(Some(0).into_iter())
        .collect();
    let wstr = wstr.as_ptr();
    let mut token_pid = 0;
    let h = unsafe {
        LaunchProcessWin(
            wstr,
            session_id,
            TRUE,
            if show { TRUE } else { FALSE },
            &mut token_pid,
        )
    };
    if h.is_null() {
        if token_pid == 0 {
            bail!(
                "Failed to launch {:?} with session id {}: no process {}",
                arg,
                session_id,
                EXPLORER_EXE
            );
        }
        bail!(
            "Failed to launch {:?} with session id {}: {}",
            arg,
            session_id,
            io::Error::last_os_error()
        );
    }
    Ok(None)
}

#[tokio::main(flavor = "current_thread")]
async fn send_close(postfix: &str) -> ResultType<()> {
    send_close_async(postfix).await
}

async fn send_close_async(postfix: &str) -> ResultType<()> {
    ipc::connect(1000, postfix)
        .await?
        .send(&ipc::Data::Close)
        .await?;
    // sleep a while to wait for closing and exit
    sleep(0.1).await;
    Ok(())
}

// https://docs.microsoft.com/en-us/windows/win32/api/sas/nf-sas-sendsas
// https://www.cnblogs.com/doutu/p/4892726.html
pub fn send_sas() {
    #[link(name = "sas")]
    extern "system" {
        pub fn SendSAS(AsUser: BOOL);
    }
    unsafe {
        log::info!("SAS received");

        // Check and temporarily set SoftwareSASGeneration if needed
        let mut original_value: Option<u32> = None;
        let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);

        if let Ok(policy_key) = hklm.open_subkey_with_flags(
            "Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
            KEY_READ | KEY_WRITE,
        ) {
            // Read current value
            match policy_key.get_value::<u32, _>("SoftwareSASGeneration") {
                Ok(value) => {
                    /*
                    - 0 = None (disabled)
                    - 1 = Services
                    - 2 = Ease of Access applications
                    - 3 = Services and Ease of Access applications (Both)
                                      */
                    if value != 1 && value != 3 {
                        original_value = Some(value);
                        log::info!("SoftwareSASGeneration is {}, setting to 1", value);
                        // Set to 1 for SendSAS to work
                        if let Err(e) = policy_key.set_value("SoftwareSASGeneration", &1u32) {
                            log::error!("Failed to set SoftwareSASGeneration: {}", e);
                        }
                    }
                }
                Err(e) => {
                    log::info!(
                        "SoftwareSASGeneration not found or error reading: {}, setting to 1",
                        e
                    );
                    original_value = Some(0); // Mark that we need to restore (delete) it
                                              // Create and set to 1
                    if let Err(e) = policy_key.set_value("SoftwareSASGeneration", &1u32) {
                        log::error!("Failed to set SoftwareSASGeneration: {}", e);
                    }
                }
            }
        } else {
            log::error!("Failed to open registry key for SoftwareSASGeneration");
        }

        // Send SAS
        SendSAS(FALSE);

        // Restore original value if we changed it
        if let Some(original) = original_value {
            if let Ok(policy_key) = hklm.open_subkey_with_flags(
                "Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
                KEY_WRITE,
            ) {
                if original == 0 {
                    // It didn't exist before, delete it
                    if let Err(e) = policy_key.delete_value("SoftwareSASGeneration") {
                        log::error!("Failed to delete SoftwareSASGeneration: {}", e);
                    } else {
                        log::info!("Deleted SoftwareSASGeneration (restored to original state)");
                    }
                } else {
                    // Restore the original value
                    if let Err(e) = policy_key.set_value("SoftwareSASGeneration", &original) {
                        log::error!(
                            "Failed to restore SoftwareSASGeneration to {}: {}",
                            original,
                            e
                        );
                    } else {
                        log::info!("Restored SoftwareSASGeneration to {}", original);
                    }
                }
            }
        }
    }
}

lazy_static::lazy_static! {
    static ref SUPPRESS: Arc<Mutex<Instant>> = Arc::new(Mutex::new(Instant::now()));
}

pub fn desktop_changed() -> bool {
    unsafe { inputDesktopSelected() == FALSE }
}

pub fn try_change_desktop() -> bool {
    unsafe {
        if inputDesktopSelected() == FALSE {
            let res = selectInputDesktop() == TRUE;
            if !res {
                let mut s = SUPPRESS.lock().unwrap();
                if s.elapsed() > std::time::Duration::from_secs(3) {
                    log::error!("Failed to switch desktop: {}", io::Error::last_os_error());
                    *s = Instant::now();
                }
            } else {
                log::info!("Desktop switched");
            }
            return res;
        }
    }
    return false;
}

fn share_rdp() -> BOOL {
    if get_reg("share_rdp") != "false" {
        TRUE
    } else {
        FALSE
    }
}

pub fn is_share_rdp() -> bool {
    share_rdp() == TRUE
}

pub fn set_share_rdp(enable: bool) {
    let (subkey, _, _, _) = get_install_info();
    let cmd = format!(
        "reg add {} /f /v share_rdp /t REG_SZ /d \"{}\"",
        subkey,
        if enable { "true" } else { "false" }
    );
    run_cmds(cmd, false, "share_rdp").ok();
}

pub fn get_current_process_session_id() -> Option<u32> {
    get_session_id_of_process(unsafe { GetCurrentProcessId() })
}

pub fn get_session_id_of_process(pid: DWORD) -> Option<u32> {
    let mut sid = 0;
    if unsafe { ProcessIdToSessionId(pid, &mut sid) == TRUE } {
        Some(sid)
    } else {
        None
    }
}

pub fn is_physical_console_session() -> Option<bool> {
    if let Some(sid) = get_current_process_session_id() {
        let physical_console_session_id = unsafe { get_current_session(FALSE) };
        if physical_console_session_id == u32::MAX {
            return None;
        }
        return Some(physical_console_session_id == sid);
    }
    None
}

pub fn get_active_username() -> String {
    // get_active_user will give console username higher priority
    if let Some(name) = get_current_session_username() {
        return name;
    }
    if !is_root() {
        return crate::username();
    }

    extern "C" {
        fn get_active_user(path: *mut u16, n: u32, rdp: BOOL) -> u32;
    }
    let buff_size = 256;
    let mut buff: Vec<u16> = Vec::with_capacity(buff_size);
    buff.resize(buff_size, 0);
    let n = unsafe { get_active_user(buff.as_mut_ptr(), buff_size as _, share_rdp()) };
    if n == 0 {
        return "".to_owned();
    }
    let sl = unsafe { std::slice::from_raw_parts(buff.as_ptr(), n as _) };
    String::from_utf16(sl)
        .unwrap_or("??".to_owned())
        .trim_end_matches('\0')
        .to_owned()
}

fn get_current_session_username() -> Option<String> {
    let Some(sid) = get_current_process_session_id() else {
        log::error!("get_current_process_session_id failed");
        return None;
    };
    Some(get_session_username(sid))
}

fn get_session_username(session_id: u32) -> String {
    extern "C" {
        fn get_session_user_info(path: *mut u16, n: u32, session_id: u32) -> u32;
    }
    let buff_size = 256;
    let mut buff: Vec<u16> = Vec::with_capacity(buff_size);
    buff.resize(buff_size, 0);
    let n = unsafe { get_session_user_info(buff.as_mut_ptr(), buff_size as _, session_id) };
    if n == 0 {
        return "".to_owned();
    }
    let sl = unsafe { std::slice::from_raw_parts(buff.as_ptr(), n as _) };
    String::from_utf16(sl)
        .unwrap_or("".to_owned())
        .trim_end_matches('\0')
        .to_owned()
}

pub fn get_available_sessions(name: bool) -> Vec<WindowsSession> {
    extern "C" {
        fn get_available_session_ids(buf: *mut wchar_t, buf_size: c_int, include_rdp: bool);
    }
    const BUF_SIZE: c_int = 1024;
    let mut buf: Vec<wchar_t> = vec![0; BUF_SIZE as usize];

    let station_session_id_array = unsafe {
        get_available_session_ids(buf.as_mut_ptr(), BUF_SIZE, true);
        let session_ids = String::from_utf16_lossy(&buf);
        session_ids.trim_matches(char::from(0)).trim().to_string()
    };
    let mut v: Vec<WindowsSession> = vec![];
    // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-wtsgetactiveconsolesessionid
    let physical_console_sid = unsafe { get_current_session(FALSE) };
    if physical_console_sid != u32::MAX {
        let physical_console_name = if name {
            let physical_console_username = get_session_username(physical_console_sid);
            if physical_console_username.is_empty() {
                "Console".to_owned()
            } else {
                format!("Console: {physical_console_username}")
            }
        } else {
            "".to_owned()
        };
        v.push(WindowsSession {
            sid: physical_console_sid,
            name: physical_console_name,
            ..Default::default()
        });
    }
    // https://learn.microsoft.com/en-us/previous-versions//cc722458(v=technet.10)?redirectedfrom=MSDN
    for type_session_id in station_session_id_array.split(",") {
        let split: Vec<_> = type_session_id.split(":").collect();
        if split.len() == 2 {
            if let Ok(sid) = split[1].parse::<u32>() {
                if !v.iter().any(|e| (*e).sid == sid) {
                    let name = if name {
                        let name = get_session_username(sid);
                        if name.is_empty() {
                            split[0].to_string()
                        } else {
                            format!("{}: {}", split[0], name)
                        }
                    } else {
                        "".to_owned()
                    };
                    v.push(WindowsSession {
                        sid,
                        name,
                        ..Default::default()
                    });
                }
            }
        }
    }
    if name {
        let mut name_count: HashMap<String, usize> = HashMap::new();
        for session in &v {
            *name_count.entry(session.name.clone()).or_insert(0) += 1;
        }
        let current_sid = get_current_process_session_id().unwrap_or_default();
        for e in v.iter_mut() {
            let running = e.sid == current_sid && current_sid != 0;
            if name_count.get(&e.name).map(|v| *v).unwrap_or_default() > 1 {
                e.name = format!("{} (sid = {})", e.name, e.sid);
            }
            if running {
                e.name = format!("{} (running)", e.name);
            }
        }
    }
    v
}

pub fn get_active_user_home() -> Option<PathBuf> {
    let username = get_active_username();
    if !username.is_empty() {
        let drive = std::env::var("SystemDrive").unwrap_or("C:".to_owned());
        let home = PathBuf::from(format!("{}\\Users\\{}", drive, username));
        if home.exists() {
            return Some(home);
        }
    }
    None
}

#[cfg(not(feature = "flutter"))]
#[inline]
pub fn portable_service_logon_helper_paths() -> Option<(PathBuf, PathBuf)> {
    // Keep parity with history for now: derive LocalAppData from user profile path.
    // If users report redirected/non-standard LocalAppData issues, switch to:
    // `BaseDirs::new()?.data_local_dir()` for Known Folder-based resolution.
    let user_dir = hbb_common::directories_next::UserDirs::new()?;
    let dir = user_dir
        .home_dir()
        .join("AppData")
        .join("Local")
        .join("rustdesk-sciter");
    let dst = dir.join("rustdesk.exe");
    Some((dir, dst))
}

pub fn is_prelogin() -> bool {
    let Some(username) = get_current_session_username() else {
        return false;
    };
    username.is_empty() || username == "SYSTEM"
}

pub fn is_locked() -> bool {
    let Some(session_id) = get_current_process_session_id() else {
        return false;
    };
    unsafe { is_session_locked(session_id) == TRUE }
}

#[inline]
pub fn is_logon_ui() -> ResultType<bool> {
    let Some(current_sid) = get_current_process_session_id() else {
        return Ok(false);
    };
    let pids = get_pids("LogonUI.exe")?;
    Ok(pids
        .into_iter()
        .any(|pid| get_session_id_of_process(pid) == Some(current_sid)))
}

pub fn is_root() -> bool {
    // https://stackoverflow.com/questions/4023586/correct-way-to-find-out-if-a-service-is-running-as-the-system-user
    unsafe { is_local_system() == TRUE }
}

pub fn lock_screen() {
    extern "system" {
        pub fn LockWorkStation() -> BOOL;
    }
    unsafe {
        LockWorkStation();
    }
}

const IS1: &str = "{54E86BC2-6C85-41F3-A9EB-1A94AC9B1F93}_is1";

fn get_subkey(name: &str, wow: bool) -> String {
    let tmp = format!(
        "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{}",
        name
    );
    if wow {
        tmp.replace("Microsoft", "Wow6432Node\\Microsoft")
    } else {
        tmp
    }
}

fn get_valid_subkey() -> String {
    let subkey = get_subkey(IS1, false);
    if !get_reg_of(&subkey, "InstallLocation").is_empty() {
        return subkey;
    }
    let subkey = get_subkey(IS1, true);
    if !get_reg_of(&subkey, "InstallLocation").is_empty() {
        return subkey;
    }
    let app_name = crate::get_app_name();
    let subkey = get_subkey(&app_name, true);
    if !get_reg_of(&subkey, "InstallLocation").is_empty() {
        return subkey;
    }
    return get_subkey(&app_name, false);
}

// Return install options other than InstallLocation.
pub fn get_install_options() -> String {
    let app_name = crate::get_app_name();
    let subkey = format!(".{}", app_name.to_lowercase());
    let mut opts = HashMap::new();

    let desktop_shortcuts = get_reg_of_hkcr(&subkey, REG_NAME_INSTALL_DESKTOPSHORTCUTS);
    if let Some(desktop_shortcuts) = desktop_shortcuts {
        opts.insert(REG_NAME_INSTALL_DESKTOPSHORTCUTS, desktop_shortcuts);
    }
    let start_menu_shortcuts = get_reg_of_hkcr(&subkey, REG_NAME_INSTALL_STARTMENUSHORTCUTS);
    if let Some(start_menu_shortcuts) = start_menu_shortcuts {
        opts.insert(REG_NAME_INSTALL_STARTMENUSHORTCUTS, start_menu_shortcuts);
    }
    let printer = get_reg_of_hkcr(&subkey, REG_NAME_INSTALL_PRINTER);
    if let Some(printer) = printer {
        opts.insert(REG_NAME_INSTALL_PRINTER, printer);
    }
    serde_json::to_string(&opts).unwrap_or("{}".to_owned())
}

pub fn get_silent_install_options(printer_override: Option<bool>) -> &'static str {
    let install_printer = match printer_override {
        Some(override_value) => override_value,
        None => {
            let app_name = crate::get_app_name();
            let subkey = format!(".{}", app_name.to_lowercase());
            let printer = get_reg_of_hkcr(&subkey, REG_NAME_INSTALL_PRINTER);
            printer.as_deref() == Some("1")
        }
    };
    if install_printer && is_win_10_or_greater() {
        "desktopicon startmenu printer"
    } else {
        "desktopicon startmenu"
    }
}

// This function return Option<String>, because some registry value may be empty.
fn get_reg_of_hkcr(subkey: &str, name: &str) -> Option<String> {
    let hkcr = RegKey::predef(HKEY_CLASSES_ROOT);
    if let Ok(tmp) = hkcr.open_subkey(subkey.replace("HKEY_CLASSES_ROOT\\", "")) {
        return tmp.get_value(name).ok();
    }
    None
}

pub fn get_install_info() -> (String, String, String, String) {
    get_install_info_with_subkey(get_valid_subkey())
}

fn application_display_version() -> String {
    if crate::common::is_custom_client() {
        crate::custom_defaults::build_display_version()
    } else {
        crate::VERSION.replace("-", ".")
    }
}

fn get_default_install_info() -> (String, String, String, String) {
    get_install_info_with_subkey(get_subkey(&crate::get_app_name(), false))
}

fn get_default_install_path() -> String {
    let mut pf = "C:\\Program Files".to_owned();
    if let Ok(x) = std::env::var("ProgramFiles") {
        if std::path::Path::new(&x).exists() {
            pf = x;
        }
    }
    #[cfg(target_pointer_width = "32")]
    {
        let tmp = pf.replace("Program Files", "Program Files (x86)");
        if std::path::Path::new(&tmp).exists() {
            pf = tmp;
        }
    }
    format!("{}\\{}", pf, crate::get_app_name())
}

pub fn check_update_broker_process() -> ResultType<()> {
    let process_exe = win_topmost_window::INJECTED_PROCESS_EXE;
    let origin_process_exe = win_topmost_window::ORIGIN_PROCESS_EXE;

    let exe_file = std::env::current_exe()?;
    let Some(cur_dir) = exe_file.parent() else {
        bail!("Cannot get parent of current exe file");
    };
    let cur_exe = cur_dir.join(process_exe);

    // Force update broker exe if failed to check modified time.
    let cmds = format!(
        "
        chcp 65001
        taskkill /F /IM {process_exe}
        copy /Y \"{origin_process_exe}\" \"{cur_exe}\"
    ",
        cur_exe = cur_exe.to_string_lossy(),
    );

    if !std::path::Path::new(&cur_exe).exists() {
        run_cmds(cmds, false, "update_broker")?;
        return Ok(());
    }

    let ori_modified = fs::metadata(origin_process_exe)?.modified()?;
    if let Ok(metadata) = fs::metadata(&cur_exe) {
        if let Ok(cur_modified) = metadata.modified() {
            if cur_modified == ori_modified {
                return Ok(());
            } else {
                log::info!(
                    "broker process updated, modify time from {:?} to {:?}",
                    cur_modified,
                    ori_modified
                );
            }
        }
    }

    run_cmds(cmds, false, "update_broker")?;

    Ok(())
}

fn get_install_info_with_subkey(subkey: String) -> (String, String, String, String) {
    let mut path = get_reg_of(&subkey, "InstallLocation");
    if path.is_empty() {
        path = get_default_install_path();
    }
    path = path.trim_end_matches('\\').to_owned();
    let start_menu = format!(
        "%ProgramData%\\Microsoft\\Windows\\Start Menu\\Programs\\{}",
        crate::get_app_name()
    );
    let exe = format!("{}\\{}.exe", path, crate::get_app_name());
    (subkey, path, start_menu, exe)
}

pub fn copy_raw_cmd(src_raw: &str, _raw: &str, _path: &str) -> ResultType<String> {
    copy_raw_cmd_with_failure(src_raw, _raw, _path, "exit /b 1", "")
}

fn copy_raw_cmd_with_failure(
    src_raw: &str,
    _raw: &str,
    _path: &str,
    failure_cmd: &str,
    output_redirection: &str,
) -> ResultType<String> {
    let source_dir = PathBuf::from(src_raw)
        .parent()
        .ok_or(anyhow!("Can't get parent directory of {src_raw}"))?
        .to_string_lossy()
        .to_string();
    let runtime_checks = |root: &str| {
        if cfg!(feature = "flutter") {
            format!(
                r#"if not exist "{root}\flutter_windows.dll" (set "MASTERDESK_UPDATE_ERROR=2" & {failure_cmd})
if not exist "{root}\libmasterdesk.dll" (set "MASTERDESK_UPDATE_ERROR=2" & {failure_cmd})
if not exist "{root}\data\app.so" (set "MASTERDESK_UPDATE_ERROR=2" & {failure_cmd})
if not exist "{root}\data\icudtl.dat" (set "MASTERDESK_UPDATE_ERROR=2" & {failure_cmd})
if not exist "{root}\data\flutter_assets\AssetManifest.bin" (set "MASTERDESK_UPDATE_ERROR=2" & {failure_cmd})"#
            )
        } else {
            String::new()
        }
    };
    let main_raw = format!(
        r#"{source_checks}
set "MASTERDESK_COPY_OK="
for /L %%I in (1,1,15) do (
    XCOPY "{source_dir}" "{_path}" /Y /E /H /I /K /R /Z {output_redirection}
    if not errorlevel 1 (
        set "MASTERDESK_COPY_OK=1"
        goto masterdesk_copy_complete
    )
    ping 127.0.0.1 -n 2 >nul
)
:masterdesk_copy_complete
if not defined MASTERDESK_COPY_OK (
    set "MASTERDESK_UPDATE_ERROR=1"
    {failure_cmd}
)
{destination_checks}"#,
        source_checks = runtime_checks(&source_dir),
        destination_checks = runtime_checks(_path),
    );
    return Ok(main_raw);
}

fn wait_for_application_exit_cmd(app_name: &str, filter: &str, label: &str) -> String {
    format!(
        r#"
for /L %%I in (1,1,20) do (
    tasklist /FI "IMAGENAME eq {app_name}.exe"{filter} /NH | find /I "{app_name}.exe" >nul
    if errorlevel 1 goto masterdesk_{label}_processes_stopped
    taskkill /F /IM {app_name}.exe{filter} >nul 2>&1
    ping 127.0.0.1 -n 2 >nul
)
tasklist /FI "IMAGENAME eq {app_name}.exe"{filter} /NH | find /I "{app_name}.exe" >nul
if not errorlevel 1 exit /b 1
:masterdesk_{label}_processes_stopped
"#
    )
}

fn wait_for_service_stop_cmd(app_name: &str) -> String {
    format!(
        r#"
 powershell.exe -NoProfile -NonInteractive -Command "$service = Get-Service -Name '{app_name}' -ErrorAction SilentlyContinue; if ($null -eq $service) {{ exit 0 }}; $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)); if ($service.Status -ne 'Stopped') {{ exit 1 }}; exit 0"
if errorlevel 1 exit /b 1
"#
    )
}

fn powershell_single_quoted(value: &str) -> String {
    value.replace('\'', "''")
}

fn wait_for_update_service_stop_cmd(app_name: &str, failure_label: &str) -> String {
    let service_name = powershell_single_quoted(app_name);
    format!(
        r#"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$name = '{service_name}'; $deadline = [DateTime]::UtcNow.AddSeconds(10); do {{ $service = Get-Service -Name $name -ErrorAction SilentlyContinue; if ($null -eq $service -or $service.Status -eq 'Stopped') {{ exit 0 }}; Start-Sleep -Milliseconds 500 }} while ([DateTime]::UtcNow -lt $deadline); $instance = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object Name -eq $name | Select-Object -First 1; if ($null -ne $instance) {{ $servicePid = [uint32]$instance.ProcessId; if ($servicePid -gt 0) {{ Write-Output ('Graceful service stop timed out; terminating service process tree PID ' + $servicePid); taskkill.exe /F /T /PID $servicePid | Out-Null }} }}; $deadline = [DateTime]::UtcNow.AddSeconds(30); do {{ $service = Get-Service -Name $name -ErrorAction SilentlyContinue; if ($null -eq $service -or $service.Status -eq 'Stopped') {{ exit 0 }}; Start-Sleep -Milliseconds 500 }} while ([DateTime]::UtcNow -lt $deadline); Write-Error ('Service did not reach Stopped state: ' + $name); exit 1" >> "%MASTERDESK_UPDATE_LOG%" 2>&1
if errorlevel 1 goto {failure_label}
"#
    )
}

fn wait_for_installed_application_exit_cmd(app_name: &str, installed_exe: &str) -> String {
    let process_name = powershell_single_quoted(&format!("{app_name}.exe"));
    let installed_exe = powershell_single_quoted(installed_exe);
    format!(
        r#"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$name = '{process_name}'; $target = [IO.Path]::GetFullPath('{installed_exe}'); $deadline = [DateTime]::UtcNow.AddSeconds(5); do {{ $remaining = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -ieq $name -and $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq $target) }}); foreach ($process in $remaining) {{ Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }}; if ($remaining.Count -eq 0) {{ exit 0 }}; Start-Sleep -Milliseconds 500 }} while ([DateTime]::UtcNow -lt $deadline); $remaining = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -ieq $name -and $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq $target) }}); if ($remaining.Count -gt 0) {{ Write-Output ('Warning: WMI still reports the installed application after termination attempts; the copy and SHA-256 verification stages will determine whether files are available: ' + $target); $remaining | Select-Object ProcessId, ParentProcessId, SessionId, ExecutablePath | Format-List }}; exit 0" >> "%MASTERDESK_UPDATE_LOG%" 2>&1
"#
    )
}

fn verify_update_runtime_copy_cmd(
    source_exe: &str,
    installed_exe: &str,
    source_root: &str,
    installed_root: &str,
    failure_label: &str,
) -> String {
    let source_exe = powershell_single_quoted(source_exe);
    let installed_exe = powershell_single_quoted(installed_exe);
    let source_root = powershell_single_quoted(source_root);
    let installed_root = powershell_single_quoted(installed_root);
    format!(
        r#"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$sourceExe = '{source_exe}'; $installedExe = '{installed_exe}'; $sourceRoot = '{source_root}'; $installedRoot = '{installed_root}'; $relativeFiles = @('flutter_windows.dll', 'libmasterdesk.dll', 'data\app.so', 'data\icudtl.dat', 'data\masterdesk-build-manifest.json', 'data\flutter_assets\AssetManifest.bin', 'data\flutter_assets\FontManifest.json'); if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf) -or -not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {{ Write-Error ('Missing executable while verifying update copy: ' + $installedExe); exit 1 }}; if ((Get-FileHash -Algorithm SHA256 -LiteralPath $sourceExe).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $installedExe).Hash) {{ Write-Error ('SHA-256 mismatch after update copy: ' + $installedExe); exit 1 }}; foreach ($relative in $relativeFiles) {{ $source = Join-Path $sourceRoot $relative; $installed = Join-Path $installedRoot $relative; if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-Path -LiteralPath $installed -PathType Leaf)) {{ Write-Error ('Missing runtime file while verifying update copy: ' + $relative); exit 1 }}; if ((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $installed).Hash) {{ Write-Error ('SHA-256 mismatch after update copy: ' + $relative); exit 1 }} }}; Write-Output 'Copied runtime SHA-256 verification passed'; exit 0" >> "%MASTERDESK_UPDATE_LOG%" 2>&1
if errorlevel 1 goto {failure_label}
"#
    )
}

fn wait_for_process_exit_cmd(app_name: &str, pid: u32, label: &str) -> String {
    format!(
        r#"
for /L %%I in (1,1,30) do (
    tasklist /FI "PID eq {pid}" /NH | find /I "{app_name}.exe" >nul
    if errorlevel 1 goto masterdesk_{label}_launcher_stopped
    ping 127.0.0.1 -n 2 >nul
)
exit /b 1
:masterdesk_{label}_launcher_stopped
"#
    )
}

fn detached_batch_launcher(batch_path: &Path) -> String {
    format!(
        r#"start "" /B cmd.exe /D /C call "{}""#,
        batch_path.to_string_lossy()
    )
}

pub fn copy_exe_cmd(src_exe: &str, exe: &str, path: &str) -> ResultType<String> {
    copy_exe_cmd_with_failure(src_exe, exe, path, "exit /b 1", "")
}

fn copy_exe_cmd_with_failure(
    src_exe: &str,
    exe: &str,
    path: &str,
    failure_cmd: &str,
    output_redirection: &str,
) -> ResultType<String> {
    let main_exe = copy_raw_cmd_with_failure(src_exe, exe, path, failure_cmd, output_redirection)?;
    Ok(format!(
        "
        {main_exe}
        copy /Y \"{ORIGIN_PROCESS_EXE}\" \"{path}\\{broker_exe}\"
        ",
        ORIGIN_PROCESS_EXE = win_topmost_window::ORIGIN_PROCESS_EXE,
        broker_exe = win_topmost_window::INJECTED_PROCESS_EXE,
    ))
}

#[inline]
pub fn rename_exe_cmd(src_exe: &str, path: &str) -> ResultType<String> {
    let src_exe_filename = PathBuf::from(src_exe)
        .file_name()
        .ok_or(anyhow!("Can't get file name of {src_exe}"))?
        .to_string_lossy()
        .to_string();
    let app_name = crate::get_app_name().to_lowercase();
    if src_exe_filename.to_lowercase() == format!("{app_name}.exe") {
        Ok("".to_owned())
    } else {
        Ok(format!(
            "
        move /Y \"{path}\\{src_exe_filename}\" \"{path}\\{app_name}.exe\"
        ",
        ))
    }
}

#[inline]
pub fn remove_meta_toml_cmd(is_msi: bool, path: &str) -> String {
    if is_msi && crate::is_custom_client() {
        format!(
            "
        del /F /Q \"{path}\\meta.toml\"
        ",
        )
    } else {
        "".to_owned()
    }
}

fn get_after_install(
    exe: &str,
    reg_value_start_menu_shortcuts: Option<String>,
    reg_value_desktop_shortcuts: Option<String>,
    reg_value_printer: Option<String>,
) -> String {
    let app_name = crate::get_app_name();
    let ext = app_name.to_lowercase();

    // reg delete HKEY_CURRENT_USER\Software\Classes for
    // https://github.com/rustdesk/rustdesk/commit/f4bdfb6936ae4804fc8ab1cf560db192622ad01a
    // and https://github.com/leanflutter/uni_links_desktop/blob/1b72b0226cec9943ca8a84e244c149773f384e46/lib/src/protocol_registrar_impl_windows.dart#L30
    let hcu = RegKey::predef(HKEY_CURRENT_USER);
    hcu.delete_subkey_all(format!("Software\\Classes\\{}", exe))
        .ok();

    let desktop_shortcuts = reg_value_desktop_shortcuts
        .map(|v| {
            format!("reg add HKEY_CLASSES_ROOT\\.{ext} /f /v {REG_NAME_INSTALL_DESKTOPSHORTCUTS} /t REG_SZ /d \"{v}\"")
        })
        .unwrap_or_default();
    let start_menu_shortcuts = reg_value_start_menu_shortcuts
        .map(|v| {
            format!(
                "reg add HKEY_CLASSES_ROOT\\.{ext} /f /v {REG_NAME_INSTALL_STARTMENUSHORTCUTS} /t REG_SZ /d \"{v}\""
            )
        })
        .unwrap_or_default();
    let reg_printer = reg_value_printer
        .map(|v| {
            format!(
                "reg add HKEY_CLASSES_ROOT\\.{ext} /f /v {REG_NAME_INSTALL_PRINTER} /t REG_SZ /d \"{v}\""
            )
        })
        .unwrap_or_default();

    format!("
    chcp 65001
    reg add HKEY_CLASSES_ROOT\\.{ext} /f
    {desktop_shortcuts}
    {start_menu_shortcuts}
    {reg_printer}
    reg add HKEY_CLASSES_ROOT\\.{ext}\\DefaultIcon /f
    reg add HKEY_CLASSES_ROOT\\.{ext}\\DefaultIcon /f /ve /t REG_SZ  /d \"\\\"{exe}\\\",0\"
    reg add HKEY_CLASSES_ROOT\\.{ext}\\shell /f
    reg add HKEY_CLASSES_ROOT\\.{ext}\\shell\\open /f
    reg add HKEY_CLASSES_ROOT\\.{ext}\\shell\\open\\command /f
    reg add HKEY_CLASSES_ROOT\\.{ext}\\shell\\open\\command /f /ve /t REG_SZ /d \"\\\"{exe}\\\" --play \\\"%%1\\\"\"
    reg add HKEY_CLASSES_ROOT\\{ext} /f
    reg add HKEY_CLASSES_ROOT\\{ext} /f /v \"URL Protocol\" /t REG_SZ /d \"\"
    reg add HKEY_CLASSES_ROOT\\{ext}\\shell /f
    reg add HKEY_CLASSES_ROOT\\{ext}\\shell\\open /f
    reg add HKEY_CLASSES_ROOT\\{ext}\\shell\\open\\command /f
    reg add HKEY_CLASSES_ROOT\\{ext}\\shell\\open\\command /f /ve /t REG_SZ /d \"\\\"{exe}\\\" \\\"%%1\\\"\"
    netsh advfirewall firewall add rule name=\"{app_name} Service\" dir=out action=allow program=\"{exe}\" enable=yes
    netsh advfirewall firewall add rule name=\"{app_name} Service\" dir=in action=allow program=\"{exe}\" enable=yes
    {create_service}
    reg add HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System /f /v SoftwareSASGeneration /t REG_DWORD /d 1
    ", create_service=get_create_service(&exe))
}

pub fn install_me(options: &str, path: String, silent: bool, debug: bool) -> ResultType<()> {
    clear_stale_stop_service_for_portable();
    let uninstall_str = get_uninstall(false, false, false);
    let mut path = path.trim_end_matches('\\').to_owned();
    let (subkey, _path, start_menu, exe) = get_default_install_info();
    let mut exe = exe;
    if path.is_empty() {
        path = _path;
    } else {
        exe = exe.replace(&_path, &path);
    }
    let mut version_major = "0";
    let mut version_minor = "0";
    let mut version_build = "0";
    let versions: Vec<&str> = crate::VERSION.split(".").collect();
    if versions.len() > 0 {
        version_major = versions[0];
    }
    if versions.len() > 1 {
        version_minor = versions[1];
    }
    if versions.len() > 2 {
        version_build = versions[2];
    }
    let app_name = crate::get_app_name();

    let current_exe = std::env::current_exe()?;

    let tmp_path = std::env::temp_dir().to_string_lossy().to_string();
    let cur_exe = current_exe.to_str().unwrap_or("").to_owned();
    let shortcut_icon_location = get_shortcut_icon_location(&path, &cur_exe);
    let mk_shortcut = write_cmds(
        format!(
            "
Set oWS = WScript.CreateObject(\"WScript.Shell\")
sLinkFile = \"{tmp_path}\\{app_name}.lnk\"

Set oLink = oWS.CreateShortcut(sLinkFile)
    oLink.TargetPath = \"{exe}\"
    {shortcut_icon_location}
oLink.Save
        "
        ),
        "vbs",
        "mk_shortcut",
    )?
    .to_str()
    .unwrap_or("")
    .to_owned();
    // https://superuser.com/questions/392061/how-to-make-a-shortcut-from-cmd
    let uninstall_shortcut = write_cmds(
        format!(
            "
Set oWS = WScript.CreateObject(\"WScript.Shell\")
sLinkFile = \"{tmp_path}\\Uninstall {app_name}.lnk\"
Set oLink = oWS.CreateShortcut(sLinkFile)
    oLink.TargetPath = \"{exe}\"
    oLink.Arguments = \"--uninstall\"
    oLink.IconLocation = \"msiexec.exe\"
oLink.Save
        "
        ),
        "vbs",
        "uninstall_shortcut",
    )?
    .to_str()
    .unwrap_or("")
    .to_owned();
    let tray_shortcut = get_tray_shortcut(&path, &exe, &cur_exe, &tmp_path)?;
    let mut reg_value_desktop_shortcuts = "0".to_owned();
    let mut reg_value_start_menu_shortcuts = "0".to_owned();
    let mut reg_value_printer = "0".to_owned();
    let mut shortcuts = Default::default();
    if options.contains("desktopicon") {
        shortcuts = format!(
            "copy /Y \"{}\\{}.lnk\" \"%PUBLIC%\\Desktop\\\"",
            tmp_path,
            crate::get_app_name()
        );
        reg_value_desktop_shortcuts = "1".to_owned();
    }
    if options.contains("startmenu") {
        shortcuts = format!(
            "{shortcuts}
md \"{start_menu}\"
copy /Y \"{tmp_path}\\{app_name}.lnk\" \"{start_menu}\\\"
copy /Y \"{tmp_path}\\Uninstall {app_name}.lnk\" \"{start_menu}\\\"
     "
        );
        reg_value_start_menu_shortcuts = "1".to_owned();
    }
    let install_printer = options.contains("printer") && is_win_10_or_greater();
    if install_printer {
        reg_value_printer = "1".to_owned();
    }

    let meta = std::fs::symlink_metadata(&current_exe)?;
    let mut size = meta.len() / 1024;
    if let Some(parent_dir) = current_exe.parent() {
        if let Some(d) = parent_dir.to_str() {
            size = get_directory_size_kb(d);
        }
    }
    // https://docs.microsoft.com/zh-cn/windows/win32/msi/uninstall-registry-key?redirectedfrom=MSDNa
    // https://www.windowscentral.com/how-edit-registry-using-command-prompt-windows-10
    // https://www.tenforums.com/tutorials/70903-add-remove-allowed-apps-through-windows-firewall-windows-10-a.html
    // Note: without if exist, the bat may exit in advance on some Windows7 https://github.com/rustdesk/rustdesk/issues/895
    let dels = format!(
        "
if exist \"{mk_shortcut}\" del /f /q \"{mk_shortcut}\"
if exist \"{uninstall_shortcut}\" del /f /q \"{uninstall_shortcut}\"
if exist \"{tray_shortcut}\" del /f /q \"{tray_shortcut}\"
if exist \"{tmp_path}\\{app_name}.lnk\" del /f /q \"{tmp_path}\\{app_name}.lnk\"
if exist \"{tmp_path}\\Uninstall {app_name}.lnk\" del /f /q \"{tmp_path}\\Uninstall {app_name}.lnk\"
if exist \"{tmp_path}\\{app_name} Tray.lnk\" del /f /q \"{tmp_path}\\{app_name} Tray.lnk\"
        "
    );
    let src_exe = std::env::current_exe()?.to_str().unwrap_or("").to_string();

    // potential bug here: if run_cmd cancelled, but config file is changed.
    if let Some(lic) = get_license() {
        Config::set_option("key".into(), lic.key);
        Config::set_option("custom-rendezvous-server".into(), lic.host);
        Config::set_option("api-server".into(), lic.api);
    }

    let tray_shortcuts = if config::is_outgoing_only() {
        "".to_owned()
    } else {
        format!("
cscript \"{tray_shortcut}\"
copy /Y \"{tmp_path}\\{app_name} Tray.lnk\" \"%PROGRAMDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\\"
")
    };

    let install_remote_printer = if install_printer {
        // No need to use `|| true` here.
        // The script will not exit even if `--install-remote-printer` panics.
        format!("\"{}\" --install-remote-printer", &src_exe)
    } else if is_win_10_or_greater() {
        format!("\"{}\" --uninstall-remote-printer", &src_exe)
    } else {
        "".to_owned()
    };

    // Remember to check if `update_me` need to be changed if changing the `cmds`.
    // No need to merge the existing dup code, because the code in these two functions are too critical.
    // New code should be written in a common function.
    let cmds = format!(
        "
{uninstall_str}
chcp 65001
md \"{path}\"
{copy_exe}
{rename_exe}
reg add {subkey} /f
reg add {subkey} /f /v DisplayIcon /t REG_SZ /d \"{display_icon}\"
reg add {subkey} /f /v DisplayName /t REG_SZ /d \"{app_name}\"
reg add {subkey} /f /v DisplayVersion /t REG_SZ /d \"{version}\"
reg add {subkey} /f /v Version /t REG_SZ /d \"{version}\"
reg add {subkey} /f /v BuildDate /t REG_SZ /d \"{build_date}\"
reg add {subkey} /f /v InstallLocation /t REG_SZ /d \"{path}\"
reg add {subkey} /f /v Publisher /t REG_SZ /d \"{app_name}\"
reg add {subkey} /f /v VersionMajor /t REG_DWORD /d {version_major}
reg add {subkey} /f /v VersionMinor /t REG_DWORD /d {version_minor}
reg add {subkey} /f /v VersionBuild /t REG_DWORD /d {version_build}
reg add {subkey} /f /v UninstallString /t REG_SZ /d \"\\\"{exe}\\\" --uninstall\"
reg add {subkey} /f /v EstimatedSize /t REG_DWORD /d {size}
reg add {subkey} /f /v WindowsInstaller /t REG_DWORD /d 0
cscript \"{mk_shortcut}\"
cscript \"{uninstall_shortcut}\"
{tray_shortcuts}
{shortcuts}
copy /Y \"{tmp_path}\\Uninstall {app_name}.lnk\" \"{path}\\\"
{dels}
{import_config}
{after_install}
{install_remote_printer}
{sleep}
    ",
        display_icon = get_custom_icon(&path, &cur_exe).unwrap_or(exe.to_string()),
        version = application_display_version(),
        build_date = crate::custom_defaults::CUSTOM_BUILD_DATE,
        after_install = get_after_install(
            &exe,
            Some(reg_value_start_menu_shortcuts),
            Some(reg_value_desktop_shortcuts),
            Some(reg_value_printer)
        ),
        sleep = if debug { "timeout 300" } else { "" },
        dels = if debug { "" } else { &dels },
        copy_exe = copy_exe_cmd(&src_exe, &exe, &path)?,
        rename_exe = rename_exe_cmd(&src_exe, &path)?,
        import_config = get_import_config(&exe),
    );
    run_cmds(cmds, debug, "install")?;
    let exit_portable_after_install = !is_cur_exe_the_installed();
    run_after_run_cmds(silent, exit_portable_after_install);
    if exit_portable_after_install {
        // The portable GUI owns the main IPC pipe while installation is in
        // progress. Keeping it alive makes the newly installed service and GUI
        // fail the executable-identity check, leaving only background
        // processes and no usable window. The delayed installed-app launch is
        // already scheduled by `run_after_run_cmds`, so release the portable
        // IPC owner before that launch occurs.
        log::info!("Installation completed; exiting the portable IPC owner.");
        std::process::exit(0);
    }
    Ok(())
}

pub fn run_after_install() -> ResultType<()> {
    let (_, _, _, exe) = get_install_info();
    run_cmds(
        get_after_install(&exe, None, None, None),
        true,
        "after_install",
    )
}

pub fn run_before_uninstall() -> ResultType<()> {
    Config::set_option("stop-service".into(), "".into());
    run_cmds(get_before_uninstall(true), true, "before_install")
}

fn get_before_uninstall(kill_self: bool) -> String {
    let app_name = crate::get_app_name();
    let ext = app_name.to_lowercase();
    let current_pid = get_current_pid();
    let filter = if kill_self {
        "".to_string()
    } else {
        format!(" /FI \"PID ne {}\"", current_pid)
    };
    let other_process_filter = format!(" /FI \"PID ne {}\"", current_pid);
    let kill_current = if kill_self {
        format!("taskkill /F /PID {current_pid} >nul 2>&1")
    } else {
        String::new()
    };
    let wait_for_service = wait_for_service_stop_cmd(&app_name);
    let wait_for_processes = wait_for_application_exit_cmd(&app_name, &filter, "uninstall");
    format!(
        "
    chcp 65001
    sc config {app_name} start= disabled
    sc failure {app_name} reset= 0 actions= \"\"
    sc stop {app_name}
    {wait_for_service}
    sc delete {app_name}
    taskkill /F /IM {broker_exe}
    taskkill /F /T /IM {app_name}.exe{other_process_filter} >nul 2>&1
    {kill_current}
    {wait_for_processes}
    reg delete HKEY_CLASSES_ROOT\\.{ext} /f
    reg delete HKEY_CLASSES_ROOT\\{ext} /f
    netsh advfirewall firewall delete rule name=\"{app_name} Service\"
    ",
        broker_exe = WIN_TOPMOST_INJECTED_PROCESS_EXE,
    )
}

/// Constructs the uninstall command string for the application.
///
/// # Parameters
/// - `kill_self`: The command will kill the process of current app name. If `true`, it will kill
///   the current process as well. If `false`, it will exclude the current process from the kill
///   command.
/// - `uninstall_printer`: If `true`, includes commands to uninstall the remote printer.
///
/// # Details
/// The `uninstall_printer` parameter determines whether the command to uninstall the remote printer
/// is included in the generated uninstall script. If `uninstall_printer` is `false`, the printer
/// related command is omitted from the script.
fn get_uninstall(kill_self: bool, uninstall_printer: bool, delete_settings: bool) -> String {
    let reg_uninstall_string = get_reg("UninstallString");
    if reg_uninstall_string.to_lowercase().contains("msiexec.exe") {
        return reg_uninstall_string;
    }

    let mut uninstall_cert_cmd = "".to_string();
    let mut uninstall_printer_cmd = "".to_string();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_path) = exe.to_str() {
            uninstall_cert_cmd = format!("\"{}\" --uninstall-cert", exe_path);
            if uninstall_printer {
                uninstall_printer_cmd = format!("\"{}\" --uninstall-remote-printer", &exe_path);
            }
        }
    }
    let (subkey, path, start_menu, _) = get_install_info();
    let purge_settings_cmd = if delete_settings {
        std::env::current_exe()
            .ok()
            .and_then(|path| path.to_str().map(|path| path.to_owned()))
            .map(|path| {
                format!("\"{path}\" --purge-masterdesk-settings\nif errorlevel 1 exit /b 1")
            })
            .unwrap_or_default()
    } else {
        String::new()
    };
    format!(
        "
    {before_uninstall}
    {uninstall_printer_cmd}
    {uninstall_cert_cmd}
    {purge_settings_cmd}
    reg delete {subkey} /f
    {uninstall_amyuni_idd}
    if exist \"{path}\" rd /s /q \"{path}\"
    if exist \"{start_menu}\" rd /s /q \"{start_menu}\"
    if exist \"%PUBLIC%\\Desktop\\{app_name}.lnk\" del /f /q \"%PUBLIC%\\Desktop\\{app_name}.lnk\"
    if exist \"%PROGRAMDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\{app_name} Tray.lnk\" del /f /q \"%PROGRAMDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\{app_name} Tray.lnk\"
    ",
        before_uninstall=get_before_uninstall(kill_self),
        uninstall_amyuni_idd=get_uninstall_amyuni_idd(),
        app_name = crate::get_app_name(),
    )
}

pub fn uninstall_me(kill_self: bool, delete_settings: bool) -> ResultType<()> {
    Config::set_option("stop-service".into(), "".into());
    if !kill_self {
        return run_cmds(
            get_uninstall(false, true, delete_settings),
            true,
            "uninstall",
        );
    }

    let current_pid = get_current_pid();
    let cleanup = format!(
        "{}\n{}",
        wait_for_process_exit_cmd(&crate::get_app_name(), current_pid, "uninstall"),
        get_uninstall(true, true, delete_settings)
    );
    let cleanup_path = write_cmds(cleanup, "bat", "uninstall_cleanup")?;
    run_cmds(
        detached_batch_launcher(&cleanup_path),
        false,
        "uninstall_launcher",
    )
}

fn owned_masterdesk_state_path_is_safe(base: &Path, target: &Path, app_name: &str) -> bool {
    target
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.eq_ignore_ascii_case(app_name))
        .unwrap_or(false)
        && target.parent() == Some(base)
}

fn remove_owned_masterdesk_state_dir(base: &Path, app_name: &str) -> ResultType<bool> {
    let target = base.join(app_name);
    if !target.exists() {
        return Ok(false);
    }
    if !owned_masterdesk_state_path_is_safe(base, &target, app_name) {
        bail!(
            "Refusing unsafe MasterDesk state path: {}",
            target.display()
        );
    }

    let canonical_base = fs::canonicalize(base)?;
    let canonical_target = fs::canonicalize(&target)?;
    if canonical_target.parent() != Some(canonical_base.as_path()) {
        bail!(
            "Refusing reparse-point MasterDesk state path outside {}: {}",
            canonical_base.display(),
            canonical_target.display()
        );
    }
    if !fs::symlink_metadata(&target)?.is_dir() {
        bail!(
            "MasterDesk state path is not a directory: {}",
            target.display()
        );
    }

    fs::remove_dir_all(&target)?;
    if target.exists() {
        bail!(
            "MasterDesk state directory still exists: {}",
            target.display()
        );
    }
    log::info!("Removed MasterDesk state directory: {}", target.display());
    Ok(true)
}

pub fn purge_masterdesk_settings() -> ResultType<()> {
    let app_name = crate::get_app_name();
    if !app_name.eq_ignore_ascii_case("MasterDesk") {
        bail!("Refusing to purge settings for unexpected application {app_name}");
    }

    let mut bases = Vec::<PathBuf>::new();
    let config_path = Config::path("");
    if let Some(app_root) = config_path.parent() {
        if app_root
            .file_name()
            .and_then(|name| name.to_str())
            .map(|name| name.eq_ignore_ascii_case(&app_name))
            .unwrap_or(false)
        {
            if let Some(base) = app_root.parent() {
                bases.push(base.to_path_buf());
            }
        }
    }
    for variable in ["APPDATA", "LOCALAPPDATA", "PROGRAMDATA"] {
        if let Ok(value) = std::env::var(variable) {
            let base = PathBuf::from(value);
            if base.exists() && !bases.iter().any(|known| known == &base) {
                bases.push(base);
            }
        }
    }

    let system_root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_owned());
    for relative in [
        r"System32\config\systemprofile\AppData\Roaming",
        r"System32\config\systemprofile\AppData\Local",
    ] {
        let base = PathBuf::from(&system_root).join(relative);
        if base.exists() && !bases.iter().any(|known| known == &base) {
            bases.push(base);
        }
    }

    let system_drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_owned());
    let users_root = PathBuf::from(format!(r"{}\Users", system_drive));
    if let Ok(entries) = fs::read_dir(&users_root) {
        for entry in entries.flatten() {
            let profile = entry.path();
            if !entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false) {
                continue;
            }
            for relative in [r"AppData\Roaming", r"AppData\Local"] {
                let base = profile.join(relative);
                if base.exists() && !bases.iter().any(|known| known == &base) {
                    bases.push(base);
                }
            }
        }
    }

    let mut failures = Vec::new();
    for base in bases {
        if let Err(err) = remove_owned_masterdesk_state_dir(&base, &app_name) {
            log::error!(
                "Failed to remove MasterDesk state under {}: {err}",
                base.display()
            );
            failures.push(format!("{}: {err}", base.display()));
        }
    }

    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    for key in [
        r"SOFTWARE\MasterDesk",
        r"SYSTEM\CurrentControlSet\Control\SafeBoot\Network\MasterDesk",
    ] {
        match hklm.delete_subkey_all(key) {
            Ok(()) => log::info!("Removed MasterDesk registry state: HKLM\\{key}"),
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => failures.push(format!("HKLM\\{key}: {err}")),
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        bail!(
            "MasterDesk settings cleanup was incomplete: {}",
            failures.join("; ")
        )
    }
}

fn write_cmds(cmds: String, ext: &str, tip: &str) -> ResultType<std::path::PathBuf> {
    let mut cmds = cmds;
    let mut tmp = std::env::temp_dir();
    // When dir contains these characters, the bat file will not execute in elevated mode.
    if vec!["&", "@", "^"]
        .drain(..)
        .any(|s| tmp.to_string_lossy().to_string().contains(s))
    {
        if let Ok(dir) = user_accessible_folder() {
            tmp = dir;
        }
    }
    tmp.push(format!("{}_{}.{}", crate::get_app_name(), tip, ext));
    let mut file = std::fs::File::create(&tmp)?;
    if ext == "bat" {
        let tmp2 = get_undone_file(&tmp)?;
        std::fs::File::create(&tmp2).ok();
        cmds = format!(
            "
{cmds}
if exist \"{path}\" del /f /q \"{path}\"
",
            path = tmp2.to_string_lossy()
        );
    }
    // in case cmds mixed with \r\n and \n, make sure all ending with \r\n
    // in some windows, \r\n required for cmd file to run
    cmds = cmds.replace("\r\n", "\n").replace("\n", "\r\n");
    if ext == "vbs" {
        let mut v: Vec<u16> = cmds.encode_utf16().collect();
        // utf8 -> utf16le which vbs support it only
        file.write_all(to_le(&mut v))?;
    } else {
        file.write_all(cmds.as_bytes())?;
    }
    file.sync_all()?;
    return Ok(tmp);
}

fn to_le(v: &mut [u16]) -> &[u8] {
    for b in v.iter_mut() {
        *b = b.to_le()
    }
    unsafe { v.align_to().1 }
}

fn get_undone_file(tmp: &Path) -> ResultType<PathBuf> {
    Ok(tmp.with_file_name(format!(
        "{}.undone",
        tmp.file_name()
            .ok_or(anyhow!("Failed to get filename of {:?}", tmp))?
            .to_string_lossy()
    )))
}

fn run_cmds(cmds: String, show: bool, tip: &str) -> ResultType<()> {
    let tmp = write_cmds(cmds, "bat", tip)?;
    let tmp2 = get_undone_file(&tmp)?;
    let tmp_fn = tmp.to_str().unwrap_or("");
    // https://github.com/rustdesk/rustdesk/issues/6786#issuecomment-1879655410
    // Specify cmd.exe explicitly to avoid the replacement of cmd commands.
    let res = runas::Command::new("cmd.exe")
        .args(&["/C", &tmp_fn])
        .show(show)
        .force_prompt(true)
        .status();
    if !show {
        allow_err!(std::fs::remove_file(tmp));
    }
    let _ = res?;
    if tmp2.exists() {
        allow_err!(std::fs::remove_file(tmp2));
        bail!("{} failed", tip);
    }
    Ok(())
}

pub fn toggle_blank_screen(v: bool) {
    let v = if v { TRUE } else { FALSE };
    unsafe {
        blank_screen(v);
    }
}

pub fn block_input(v: bool) -> (bool, String) {
    let v = if v { TRUE } else { FALSE };
    unsafe {
        if BlockInput(v) == TRUE {
            (true, "".to_owned())
        } else {
            (false, format!("Error: {}", io::Error::last_os_error()))
        }
    }
}

pub fn add_recent_document(path: &str) {
    extern "C" {
        fn AddRecentDocument(path: *const u16);
    }
    use std::os::windows::ffi::OsStrExt;
    let wstr: Vec<u16> = std::ffi::OsStr::new(path)
        .encode_wide()
        .chain(Some(0).into_iter())
        .collect();
    let wstr = wstr.as_ptr();
    unsafe {
        AddRecentDocument(wstr);
    }
}

pub fn is_installed() -> bool {
    let (_, _, _, exe) = get_install_info();
    std::fs::metadata(exe).is_ok()
}

#[inline]
fn should_clear_stale_stop_service(installed: bool, stop_service: &str) -> bool {
    !installed && stop_service == "Y"
}

/// A full uninstall removes the Windows service, so a later no-argument
/// portable launch must not inherit the old per-user "service stopped" state.
pub fn clear_stale_stop_service_for_portable() {
    let stop_service = Config::get_option("stop-service");
    if should_clear_stale_stop_service(is_installed(), &stop_service) {
        log::info!("Clearing stale stop-service state for standalone portable mode");
        Config::set_option("stop-service".into(), "".into());
    }
}

fn safe_mode_network_entries(app_name: &str) -> Vec<(String, &'static str)> {
    vec![
        (app_name.to_owned(), "Service"),
        // Windows Safe Mode with Networking normally contains these entries.
        // Ensure they exist because WlanSvc is the supported Wi-Fi manager and
        // depends on the other three services/drivers on current Windows 10/11.
        ("WlanSvc".to_owned(), "Service"),
        ("Wcmsvc".to_owned(), "Service"),
        ("Ndisuio".to_owned(), "Service"),
        ("nativewifip".to_owned(), "Service"),
    ]
}

fn bcdedit_path() -> PathBuf {
    std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Windows"))
        .join("System32")
        .join("bcdedit.exe")
}

fn run_bcdedit(arguments: &[&str]) -> ResultType<()> {
    let output = std::process::Command::new(bcdedit_path())
        .args(arguments)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|err| anyhow!("Failed to start bcdedit: {err}"))?;
    if output.status.success() {
        return Ok(());
    }
    let details = String::from_utf8_lossy(&output.stderr)
        .trim()
        .chars()
        .take(400)
        .collect::<String>();
    bail!(
        "bcdedit failed with exit code {}{}{}",
        output.status.code().unwrap_or(-1),
        if details.is_empty() { "" } else { ": " },
        details
    )
}

fn bcd_output_has_safeboot(output: &str) -> bool {
    output.lines().any(|line| {
        line.split_whitespace()
            .next()
            .map(|name| name.eq_ignore_ascii_case("safeboot"))
            .unwrap_or(false)
    })
}

fn current_bcd_has_safeboot() -> ResultType<bool> {
    let output = std::process::Command::new(bcdedit_path())
        .args(["/enum", "{current}"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|err| anyhow!("Failed to query bcdedit: {err}"))?;
    if !output.status.success() {
        bail!(
            "bcdedit query failed with exit code {}",
            output.status.code().unwrap_or(-1)
        );
    }
    Ok(bcd_output_has_safeboot(&String::from_utf8_lossy(
        &output.stdout,
    )))
}

fn ensure_safe_mode_network_entries() -> ResultType<Vec<String>> {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let planned = safe_mode_network_entries(&crate::get_app_name());
    let mut missing = Vec::new();
    for (name, kind) in &planned {
        let path = format!(r"{}\{}", SAFE_MODE_NETWORK_REG_PATH, name);
        // Existing SafeBoot entries only need validation. Requesting write access
        // to every built-in child can fail even for LocalSystem on hardened hosts.
        match hklm.open_subkey_with_flags(&path, KEY_READ) {
            Ok(key) => {
                let value = key.get_value::<String, _>("").unwrap_or_default();
                if !value.eq_ignore_ascii_case(kind) {
                    bail!("Unexpected SafeBoot value for {name}");
                }
            }
            Err(err) if err.kind() == io::ErrorKind::NotFound => {
                missing.push((name.clone(), *kind));
            }
            Err(err) => bail!("Failed to inspect SafeBoot entry {name}: {err}"),
        }
    }

    let mut created = Vec::new();
    for (name, kind) in missing {
        let path = format!(r"{}\{}", SAFE_MODE_NETWORK_REG_PATH, name);
        let create_result = hklm.create_subkey(&path).and_then(|(key, disposition)| {
            key.set_value("", &kind)?;
            Ok(disposition)
        });
        if let Err(err) = create_result {
            remove_created_safe_mode_entries(&created).ok();
            bail!("Failed to create SafeBoot entry {name}: {err}");
        }
        created.push(name);
    }
    Ok(created)
}

fn write_safe_mode_marker(phase: u32, created_entries: &[String]) -> ResultType<()> {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let (marker, _) = hklm
        .create_subkey(SAFE_MODE_REBOOT_MARKER_PATH)
        .map_err(|err| anyhow!("Failed to create Safe Mode reboot marker: {err}"))?;
    marker
        .set_value("Phase", &phase)
        .map_err(|err| anyhow!("Failed to write Safe Mode reboot phase: {err}"))?;
    marker
        .set_value("CreatedEntries", &created_entries.join("|"))
        .map_err(|err| anyhow!("Failed to write Safe Mode reboot entries: {err}"))?;
    Ok(())
}

fn read_safe_mode_marker() -> ResultType<Option<(u32, Vec<String>)>> {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let marker = match hklm.open_subkey_with_flags(SAFE_MODE_REBOOT_MARKER_PATH, KEY_READ) {
        Ok(marker) => marker,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err.into()),
    };
    let phase = marker.get_value::<u32, _>("Phase")?;
    let created = marker
        .get_value::<String, _>("CreatedEntries")
        .unwrap_or_default()
        .split('|')
        .filter(|entry| !entry.is_empty())
        .map(str::to_owned)
        .collect();
    Ok(Some((phase, created)))
}

fn remove_safe_mode_marker() -> ResultType<()> {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    match hklm.delete_subkey_all(SAFE_MODE_REBOOT_MARKER_PATH) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err.into()),
    }
}

fn remove_created_safe_mode_entries(created_entries: &[String]) -> ResultType<()> {
    let allowed = safe_mode_network_entries(&crate::get_app_name())
        .into_iter()
        .map(|(name, _)| name)
        .collect::<Vec<_>>();
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    for name in created_entries {
        if !allowed.iter().any(|allowed_name| allowed_name == name) {
            log::warn!("Ignoring unexpected SafeBoot cleanup entry: {name}");
            continue;
        }
        let path = format!(r"{}\{}", SAFE_MODE_NETWORK_REG_PATH, name);
        match hklm.delete_subkey_all(path) {
            Ok(()) => {}
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => return Err(err.into()),
        }
    }
    Ok(())
}

fn rollback_safe_mode_reboot(created_entries: &[String]) {
    if let Err(err) = run_bcdedit(&["/deletevalue", "{current}", "safeboot"]) {
        log::warn!("Failed to clear Safe Mode BCD during rollback: {err}");
    }
    if let Err(err) = remove_created_safe_mode_entries(created_entries) {
        log::warn!("Failed to remove SafeBoot entries during rollback: {err}");
    }
    if let Err(err) = remove_safe_mode_marker() {
        log::warn!("Failed to remove Safe Mode reboot marker during rollback: {err}");
    }
}

fn validate_safe_mode_reboot_service() -> ResultType<()> {
    if !is_cur_exe_the_installed() {
        bail!("Safe Mode restart requires the installed MasterDesk service");
    }
    let services = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(r"SYSTEM\CurrentControlSet\Services", KEY_READ)?;
    let service = services.open_subkey_with_flags(crate::get_app_name(), KEY_READ)?;
    let image_path = service.get_value::<String, _>("ImagePath")?;
    let (_, _, _, installed_executable) = get_install_info();
    let image_path = image_path.to_ascii_lowercase();
    if !image_path.contains("--service")
        || !image_path.contains(&installed_executable.to_ascii_lowercase())
    {
        bail!("MasterDesk service command line is invalid");
    }
    Ok(())
}

/// Prepares a one-shot Safe Mode with Networking boot and restarts Windows.
/// This is intentionally available only from an installed MasterDesk service.
pub fn restart_in_safe_mode() -> ResultType<()> {
    validate_safe_mode_reboot_service()?;
    if current_bcd_has_safeboot()? {
        bail!("Windows boot is already configured for Safe Mode");
    }
    let created_entries = ensure_safe_mode_network_entries()?;
    if let Err(err) = write_safe_mode_marker(SAFE_MODE_REBOOT_PHASE_ARMED, &created_entries) {
        remove_created_safe_mode_entries(&created_entries).ok();
        return Err(err);
    }
    if let Err(err) = run_bcdedit(&["/set", "{current}", "safeboot", "network"]) {
        rollback_safe_mode_reboot(&created_entries);
        return Err(err);
    }
    if let Err(err) = system_shutdown::force_reboot() {
        rollback_safe_mode_reboot(&created_entries);
        bail!("Failed to restart Windows: {err}");
    }
    Ok(())
}

pub async fn request_restart_in_safe_mode() -> ResultType<()> {
    let mut service = ipc::connect_service(2_000)
        .await
        .map_err(|err| anyhow!("MasterDesk service is unavailable: {err}"))?;
    service.send(&ipc::Data::SafeModeRestart(None)).await?;
    match service.next_timeout(10_000).await? {
        Some(ipc::Data::SafeModeRestart(Some(error))) if error.is_empty() => Ok(()),
        Some(ipc::Data::SafeModeRestart(Some(error))) => bail!(error),
        _ => bail!("MasterDesk service returned an invalid Safe Mode restart response"),
    }
}

#[inline]
fn is_windows_safe_mode(clean_boot_metric: i32) -> bool {
    clean_boot_metric != 0
}

fn reconcile_safe_mode_reboot_state() -> ResultType<()> {
    let Some((phase, created_entries)) = read_safe_mode_marker()? else {
        return Ok(());
    };
    let safe_mode = is_windows_safe_mode(unsafe { GetSystemMetrics(SM_CLEANBOOT) });
    match (phase, safe_mode) {
        (SAFE_MODE_REBOOT_PHASE_ARMED, true) => {
            run_bcdedit(&["/deletevalue", "{current}", "safeboot"])?;
            write_safe_mode_marker(SAFE_MODE_REBOOT_PHASE_STARTED, &created_entries)?;
            log::info!("Safe Mode boot is active; next restart restored to normal boot");
        }
        (SAFE_MODE_REBOOT_PHASE_ARMED, false) => {
            // The service restarted before Windows entered Safe Mode. Treat the
            // plan as abandoned so a later unrelated reboot cannot enter it.
            rollback_safe_mode_reboot(&created_entries);
        }
        (SAFE_MODE_REBOOT_PHASE_STARTED, false) => {
            remove_created_safe_mode_entries(&created_entries)?;
            remove_safe_mode_marker()?;
            log::info!("Safe Mode reboot cleanup completed after normal startup");
        }
        (SAFE_MODE_REBOOT_PHASE_STARTED, true) => {}
        _ => {
            rollback_safe_mode_reboot(&created_entries);
            bail!("Invalid Safe Mode reboot marker phase");
        }
    }
    Ok(())
}

pub fn get_reg(name: &str) -> String {
    let (subkey, _, _, _) = get_install_info();
    get_reg_of(&subkey, name)
}

fn get_reg_of(subkey: &str, name: &str) -> String {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    if let Ok(tmp) = hklm.open_subkey(subkey.replace("HKEY_LOCAL_MACHINE\\", "")) {
        if let Ok(v) = tmp.get_value(name) {
            return v;
        }
    }
    "".to_owned()
}

fn get_public_base_dir() -> PathBuf {
    if let Ok(allusersprofile) = std::env::var("ALLUSERSPROFILE") {
        let path = PathBuf::from(&allusersprofile);
        if path.exists() {
            return path;
        }
    }
    if let Ok(public) = std::env::var("PUBLIC") {
        let path = PathBuf::from(public).join("Documents");
        if path.exists() {
            return path;
        }
    }
    let program_data_dir = PathBuf::from("C:\\ProgramData");
    if program_data_dir.exists() {
        return program_data_dir;
    }
    std::env::temp_dir()
}

#[inline]
pub fn get_custom_client_staging_dir() -> PathBuf {
    get_public_base_dir()
        .join("RustDesk")
        .join("RustDeskCustomClientStaging")
}

/// Removes the custom client staging directory.
///
/// Current behavior: intentionally a no-op (does not delete).
///
/// Rationale
/// - The staging directory only contains a small `custom.txt`, leaving it is harmless.
/// - Deleting directories under a public location (e.g., C:\\ProgramData\\RustDesk) is
///   susceptible to TOCTOU attacks if an unprivileged user can replace the path with a
///   symlink/junction between checks and deletion.
///
/// Future work:
/// - Use the files (if needed) in the installation directory instead of a public location.
///   This directory only contains a small `custom.txt` file.
/// - Pass the custom client name directly via command line
///   or environment variable during update installation. Then no staging directory is needed.
#[inline]
pub fn remove_custom_client_staging_dir(staging_dir: &Path) -> ResultType<bool> {
    if !staging_dir.exists() {
        return Ok(false);
    }

    // First explicitly removes `custom.txt` to ensure stale config is never replayed,
    // even if the subsequent directory removal fails.
    //
    // `std::fs::remove_file` on a symlink removes the symlink itself, not the target,
    // so this is safe even in a TOCTOU race.
    let custom_txt_path = staging_dir.join("custom.txt");
    if custom_txt_path.exists() {
        allow_err!(std::fs::remove_file(&custom_txt_path));
    }

    // Intentionally not deleting. See the function docs for rationale.
    log::debug!(
        "Skip deleting staging directory {:?} (intentional to avoid TOCTOU)",
        staging_dir
    );
    Ok(false)
}

// Prepare custom client update by copying staged custom.txt to current directory and loading it.
// Returns:
// 1. Ok(true) if preparation was successful or no staging directory exists.
// 2. Ok(false) if custom.txt file exists but has invalid contents or fails security checks
//    (e.g., is a symlink or has invalid contents).
// 3. Err if any unexpected error occurs during file operations.
pub fn prepare_custom_client_update() -> ResultType<bool> {
    let custom_client_staging_dir = get_custom_client_staging_dir();
    let current_exe = std::env::current_exe()?;
    let current_exe_dir = current_exe
        .parent()
        .ok_or(anyhow!("Cannot get parent directory of current exe"))?;

    let staging_dir = custom_client_staging_dir.clone();
    let clear_staging_on_exit = crate::SimpleCallOnReturn {
        b: true,
        f: Box::new(
            move || match remove_custom_client_staging_dir(&staging_dir) {
                Ok(existed) => {
                    if existed {
                        log::info!("Custom client staging directory removed successfully.");
                    }
                }
                Err(e) => {
                    log::error!(
                        "Failed to remove custom client staging directory {:?}: {}",
                        staging_dir,
                        e
                    );
                }
            },
        ),
    };

    if custom_client_staging_dir.exists() {
        let custom_txt_path = custom_client_staging_dir.join("custom.txt");
        if !custom_txt_path.exists() {
            return Ok(true);
        }

        let metadata = std::fs::symlink_metadata(&custom_txt_path)?;
        if metadata.is_symlink() {
            log::error!(
                "custom.txt is a symlink. Refusing to load custom client for security reasons."
            );
            drop(clear_staging_on_exit);
            return Ok(false);
        }
        if metadata.is_file() {
            // Copy custom.txt to current directory
            let local_custom_file_path = current_exe_dir.join("custom.txt");
            log::debug!(
                "Copying staged custom file from {:?} to {:?}",
                custom_txt_path,
                local_custom_file_path
            );

            // No need to check symlink before copying.
            // `load_custom_client()` will fail if the file is not valid.
            fs::copy(&custom_txt_path, &local_custom_file_path)?;
            log::info!("Staged custom client file copied to current directory.");

            // Load custom client
            let is_custom_file_exists =
                local_custom_file_path.exists() && local_custom_file_path.is_file();
            crate::load_custom_client();

            // Remove the copied custom.txt file
            allow_err!(fs::remove_file(&local_custom_file_path));

            // Check if loaded successfully
            if is_custom_file_exists && !crate::common::is_custom_client() {
                // The custom.txt file existed, but its contents are invalid.
                log::error!("Failed to load custom client from custom.txt.");
                drop(clear_staging_on_exit);
                // ERROR_INVALID_DATA
                return Ok(false);
            }
        } else {
            log::info!("No custom client files found in staging directory.");
        }
    } else {
        log::info!(
            "Custom client staging directory {:?} does not exist.",
            custom_client_staging_dir
        );
    }

    Ok(true)
}

pub fn get_license_from_exe_name() -> ResultType<CustomServer> {
    let mut exe = std::env::current_exe()?.to_str().unwrap_or("").to_owned();
    // if defined portable appname entry, replace original executable name with it.
    if let Ok(portable_exe) = std::env::var(PORTABLE_APPNAME_RUNTIME_ENV_KEY) {
        exe = portable_exe;
    }
    get_custom_server_from_string(&exe)
}

// We can't directly use `RegKey::set_value` to update the registry value, because it will fail with `ERROR_ACCESS_DENIED`
// So we have to use `run_cmds` to update the registry value.
pub fn update_install_option(k: &str, v: &str) -> ResultType<()> {
    // Don't update registry if not installed or not server process.
    if !is_installed() || !crate::is_server() {
        return Ok(());
    }
    if ![REG_NAME_INSTALL_PRINTER].contains(&k) || !["0", "1"].contains(&v) {
        return Ok(());
    }
    let app_name = crate::get_app_name();
    let ext = app_name.to_lowercase();
    let cmds =
        format!("chcp 65001 && reg add HKEY_CLASSES_ROOT\\.{ext} /f /v {k} /t REG_SZ /d \"{v}\"");
    run_cmds(cmds, false, "update_install_option")?;
    Ok(())
}

#[inline]
pub fn is_win_server() -> bool {
    unsafe { is_windows_server() > 0 }
}

#[inline]
pub fn is_win_10_or_greater() -> bool {
    unsafe { is_windows_10_or_greater() > 0 }
}

pub fn bootstrap() -> bool {
    if let Ok(lic) = get_license_from_exe_name() {
        *config::EXE_RENDEZVOUS_SERVER.write().unwrap() = lic.host.clone();
    }

    #[cfg(debug_assertions)]
    {
        true
    }
    #[cfg(not(debug_assertions))]
    {
        // This function will cause `'sciter.dll' was not found neither in PATH nor near the current executable.` when debugging RustDesk.
        // Only call set_safe_load_dll() on Windows 10 or greater
        if is_win_10_or_greater() {
            set_safe_load_dll()
        } else {
            true
        }
    }
}

#[cfg(not(debug_assertions))]
fn set_safe_load_dll() -> bool {
    if !unsafe { set_default_dll_directories() } {
        return false;
    }

    // `SetDllDirectoryW` should never fail.
    // https://docs.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setdlldirectoryw
    if unsafe { SetDllDirectoryW(wide_string("").as_ptr()) == FALSE } {
        eprintln!("SetDllDirectoryW failed: {}", io::Error::last_os_error());
        return false;
    }

    true
}

// https://docs.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-setdefaultdlldirectories
#[cfg(not(debug_assertions))]
unsafe fn set_default_dll_directories() -> bool {
    let module = LoadLibraryExW(
        wide_string("Kernel32.dll").as_ptr(),
        0 as _,
        LOAD_LIBRARY_SEARCH_SYSTEM32,
    );
    if module.is_null() {
        return false;
    }

    match CString::new("SetDefaultDllDirectories") {
        Err(e) => {
            eprintln!("CString::new failed: {}", e);
            return false;
        }
        Ok(func_name) => {
            let func = GetProcAddress(module, func_name.as_ptr());
            if func.is_null() {
                eprintln!("GetProcAddress failed: {}", io::Error::last_os_error());
                return false;
            }
            type SetDefaultDllDirectories = unsafe extern "system" fn(DWORD) -> BOOL;
            let func: SetDefaultDllDirectories = std::mem::transmute(func);
            if func(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_USER_DIRS) == FALSE {
                eprintln!(
                    "SetDefaultDllDirectories failed: {}",
                    io::Error::last_os_error()
                );
                return false;
            }
        }
    }
    true
}

fn get_custom_icon(install_dir: &str, exe: &str) -> Option<String> {
    const RELATIVE_ICON_PATH: &str = "data\\flutter_assets\\assets\\icon.ico";
    if crate::is_custom_client() {
        if let Some(p) = PathBuf::from(exe).parent() {
            let alter_icon_path = p.join(RELATIVE_ICON_PATH);
            if alter_icon_path.exists() {
                // During installation, files under `install_dir` may not exist yet.
                // So we validate the icon from the current executable directory first.
                // But for shortcut/registry icon location, we should point to the final
                // installed path so the icon works across different Windows users.
                if let Ok(metadata) = std::fs::symlink_metadata(&alter_icon_path) {
                    if metadata.is_symlink() {
                        log::warn!(
                            "Custom icon at {:?} is a symlink, refusing to use it.",
                            alter_icon_path
                        );
                        return None;
                    }
                    if metadata.is_file() {
                        return if install_dir.is_empty() {
                            Some(alter_icon_path.to_string_lossy().to_string())
                        } else {
                            Some(format!("{}\\{}", install_dir, RELATIVE_ICON_PATH))
                        };
                    }
                }
            }
        }
    }
    None
}

#[inline]
fn get_shortcut_icon_location(install_dir: &str, exe: &str) -> String {
    if exe.is_empty() {
        return "".to_owned();
    }

    get_custom_icon(install_dir, exe)
        .map(|p| format!("oLink.IconLocation = \"{}\"", p))
        .unwrap_or_default()
}

pub fn create_shortcut(id: &str) -> ResultType<()> {
    let exe = std::env::current_exe()?.to_str().unwrap_or("").to_owned();
    // https://github.com/rustdesk/rustdesk/issues/13735
    // Replace ':' with '_' for filename since ':' is not allowed in Windows filenames
    // https://github.com/rustdesk/hbb_common/blob/8b0e25867375ba9e6bff548acf44fe6d6ffa7c0e/src/config.rs#L1384
    let filename = id.replace(':', "_");
    let shortcut_icon_location = get_shortcut_icon_location("", &exe);
    let shortcut = write_cmds(
        format!(
            "
Set oWS = WScript.CreateObject(\"WScript.Shell\")
strDesktop = oWS.SpecialFolders(\"Desktop\")
Set objFSO = CreateObject(\"Scripting.FileSystemObject\")
sLinkFile = objFSO.BuildPath(strDesktop, \"{filename}.lnk\")
Set oLink = oWS.CreateShortcut(sLinkFile)
    oLink.TargetPath = \"{exe}\"
    oLink.Arguments = \"--connect {id}\"
    {shortcut_icon_location}
oLink.Save
        "
        ),
        "vbs",
        "connect_shortcut",
    )?
    .to_str()
    .unwrap_or("")
    .to_owned();
    std::process::Command::new("cscript")
        .arg(&shortcut)
        .creation_flags(CREATE_NO_WINDOW)
        .output()?;
    allow_err!(std::fs::remove_file(shortcut));
    Ok(())
}

pub fn enable_lowlevel_keyboard(hwnd: HWND) {
    let ret = unsafe { win32_enable_lowlevel_keyboard(hwnd) };
    if ret != 0 {
        log::error!("Failure grabbing keyboard");
        return;
    }
}

pub fn disable_lowlevel_keyboard(hwnd: HWND) {
    unsafe { win32_disable_lowlevel_keyboard(hwnd) };
}

pub fn stop_system_key_propagate(v: bool) {
    unsafe { win_stop_system_key_propagate(if v { TRUE } else { FALSE }) };
}

pub fn get_win_key_state() -> bool {
    unsafe { is_win_down() == TRUE }
}

pub fn quit_gui() {
    std::process::exit(0);
    // unsafe { PostQuitMessage(0) }; // some how not work
}

pub fn get_user_token(session_id: u32, as_user: bool) -> HANDLE {
    let mut token = NULL as HANDLE;
    unsafe {
        let mut _token_pid = 0;
        if FALSE
            == GetSessionUserTokenWin(
                &mut token as _,
                session_id,
                if as_user { TRUE } else { FALSE },
                &mut _token_pid,
            )
        {
            NULL as _
        } else {
            token
        }
    }
}

pub fn run_background(exe: &str, arg: &str) -> ResultType<bool> {
    let wexe = wide_string(exe);
    let warg;
    unsafe {
        let ret = ShellExecuteW(
            NULL as _,
            NULL as _,
            wexe.as_ptr() as _,
            if arg.is_empty() {
                NULL as _
            } else {
                warg = wide_string(arg);
                warg.as_ptr() as _
            },
            NULL as _,
            SW_HIDE,
        );
        return Ok(ret as i32 > 32);
    }
}

pub fn run_uac(exe: &str, arg: &str) -> ResultType<bool> {
    let wop = wide_string("runas");
    let wexe = wide_string(exe);
    let warg;
    unsafe {
        let ret = ShellExecuteW(
            NULL as _,
            wop.as_ptr() as _,
            wexe.as_ptr() as _,
            if arg.is_empty() {
                NULL as _
            } else {
                warg = wide_string(arg);
                warg.as_ptr() as _
            },
            NULL as _,
            SW_SHOWNORMAL,
        );
        return Ok(ret as i32 > 32);
    }
}

pub fn check_super_user_permission() -> ResultType<bool> {
    run_uac(
        std::env::current_exe()?
            .to_string_lossy()
            .to_string()
            .as_str(),
        "--version",
    )
}

pub fn elevate(arg: &str) -> ResultType<bool> {
    run_uac(
        std::env::current_exe()?
            .to_string_lossy()
            .to_string()
            .as_str(),
        arg,
    )
}

pub fn run_as_system(arg: &str) -> ResultType<()> {
    let exe = std::env::current_exe()?.to_string_lossy().to_string();
    if impersonate_system::run_as_system(&exe, arg).is_err() {
        bail!(format!("Failed to run {} as system", exe));
    }
    Ok(())
}

pub fn elevate_or_run_as_system(is_setup: bool, is_elevate: bool, is_run_as_system: bool) {
    // avoid possible run recursively due to failed run.
    log::info!(
        "elevate: {} -> {:?}, run_as_system: {} -> {}",
        is_elevate,
        is_elevated(None),
        is_run_as_system,
        crate::username(),
    );
    let mut arg_elevate = if is_setup {
        "--noinstall --elevate"
    } else {
        "--elevate"
    }
    .to_owned();
    let mut arg_run_as_system = if is_setup {
        "--noinstall --run-as-system"
    } else {
        "--run-as-system"
    }
    .to_owned();
    let shmem_name_from_args = crate::portable_service::portable_service_shmem_name_from_args();
    if shmem_name_from_args.is_none() && crate::portable_service::has_portable_service_shmem_arg() {
        log::error!("Invalid portable service shared memory argument, aborting elevation flow");
        // This is a malformed bootstrap argument in a privilege-sensitive path.
        // Keep fail-closed process termination here to avoid continuing elevation
        // with inconsistent shared-memory contract.
        std::process::exit(1);
    }
    if let Some(shmem_name) = shmem_name_from_args {
        let shmem_arg = crate::portable_service::portable_service_shmem_arg(&shmem_name);
        arg_elevate.push(' ');
        arg_elevate.push_str(&shmem_arg);
        arg_run_as_system.push(' ');
        arg_run_as_system.push_str(&shmem_arg);
    }
    if is_root() {
        if is_run_as_system {
            log::info!("run portable service");
            crate::portable_service::server::run_portable_service();
        }
    } else {
        match is_elevated(None) {
            Ok(elevated) => {
                if elevated {
                    if !is_run_as_system {
                        if run_as_system(arg_run_as_system.as_str()).is_ok() {
                            std::process::exit(0);
                        } else {
                            log::error!(
                                "Failed to run as system, error {}",
                                io::Error::last_os_error()
                            );
                        }
                    }
                } else {
                    if !is_elevate {
                        if let Ok(true) = elevate(arg_elevate.as_str()) {
                            std::process::exit(0);
                        } else {
                            log::error!("Failed to elevate, error {}", io::Error::last_os_error());
                        }
                    }
                }
            }
            Err(_) => log::error!(
                "Failed to get elevation status, error {}",
                io::Error::last_os_error()
            ),
        }
    }
}

pub fn is_elevated(process_id: Option<DWORD>) -> ResultType<bool> {
    use hbb_common::platform::windows::RAIIHandle;
    unsafe {
        let handle: HANDLE = match process_id {
            Some(process_id) => OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id),
            None => GetCurrentProcess(),
        };
        if handle == NULL {
            bail!(
                "Failed to open process, error {}",
                io::Error::last_os_error()
            )
        }
        let _handle = RAIIHandle(handle);
        let mut token: HANDLE = mem::zeroed();
        if OpenProcessToken(handle, TOKEN_QUERY, &mut token) == FALSE {
            bail!(
                "Failed to open process token, error {}",
                io::Error::last_os_error()
            )
        }
        let _token = RAIIHandle(token);
        let mut token_elevation: TOKEN_ELEVATION = mem::zeroed();
        let mut size: DWORD = 0;
        if GetTokenInformation(
            token,
            TokenElevation,
            (&mut token_elevation) as *mut _ as *mut c_void,
            mem::size_of::<TOKEN_ELEVATION>() as _,
            &mut size,
        ) == FALSE
        {
            bail!(
                "Failed to get token information, error {}",
                io::Error::last_os_error()
            )
        }

        Ok(token_elevation.TokenIsElevated != 0)
    }
}

#[inline]
unsafe fn read_token_user_buffer(token: WinHANDLE, subject: &str) -> ResultType<Vec<u8>> {
    let mut token_user_size = 0u32;
    let get_info_result = WinGetTokenInformation(token, TokenUser, None, 0, &mut token_user_size);
    match get_info_result {
        Ok(()) => {
            if token_user_size == 0 {
                bail!(
                    "Failed to get {} token user size: unexpected zero buffer size",
                    subject
                );
            }
        }
        Err(e) => {
            // Allow expected size-probe failures if Windows still returns required size.
            let is_insufficient_buffer =
                e.code() == windows::core::HRESULT::from_win32(ERROR_INSUFFICIENT_BUFFER as u32);
            let is_bad_length =
                e.code() == windows::core::HRESULT::from_win32(ERROR_BAD_LENGTH as u32);
            if (!is_insufficient_buffer && !is_bad_length) || token_user_size == 0 {
                bail!("Failed to get {} token user size: {}", subject, e);
            }
        }
    }

    let mut buffer = vec![0u8; token_user_size as usize];
    WinGetTokenInformation(
        token,
        TokenUser,
        Some(buffer.as_mut_ptr() as *mut core::ffi::c_void),
        token_user_size,
        &mut token_user_size,
    )
    .map_err(|e| anyhow!("Failed to get {} token user: {}", subject, e))?;

    let min_size = std::mem::size_of::<TOKEN_USER>();
    if buffer.len() < min_size {
        bail!(
            "Failed to parse {} token user: buffer too small (got {}, need >= {})",
            subject,
            buffer.len(),
            min_size
        );
    }
    Ok(buffer)
}

/// Similar to `is_root()` / `is_local_system()` but for an arbitrary process.
///
/// Returns `true` if the target process is running as LocalSystem (SID: S-1-5-18).
///
/// TODO: After a few releases of real-world validation, consider replacing
/// the legacy `is_local_system()` with this implementation.
pub fn is_process_running_as_system(process_id: DWORD) -> ResultType<bool> {
    unsafe {
        let process = WinOpenProcess(WIN_PROCESS_QUERY_LIMITED_INFORMATION, false, process_id)
            .map_err(|e| anyhow!("Failed to open process {}: {}", process_id, e))?;

        let mut token = WinHANDLE::default();
        let result = (|| -> ResultType<bool> {
            WinOpenProcessToken(process, WIN_TOKEN_QUERY, &mut token)
                .map_err(|e| anyhow!("Failed to open process {} token: {}", process_id, e))?;

            let token_subject = format!("process {}", process_id);
            let buffer = read_token_user_buffer(token, token_subject.as_str())?;
            let token_user: TOKEN_USER =
                std::ptr::read_unaligned(buffer.as_ptr() as *const TOKEN_USER);
            Ok(IsWellKnownSid(token_user.User.Sid, WinLocalSystemSid).as_bool())
        })();

        if !token.is_invalid() {
            let _ = WinCloseHandle(token);
        }
        let _ = WinCloseHandle(process);
        result
    }
}

/// Returns whether the process token contains the built-in Administrators SID.
///
/// Unlike `is_elevated`, this intentionally recognizes an administrator's
/// filtered UAC token. It is used only as one part of the main IPC policy; the
/// caller also verifies that the peer is the exact same RustDesk executable.
pub fn is_process_user_admin(process_id: DWORD) -> ResultType<bool> {
    use hbb_common::platform::windows::RAIIHandle;
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
        if process == NULL {
            bail!(
                "Failed to open process {}, error {}",
                process_id,
                io::Error::last_os_error()
            );
        }
        let _process = RAIIHandle(process);

        let mut token: HANDLE = mem::zeroed();
        if OpenProcessToken(process, TOKEN_QUERY, &mut token) == FALSE {
            bail!(
                "Failed to open process {} token, error {}",
                process_id,
                io::Error::last_os_error()
            );
        }
        let _token = RAIIHandle(token);
        is_user_token_admin(token)
    }
}

pub fn get_process_executable_path(process_id: DWORD) -> ResultType<PathBuf> {
    const PROCESS_IMAGE_PATH_BUFFER_LEN: usize = 32 * 1024;
    unsafe {
        let process = WinOpenProcess(WIN_PROCESS_QUERY_LIMITED_INFORMATION, false, process_id)
            .map_err(|e| anyhow!("Failed to open process {}: {}", process_id, e))?;

        let result = (|| -> ResultType<PathBuf> {
            let mut buffer = vec![0u16; PROCESS_IMAGE_PATH_BUFFER_LEN];
            let mut length = PROCESS_IMAGE_PATH_BUFFER_LEN as u32;
            WinQueryFullProcessImageNameW(
                process,
                windows::Win32::System::Threading::PROCESS_NAME_FORMAT(0),
                windows::core::PWSTR(buffer.as_mut_ptr()),
                &mut length,
            )
            .map_err(|e| anyhow!("Failed to query process {} image path: {}", process_id, e))?;
            if length == 0 {
                bail!(
                    "Failed to query process {} image path: empty result",
                    process_id
                );
            }
            buffer.truncate(length as usize);
            Ok(PathBuf::from(OsString::from_wide(&buffer)))
        })();

        let _ = WinCloseHandle(process);
        result
    }
}

pub fn is_foreground_window_elevated() -> ResultType<bool> {
    unsafe {
        let mut process_id: DWORD = 0;
        GetWindowThreadProcessId(GetForegroundWindow(), &mut process_id);
        if process_id == 0 {
            bail!(
                "Failed to get processId, error {}",
                io::Error::last_os_error()
            )
        }
        is_elevated(Some(process_id))
    }
}

fn get_current_pid() -> u32 {
    unsafe { GetCurrentProcessId() }
}

pub fn get_double_click_time() -> u32 {
    unsafe { GetDoubleClickTime() }
}

pub fn wide_string(s: &str) -> Vec<u16> {
    use std::os::windows::prelude::OsStrExt;
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(Some(0).into_iter())
        .collect()
}

/// send message to currently shown window
pub fn send_message_to_hnwd(
    class_name: &str,
    window_name: &str,
    dw_data: usize,
    data: &str,
    show_window: bool,
) -> bool {
    unsafe {
        let class_name_utf16 = wide_string(class_name);
        let window_name_utf16 = wide_string(window_name);
        let window = FindWindowW(class_name_utf16.as_ptr(), window_name_utf16.as_ptr());
        if window.is_null() {
            log::warn!("no such window {}:{}", class_name, window_name);
            return false;
        }
        let mut data_struct = COPYDATASTRUCT::default();
        data_struct.dwData = dw_data;
        let mut data_zero: String = data.chars().chain(Some('\0').into_iter()).collect();
        println!("send {:?}", data_zero);
        data_struct.cbData = data_zero.len() as _;
        data_struct.lpData = data_zero.as_mut_ptr() as _;
        SendMessageW(
            window,
            WM_COPYDATA,
            0,
            &data_struct as *const COPYDATASTRUCT as _,
        );
        if show_window {
            ShowWindow(window, SW_NORMAL);
            SetForegroundWindow(window);
        }
    }
    return true;
}

pub fn get_logon_user_token(user: &str, pwd: &str) -> ResultType<HANDLE> {
    let user_split = user.split("\\").collect::<Vec<&str>>();
    let wuser = wide_string(user_split.get(1).unwrap_or(&user));
    let wpc = wide_string(user_split.get(0).unwrap_or(&""));
    let wpwd = wide_string(pwd);
    let mut ph_token: HANDLE = std::ptr::null_mut();
    let res = unsafe {
        LogonUserW(
            wuser.as_ptr(),
            wpc.as_ptr(),
            wpwd.as_ptr(),
            LOGON32_LOGON_INTERACTIVE,
            LOGON32_PROVIDER_DEFAULT,
            &mut ph_token as _,
        )
    };
    if res == FALSE {
        bail!(
            "Failed to log on user {}: {}",
            user,
            std::io::Error::last_os_error()
        );
    } else {
        if ph_token.is_null() {
            bail!(
                "Failed to log on user {}: {}",
                user,
                std::io::Error::last_os_error()
            );
        }
        Ok(ph_token)
    }
}

// Ensure the token returned is a primary token.
// If the provided token is an impersonation token, it duplicates it to a primary token.
// If the provided token is already a primary token, it returns it as is.
// The caller is responsible for closing the returned token handle.
pub fn ensure_primary_token(user_token: HANDLE) -> ResultType<HANDLE> {
    if user_token.is_null() || user_token == INVALID_HANDLE_VALUE {
        bail!("Invalid user token provided");
    }

    unsafe {
        let mut token_type: TOKEN_TYPE = 0;
        let mut return_length: DWORD = 0;

        if GetTokenInformation(
            user_token,
            TokenType,
            &mut token_type as *mut _ as *mut _,
            std::mem::size_of::<TOKEN_TYPE>() as DWORD,
            &mut return_length,
        ) == FALSE
        {
            bail!(
                "Failed to get token type, error {}",
                io::Error::last_os_error()
            );
        }

        if token_type == TokenImpersonation {
            let mut duplicate_token: HANDLE = std::ptr::null_mut();
            let dup_res = DuplicateToken(user_token, SecurityImpersonation, &mut duplicate_token);
            CloseHandle(user_token);
            if dup_res == FALSE {
                bail!(
                    "Failed to duplicate token, error {}",
                    io::Error::last_os_error()
                );
            }
            Ok(duplicate_token)
        } else {
            Ok(user_token)
        }
    }
}

pub fn is_user_token_admin(user_token: HANDLE) -> ResultType<bool> {
    if user_token.is_null() || user_token == INVALID_HANDLE_VALUE {
        bail!("Invalid user token provided");
    }

    unsafe {
        let mut dw_size: DWORD = 0;
        GetTokenInformation(
            user_token,
            TokenGroups,
            std::ptr::null_mut(),
            0,
            &mut dw_size,
        );

        let last_error = GetLastError();
        if last_error != ERROR_INSUFFICIENT_BUFFER {
            bail!(
                "Failed to get token groups buffer size, error: {}",
                last_error
            );
        }
        if dw_size == 0 {
            bail!("Token groups buffer size is zero");
        }

        let mut buffer = vec![0u8; dw_size as usize];
        if GetTokenInformation(
            user_token,
            TokenGroups,
            buffer.as_mut_ptr() as *mut _,
            dw_size,
            &mut dw_size,
        ) == FALSE
        {
            bail!(
                "Failed to get token groups information, error: {}",
                io::Error::last_os_error()
            );
        }

        let p_token_groups = buffer.as_ptr() as *const TOKEN_GROUPS;
        let group_count = (*p_token_groups).GroupCount;

        if group_count == 0 {
            return Ok(false);
        }

        let mut nt_authority: SID_IDENTIFIER_AUTHORITY = SID_IDENTIFIER_AUTHORITY {
            Value: SECURITY_NT_AUTHORITY,
        };
        let mut administrators_group: PSID = std::ptr::null_mut();
        if AllocateAndInitializeSid(
            &mut nt_authority,
            2,
            SECURITY_BUILTIN_DOMAIN_RID,
            DOMAIN_ALIAS_RID_ADMINS,
            0,
            0,
            0,
            0,
            0,
            0,
            &mut administrators_group,
        ) == FALSE
        {
            bail!(
                "Failed to allocate administrators group SID, error: {}",
                io::Error::last_os_error()
            );
        }
        if administrators_group.is_null() {
            bail!("Failed to create administrators group SID");
        }

        let mut is_admin = false;
        let groups =
            std::slice::from_raw_parts((*p_token_groups).Groups.as_ptr(), group_count as usize);
        for group in groups {
            if EqualSid(administrators_group, group.Sid) == TRUE {
                is_admin = true;
                break;
            }
        }

        if !administrators_group.is_null() {
            FreeSid(administrators_group);
        }

        Ok(is_admin)
    }
}

pub fn create_process_with_logon(user: &str, pwd: &str, exe: &str, arg: &str) -> ResultType<()> {
    let last_error_table = HashMap::from([
        (
            ERROR_LOGON_FAILURE,
            "The user name or password is incorrect.",
        ),
        (ERROR_ACCESS_DENIED, "Access is denied."),
    ]);

    unsafe {
        let user_split = user.split("\\").collect::<Vec<&str>>();
        let wuser = wide_string(user_split.get(1).unwrap_or(&user));
        let wpc = wide_string(user_split.get(0).unwrap_or(&""));
        let wpwd = wide_string(pwd);
        let cmd = if arg.is_empty() {
            format!("\"{}\"", exe)
        } else {
            format!("\"{}\" {}", exe, arg)
        };
        let mut wcmd = wide_string(&cmd);
        let mut si: STARTUPINFOW = mem::zeroed();
        si.wShowWindow = SW_HIDE as _;
        si.lpDesktop = NULL as _;
        si.cb = std::mem::size_of::<STARTUPINFOW>() as _;
        si.dwFlags = STARTF_USESHOWWINDOW;
        let mut pi: PROCESS_INFORMATION = mem::zeroed();
        let wexe = wide_string(exe);
        if FALSE
            == CreateProcessWithLogonW(
                wuser.as_ptr(),
                wpc.as_ptr(),
                wpwd.as_ptr(),
                LOGON_WITH_PROFILE,
                wexe.as_ptr(),
                wcmd.as_mut_ptr(),
                CREATE_UNICODE_ENVIRONMENT,
                NULL,
                NULL as _,
                &mut si as *mut STARTUPINFOW,
                &mut pi as *mut PROCESS_INFORMATION,
            )
        {
            let last_error = GetLastError();
            bail!(
                "CreateProcessWithLogonW failed : \"{}\", error {}",
                last_error_table
                    .get(&last_error)
                    .unwrap_or(&"Unknown error"),
                io::Error::from_raw_os_error(last_error as _)
            );
        }
    }
    return Ok(());
}

#[inline]
fn str_to_device_name(name: &str) -> [u16; 32] {
    let mut device_name: Vec<u16> = wide_string(name);
    if device_name.len() < 32 {
        device_name.resize(32, 0);
    }
    let mut result = [0; 32];
    result.copy_from_slice(&device_name[..32]);
    result
}

pub fn resolutions(name: &str) -> Vec<Resolution> {
    unsafe {
        let mut dm: DEVMODEW = std::mem::zeroed();
        let mut v = vec![];
        let mut num = 0;
        let device_name = str_to_device_name(name);
        loop {
            if EnumDisplaySettingsW(device_name.as_ptr(), num, &mut dm) == 0 {
                break;
            }
            let r = Resolution {
                width: dm.dmPelsWidth as _,
                height: dm.dmPelsHeight as _,
                ..Default::default()
            };
            if !v.contains(&r) {
                v.push(r);
            }
            num += 1;
        }
        v
    }
}

pub fn current_resolution(name: &str) -> ResultType<Resolution> {
    let device_name = str_to_device_name(name);
    unsafe {
        let mut dm: DEVMODEW = std::mem::zeroed();
        dm.dmSize = std::mem::size_of::<DEVMODEW>() as _;
        if EnumDisplaySettingsW(device_name.as_ptr(), ENUM_CURRENT_SETTINGS, &mut dm) == 0 {
            bail!(
                "failed to get current resolution, error {}",
                io::Error::last_os_error()
            );
        }
        let r = Resolution {
            width: dm.dmPelsWidth as _,
            height: dm.dmPelsHeight as _,
            ..Default::default()
        };
        Ok(r)
    }
}

pub(super) fn change_resolution_directly(
    name: &str,
    width: usize,
    height: usize,
) -> ResultType<()> {
    let device_name = str_to_device_name(name);
    unsafe {
        let mut dm: DEVMODEW = std::mem::zeroed();
        dm.dmSize = std::mem::size_of::<DEVMODEW>() as _;
        dm.dmPelsWidth = width as _;
        dm.dmPelsHeight = height as _;
        dm.dmFields = DM_PELSHEIGHT | DM_PELSWIDTH;
        let res = ChangeDisplaySettingsExW(
            device_name.as_ptr(),
            &mut dm,
            NULL as _,
            CDS_UPDATEREGISTRY | CDS_GLOBAL | CDS_RESET,
            NULL,
        );
        if res != DISP_CHANGE_SUCCESSFUL {
            bail!(
                "ChangeDisplaySettingsExW failed, res={}, error {}",
                res,
                io::Error::last_os_error()
            );
        }
        Ok(())
    }
}

pub fn user_accessible_folder() -> ResultType<PathBuf> {
    let disk = std::env::var("SystemDrive").unwrap_or("C:".to_string());
    let dir1 = PathBuf::from(format!("{}\\ProgramData", disk));
    // NOTICE: "C:\Windows\Temp" requires permanent authorization.
    let dir2 = PathBuf::from(format!("{}\\Windows\\Temp", disk));
    let dir;
    if dir1.exists() {
        dir = dir1;
    } else if dir2.exists() {
        dir = dir2;
    } else {
        bail!("no valid user accessible folder");
    }
    Ok(dir)
}

#[inline]
pub fn uninstall_cert() -> ResultType<()> {
    cert::uninstall_cert()
}

mod cert {
    use hbb_common::ResultType;

    extern "C" {
        fn DeleteRustDeskTestCertsW();
    }
    pub fn uninstall_cert() -> ResultType<()> {
        unsafe {
            DeleteRustDeskTestCertsW();
        }
        Ok(())
    }
}

#[inline]
pub fn get_char_from_vk(vk: u32) -> Option<char> {
    get_char_from_unicode(get_unicode_from_vk(vk)?)
}

/// Returns the KLID selected by the foreground Windows thread (for example
/// `00000409`). This is sampled after Windows has processed Alt+Shift/Ctrl+Shift.
pub fn foreground_keyboard_layout_klid() -> ResultType<String> {
    let foreground = unsafe { GetForegroundWindow() };
    if foreground.is_null() {
        bail!("No foreground window while reading keyboard layout");
    }
    keyboard_layout_klid_for_window(foreground as usize)
}

/// Captures the current foreground window together with its thread layout.
/// The handle lets the caller keep observing the same viewer window while the
/// Windows language flyout or another transient window briefly takes focus.
pub fn foreground_keyboard_layout_context() -> ResultType<(usize, String)> {
    let foreground = unsafe { GetForegroundWindow() };
    if foreground.is_null() {
        bail!("No foreground window while reading keyboard layout");
    }
    let handle = foreground as usize;
    Ok((handle, keyboard_layout_klid_for_window(handle)?))
}

pub fn keyboard_layout_klid_for_window(window_handle: usize) -> ResultType<String> {
    if window_handle == 0 {
        bail!("Invalid window while reading keyboard layout");
    }
    let thread_id = unsafe { GetWindowThreadProcessId(window_handle as HWND, null_mut()) };
    if thread_id == 0 {
        bail!("Failed to resolve window thread while reading keyboard layout");
    }
    let layout = unsafe { GetKeyboardLayout(thread_id) };
    if layout.is_null() {
        bail!("Window thread has no keyboard layout");
    }
    Ok(canonical_keyboard_layout_klid_from_runtime_hkl(
        layout as usize,
    ))
}

#[inline]
pub fn current_process_owns_foreground_window() -> bool {
    let foreground = unsafe { GetForegroundWindow() };
    if foreground.is_null() {
        return false;
    }
    let mut process_id = 0;
    unsafe { GetWindowThreadProcessId(foreground, &mut process_id) };
    process_id == unsafe { GetCurrentProcessId() }
}

fn canonical_keyboard_layout_klid_from_runtime_hkl(layout: usize) -> String {
    format!("{:08X}", layout & 0xFFFF)
}

fn normalized_keyboard_layout_klid(klid: &str) -> ResultType<String> {
    let normalized = klid.trim().to_ascii_uppercase();
    if normalized.len() != 8 || !normalized.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("Invalid Windows keyboard layout KLID");
    }
    let value = u32::from_str_radix(&normalized, 16)?;
    let language_id = value & 0xFFFF;
    // Beta 18 sent a runtime HKL such as 04190419 instead of the loadable
    // KLID 00000419. Preserve real variant KLIDs (for example 00010409), but
    // normalize the common repeated-language runtime form for compatibility.
    if value >> 16 == language_id {
        Ok(format!("{language_id:08X}"))
    } else {
        Ok(normalized)
    }
}

#[inline]
fn keyboard_layout_requires_input_desktop(locked: bool, logon_ui: bool) -> bool {
    locked || logon_ui
}

fn current_thread_desktop_name() -> String {
    unsafe {
        let desktop = GetThreadDesktop(GetCurrentThreadId());
        if desktop.is_null() {
            return "unavailable".to_owned();
        }
        let mut required = 0;
        let _ = GetUserObjectInformationW(
            desktop as *mut c_void,
            UOI_NAME as i32,
            null_mut(),
            0,
            &mut required,
        );
        if required == 0 {
            return "unknown".to_owned();
        }
        let mut buffer = vec![0_u16; (required as usize + 1) / 2];
        if GetUserObjectInformationW(
            desktop as *mut c_void,
            UOI_NAME as i32,
            buffer.as_mut_ptr() as *mut c_void,
            required,
            &mut required,
        ) == FALSE
        {
            return "unknown".to_owned();
        }
        let length = buffer
            .iter()
            .position(|value| *value == 0)
            .unwrap_or(buffer.len());
        OsString::from_wide(&buffer[..length])
            .to_string_lossy()
            .into_owned()
    }
}

fn log_keyboard_layout_apply_context(stage: &str, requested_klid: &str) {
    let foreground = unsafe { GetForegroundWindow() };
    let mut foreground_process_id = 0;
    let foreground_thread_id = if foreground.is_null() {
        0
    } else {
        unsafe { GetWindowThreadProcessId(foreground, &mut foreground_process_id) }
    };
    let current_klid = if foreground_thread_id == 0 {
        "unavailable".to_owned()
    } else {
        let layout = unsafe { GetKeyboardLayout(foreground_thread_id) };
        if layout.is_null() {
            "unavailable".to_owned()
        } else {
            format!("{:08X}", (layout as usize & 0xFFFF_FFFF) as u32)
        }
    };
    log::info!(
        "MD_LAYOUT stage={stage} requested_klid={requested_klid} process_id={} session_id={} desktop={} foreground_hwnd={} foreground_thread_id={foreground_thread_id} foreground_process_id={foreground_process_id} foreground_klid={current_klid}",
        unsafe { GetCurrentProcessId() },
        get_current_process_session_id()
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unavailable".to_owned()),
        current_thread_desktop_name(),
        foreground as usize,
    );
}

fn apply_keyboard_layout_klid_on_current_desktop(klid: &str) -> ResultType<()> {
    log_keyboard_layout_apply_context("target-apply-before-load", klid);
    let wide: Vec<u16> = std::ffi::OsStr::new(klid)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let layout = unsafe { LoadKeyboardLayoutW(wide.as_ptr(), KLF_ACTIVATE) };
    if layout.is_null() {
        bail!(
            "Windows keyboard layout {} is unavailable: {}",
            klid,
            io::Error::last_os_error()
        );
    }
    let target = layout as usize & 0xFFFF_FFFF;
    log::info!(
        "MD_LAYOUT stage=target-layout-loaded requested_klid={klid} loaded_hkl={target:08X}"
    );
    for attempt in 1..=3 {
        let foreground = unsafe { GetForegroundWindow() };
        if foreground.is_null() {
            log::warn!(
                "MD_LAYOUT stage=target-apply-attempt requested_klid={klid} attempt={attempt} result=no-foreground"
            );
            std::thread::sleep(Duration::from_millis(40));
            continue;
        }
        let foreground_thread = unsafe { GetWindowThreadProcessId(foreground, null_mut()) };
        let matches = || {
            if foreground_thread == 0 {
                return false;
            }
            let current = unsafe { GetKeyboardLayout(foreground_thread) };
            !current.is_null() && (current as usize & 0xFFFF_FFFF) == target
        };
        if !matches() {
            let mut result: usize = 0;
            let send_result = unsafe {
                SendMessageTimeoutW(
                    foreground,
                    WM_INPUTLANGCHANGEREQUEST,
                    0,
                    layout as LPARAM,
                    SMTO_ABORTIFHUNG | SMTO_BLOCK,
                    500,
                    &mut result,
                )
            };
            if send_result == 0 {
                log::warn!(
                    "MD_LAYOUT stage=target-language-request requested_klid={klid} attempt={attempt} result=send-failed error={}",
                    io::Error::last_os_error()
                );
                continue;
            }
            log::info!(
                "MD_LAYOUT stage=target-language-request requested_klid={klid} attempt={attempt} result=sent message_result={result}"
            );
        } else {
            log::info!(
                "MD_LAYOUT stage=target-language-request requested_klid={klid} attempt={attempt} result=already-current"
            );
        }
        for _ in 0..10 {
            std::thread::sleep(Duration::from_millis(20));
            if matches() {
                // Require a short stable period. This catches the beta 11/12
                // failure where the indicator changed and a delayed modifier
                // event immediately switched it back.
                std::thread::sleep(Duration::from_millis(80));
                if matches() {
                    log_keyboard_layout_apply_context("target-apply-stable", klid);
                    return Ok(());
                }
                log::warn!(
                    "MD_LAYOUT stage=target-apply-stability requested_klid={klid} attempt={attempt} result=reverted"
                );
                break;
            }
        }
    }
    bail!("Windows did not retain keyboard layout {klid}")
}

/// Applies an exact controller-selected KLID to the controlled foreground window.
/// Reapplying the current layout is intentionally a no-op, so one physical shortcut
/// can first toggle both machines and then deterministically converge them.
pub fn apply_keyboard_layout_klid(klid: &str) -> ResultType<()> {
    let klid = normalized_keyboard_layout_klid(klid)?;
    let locked = is_locked();
    let logon_ui = is_logon_ui().unwrap_or(false);
    let use_input_desktop = keyboard_layout_requires_input_desktop(locked, logon_ui);
    log::info!(
        "MD_LAYOUT stage=target-apply-dispatch requested_klid={klid} locked={locked} logon_ui={logon_ui} route={}",
        if use_input_desktop {
            "input-desktop-worker"
        } else {
            "current-interactive-desktop"
        }
    );
    if use_input_desktop {
        return std::thread::spawn(move || {
            if unsafe { selectInputDesktop() } == FALSE {
                bail!(
                    "Failed to select Windows input desktop for keyboard layout: {}",
                    io::Error::last_os_error()
                );
            }
            log_keyboard_layout_apply_context("target-input-desktop-selected", &klid);
            apply_keyboard_layout_klid_on_current_desktop(&klid)
        })
        .join()
        .map_err(|_| anyhow!("Windows input-desktop keyboard worker panicked"))?;
    }
    apply_keyboard_layout_klid_on_current_desktop(&klid)
}

pub fn get_char_from_unicode(unicode: u16) -> Option<char> {
    let buff = [unicode];
    if let Some(chr) = String::from_utf16(&buff[..1]).ok()?.chars().next() {
        if chr.is_control() {
            return None;
        } else {
            Some(chr)
        }
    } else {
        None
    }
}

pub fn get_unicode_from_vk(vk: u32) -> Option<u16> {
    const BUF_LEN: i32 = 32;
    let mut buff = [0_u16; BUF_LEN as usize];
    let buff_ptr = buff.as_mut_ptr();
    let len = unsafe {
        let current_window_thread_id = GetWindowThreadProcessId(GetForegroundWindow(), null_mut());
        let layout = GetKeyboardLayout(current_window_thread_id);

        // refs: https://github.com/rustdesk-org/rdev/blob/25a99ce71ab42843ad253dd51e6a35e83e87a8a4/src/windows/keyboard.rs#L115
        let press_state = 129;
        let mut state: [BYTE; 256] = [0; 256];
        let shift_left = rdev::get_modifier(rdev::Key::ShiftLeft);
        let shift_right = rdev::get_modifier(rdev::Key::ShiftRight);
        if shift_left {
            state[VK_LSHIFT as usize] = press_state;
        }
        if shift_right {
            state[VK_RSHIFT as usize] = press_state;
        }
        if shift_left || shift_right {
            state[VK_SHIFT as usize] = press_state;
        }
        ToUnicodeEx(vk, 0x00, &state as _, buff_ptr, BUF_LEN, 0, layout)
    };
    if len == 1 {
        Some(buff[0])
    } else {
        None
    }
}

pub fn is_process_consent_running() -> ResultType<bool> {
    let output = std::process::Command::new("cmd")
        .args(&["/C", "tasklist | findstr consent.exe"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()?;
    Ok(output.status.success() && !output.stdout.is_empty())
}

pub struct WakeLock(u32);
// Failed to compile keepawake-rs on i686
impl WakeLock {
    pub fn new(display: bool, idle: bool, sleep: bool) -> Self {
        let mut flag = ES_CONTINUOUS;
        if display {
            flag |= ES_DISPLAY_REQUIRED;
        }
        if idle {
            flag |= ES_SYSTEM_REQUIRED;
        }
        if sleep {
            flag |= ES_AWAYMODE_REQUIRED;
        }
        unsafe { SetThreadExecutionState(flag) };
        WakeLock(flag)
    }

    pub fn set_display(&mut self, display: bool) -> ResultType<()> {
        let flag = if display {
            self.0 | ES_DISPLAY_REQUIRED
        } else {
            self.0 & !ES_DISPLAY_REQUIRED
        };
        if flag != self.0 {
            unsafe { SetThreadExecutionState(flag) };
            self.0 = flag;
        }
        Ok(())
    }
}

impl Drop for WakeLock {
    fn drop(&mut self) {
        unsafe { SetThreadExecutionState(ES_CONTINUOUS) };
    }
}

pub fn uninstall_service(show_new_window: bool, _: bool) -> bool {
    log::info!("Uninstalling service...");
    let filter = format!(" /FI \"PID ne {}\"", get_current_pid());
    Config::set_option("stop-service".into(), "Y".into());
    let cmds = format!(
        "
    chcp 65001
    sc stop {app_name}
    sc delete {app_name}
    if exist \"%PROGRAMDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\{app_name} Tray.lnk\" del /f /q \"%PROGRAMDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\{app_name} Tray.lnk\"
    taskkill /F /IM {broker_exe}
    taskkill /F /IM {app_name}.exe{filter}
    ",
        app_name = crate::get_app_name(),
        broker_exe = WIN_TOPMOST_INJECTED_PROCESS_EXE,
    );
    if let Err(err) = run_cmds(cmds, false, "uninstall") {
        Config::set_option("stop-service".into(), "".into());
        log::debug!("{err}");
        return true;
    }
    run_after_run_cmds(!show_new_window, false);
    std::process::exit(0);
}

pub fn install_service() -> bool {
    log::info!("Installing service...");
    let _installing = crate::platform::InstallingService::new();
    let (_, path, _, exe) = get_install_info();
    let tmp_path = std::env::temp_dir().to_string_lossy().to_string();
    let tray_shortcut = get_tray_shortcut(&path, &exe, &exe, &tmp_path).unwrap_or_default();
    let filter = format!(" /FI \"PID ne {}\"", get_current_pid());
    Config::set_option("stop-service".into(), "".into());
    crate::ipc::EXIT_RECV_CLOSE.store(false, Ordering::Relaxed);
    let cmds = format!(
        "
chcp 65001
taskkill /F /IM {app_name}.exe{filter}
cscript \"{tray_shortcut}\"
copy /Y \"{tmp_path}\\{app_name} Tray.lnk\" \"%PROGRAMDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\\"
{import_config}
{create_service}
if exist \"{tray_shortcut}\" del /f /q \"{tray_shortcut}\"
    ",
        app_name = crate::get_app_name(),
        import_config = get_import_config(&exe),
        create_service = get_create_service(&exe),
    );
    if let Err(err) = run_cmds(cmds, false, "install") {
        Config::set_option("stop-service".into(), "Y".into());
        crate::ipc::EXIT_RECV_CLOSE.store(true, Ordering::Relaxed);
        log::debug!("{err}");
        return true;
    }
    run_after_run_cmds(false, false);
    std::process::exit(0);
}

/// Calculate the total size of a directory in KB
/// Does not follow symlinks to prevent directory traversal attacks.
fn get_directory_size_kb(path: &str) -> u64 {
    let mut total_size = 0u64;
    let mut stack = vec![PathBuf::from(path)];

    while let Some(current_path) = stack.pop() {
        let entries = match std::fs::read_dir(&current_path) {
            Ok(entries) => entries,
            Err(_) => continue,
        };

        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => continue,
            };

            let metadata = match std::fs::symlink_metadata(entry.path()) {
                Ok(metadata) => metadata,
                Err(_) => continue,
            };

            if metadata.is_symlink() {
                continue;
            }

            if metadata.is_dir() {
                stack.push(entry.path());
            } else {
                total_size = total_size.saturating_add(metadata.len());
            }
        }
    }

    total_size / 1024
}

pub fn update_me(debug: bool) -> ResultType<()> {
    let app_name = crate::get_app_name();
    let src_exe = std::env::current_exe()?.to_string_lossy().to_string();
    let (subkey, path, _, exe) = get_install_info();
    let is_installed = std::fs::metadata(&exe).is_ok();
    if !is_installed {
        bail!("{} is not installed.", &app_name);
    }

    let app_exe_name = &format!("{}.exe", &app_name);
    let main_window_pids =
        crate::platform::get_pids_of_process_with_args::<_, &str>(&app_exe_name, &[]);
    let mut main_window_sessions = main_window_pids
        .iter()
        .map(|pid| get_session_id_of_process(pid.as_u32()))
        .flatten()
        .collect::<Vec<_>>();
    main_window_sessions.sort_unstable();
    main_window_sessions.dedup();
    main_window_sessions.retain(|session_id| *session_id != 0);
    preterminate_update_processes(&app_exe_name, "main-window", main_window_pids);
    let tray_pids = crate::platform::get_pids_of_process_with_args(&app_exe_name, &["--tray"]);
    let mut tray_sessions = tray_pids
        .iter()
        .map(|pid| get_session_id_of_process(pid.as_u32()))
        .flatten()
        .collect::<Vec<_>>();
    tray_sessions.sort_unstable();
    tray_sessions.dedup();
    preterminate_update_processes(&app_exe_name, "tray", tray_pids);
    let is_service_running = is_self_service_running();
    let service_should_run = should_restore_service_after_update(
        is_service_running,
        &Config::get_option("stop-service"),
    );

    let mut version_major = "0";
    let mut version_minor = "0";
    let mut version_build = "0";
    let versions: Vec<&str> = crate::VERSION.split(".").collect();
    if versions.len() > 0 {
        version_major = versions[0];
    }
    if versions.len() > 1 {
        version_minor = versions[1];
    }
    if versions.len() > 2 {
        version_build = versions[2];
    }
    let version = application_display_version();
    let size = get_directory_size_kb(&path);
    let build_date = crate::custom_defaults::CUSTOM_BUILD_DATE;
    // Use the icon in the previous installation directory if possible.
    let display_icon = get_custom_icon("", &exe).unwrap_or(exe.to_string());

    let is_msi = is_msi_installed().ok();

    fn get_reg_cmd(
        subkey: &str,
        is_msi: Option<bool>,
        display_icon: &str,
        version: &str,
        build_date: &str,
        version_major: &str,
        version_minor: &str,
        version_build: &str,
        size: u64,
    ) -> String {
        let reg_display_icon = if is_msi.unwrap_or(false) {
            "".to_string()
        } else {
            format!(
                "reg add {} /f /v DisplayIcon /t REG_SZ /d \"{}\"",
                subkey, display_icon
            )
        };
        format!(
            "
{reg_display_icon}
reg add {subkey} /f /v DisplayVersion /t REG_SZ /d \"{version}\"
reg add {subkey} /f /v Version /t REG_SZ /d \"{version}\"
reg add {subkey} /f /v BuildDate /t REG_SZ /d \"{build_date}\"
reg add {subkey} /f /v VersionMajor /t REG_DWORD /d {version_major}
reg add {subkey} /f /v VersionMinor /t REG_DWORD /d {version_minor}
reg add {subkey} /f /v VersionBuild /t REG_DWORD /d {version_build}
reg add {subkey} /f /v EstimatedSize /t REG_DWORD /d {size}
        "
        )
    }

    let reg_cmd = {
        let reg_cmd_main = get_reg_cmd(
            &subkey,
            is_msi,
            &display_icon,
            &version,
            &build_date,
            &version_major,
            &version_minor,
            &version_build,
            size,
        );
        let reg_cmd_msi = if let Some(reg_msi_key) = get_reg_msi_key(&subkey, is_msi) {
            get_reg_cmd(
                &reg_msi_key,
                is_msi,
                &display_icon,
                &version,
                &build_date,
                &version_major,
                &version_minor,
                &version_build,
                size,
            )
        } else {
            "".to_owned()
        };
        format!("{}{}", reg_cmd_main, reg_cmd_msi)
    };

    let filter = format!(" /FI \"PID ne {}\"", get_current_pid());
    let update_failure_label = "masterdesk_update_failed";
    let failure_cmd = format!("goto {update_failure_label}");
    let wait_for_service = wait_for_update_service_stop_cmd(&app_name, update_failure_label);
    let wait_for_processes = wait_for_installed_application_exit_cmd(&app_name, &exe);
    let restore_service_cmd = if service_should_run {
        format!("sc start {} >> \"%MASTERDESK_UPDATE_LOG%\" 2>&1", &app_name)
    } else {
        "".to_owned()
    };
    let copy_exe = copy_exe_cmd_with_failure(
        &src_exe,
        &exe,
        &path,
        &failure_cmd,
        ">> \"%MASTERDESK_UPDATE_LOG%\" 2>&1",
    )?;
    let source_root = Path::new(&src_exe)
        .parent()
        .ok_or(anyhow!("Can't get parent directory of {src_exe}"))?
        .to_string_lossy()
        .to_string();
    let verify_runtime =
        verify_update_runtime_copy_cmd(&src_exe, &exe, &source_root, &path, update_failure_label);

    // No need to check the install option here, `is_rd_printer_installed` rarely fails.
    let is_printer_installed = remote_printer::is_rd_printer_installed(&app_name).unwrap_or(false);
    // Do nothing if the printer is not installed or failed to query if the printer is installed.
    let (uninstall_printer_cmd, install_printer_cmd) = if is_printer_installed {
        (
            format!("\"{}\" --uninstall-remote-printer", &src_exe),
            format!("\"{}\" --install-remote-printer", &src_exe),
        )
    } else {
        ("".to_owned(), "".to_owned())
    };

    // We do not try to remove all files in the old version.
    // Because I don't know whether additional files will be installed here after installation, such as drivers.
    // Just copy files to the installation directory works fine.
    //if exist \"{path}\" rd /s /q \"{path}\"
    // md \"{path}\"
    //
    // We need `taskkill` because:
    // 1. There may be some other processes like `rustdesk --connect` are running.
    // 2. Sometimes, the main window and the tray icon are showing
    // while I cannot find them by `tasklist` or the methods above.
    // There's should be 4 processes running: service, server, tray and main window.
    // But only 2 processes are shown in the tasklist.
    let cmds = format!(
        "
chcp 65001 >nul
setlocal
if not exist \"%ProgramData%\\MasterDesk\" md \"%ProgramData%\\MasterDesk\"
set \"MASTERDESK_UPDATE_LOG=%ProgramData%\\MasterDesk\\update.log\"
set \"MASTERDESK_UPDATE_STAGE=stop-service\"
echo [%date% %time%] MasterDesk update started >> \"%MASTERDESK_UPDATE_LOG%\"
sc stop {app_name} >> \"%MASTERDESK_UPDATE_LOG%\" 2>&1
{wait_for_service}
set \"MASTERDESK_UPDATE_STAGE=stop-installed-processes\"
taskkill /F /IM {app_name}.exe{filter} >> \"%MASTERDESK_UPDATE_LOG%\" 2>&1
{wait_for_processes}
set \"MASTERDESK_UPDATE_STAGE=copy-runtime\"
{copy_exe}
set \"MASTERDESK_UPDATE_STAGE=rename-runtime\"
{rename_exe}
{remove_meta_toml}
set \"MASTERDESK_UPDATE_STAGE=verify-runtime\"
{verify_runtime}
set \"MASTERDESK_UPDATE_STAGE=registry\"
{reg_cmd}
set \"MASTERDESK_UPDATE_STAGE=restore-service\"
{restore_service_cmd}
set \"MASTERDESK_UPDATE_STAGE=printer\"
{uninstall_printer_cmd}
{install_printer_cmd}
{sleep}
set \"MASTERDESK_UPDATE_STAGE=complete\"
echo [%date% %time%] MasterDesk update completed >> \"%MASTERDESK_UPDATE_LOG%\"
goto masterdesk_update_success
:masterdesk_update_failed
if not defined MASTERDESK_UPDATE_ERROR set \"MASTERDESK_UPDATE_ERROR=%ERRORLEVEL%\"
echo [%date% %time%] MasterDesk update failed; stage=%MASTERDESK_UPDATE_STAGE%; error=%MASTERDESK_UPDATE_ERROR% >> \"%MASTERDESK_UPDATE_LOG%\"
sc queryex {app_name} >> \"%MASTERDESK_UPDATE_LOG%\" 2>&1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object Name -ieq '{app_name}.exe' | Select-Object ProcessId, ParentProcessId, SessionId, ExecutablePath | Format-List\" >> \"%MASTERDESK_UPDATE_LOG%\" 2>&1
{restore_service_cmd}
exit /b 1
:masterdesk_update_success
endlocal
    ",
        app_name = app_name,
        copy_exe = copy_exe,
        verify_runtime = verify_runtime,
        rename_exe = rename_exe_cmd(&src_exe, &path)?,
        remove_meta_toml = remove_meta_toml_cmd(is_msi.unwrap_or(true), &path),
        sleep = if debug { "timeout 300" } else { "" },
    );

    let update_completed = Arc::new(AtomicBool::new(false));
    let update_completed_for_restore = update_completed.clone();
    let _restore_session_guard = crate::common::SimpleCallOnReturn {
        b: true,
        f: Box::new(move || {
            let is_root = is_root();
            let use_portable_handoff = update_completed_for_restore.load(Ordering::Acquire);
            if tray_sessions.is_empty() {
                log::info!("No tray process found.");
            } else {
                log::info!(
                    "Try to restore the tray process..., sessions: {:?}",
                    &tray_sessions
                );
                // When not running as root, only spawn once since run_exe_direct
                // doesn't target specific sessions.
                let mut spawned_non_root_tray = false;
                for s in tray_sessions.clone().into_iter() {
                    if s != 0 {
                        // We need to check if is_root here because if `update_me()` is called from
                        // the main window running with administrator permission,
                        // `run_exe_in_session()` will fail with error 1314 ("A required privilege is
                        // not held by the client").
                        //
                        // This issue primarily affects the MSI-installed version running in Administrator
                        // session during testing, but we check permissions here to be safe.
                        if is_root {
                            allow_err!(run_exe_in_session(&exe, vec!["--tray"], s, true));
                        } else if !spawned_non_root_tray {
                            // Only spawn once for non-root since run_exe_direct doesn't take session parameter
                            allow_err!(run_exe_direct(&exe, vec!["--tray"], false));
                            spawned_non_root_tray = true;
                        }
                    }
                }
            }
            if main_window_sessions.is_empty() {
                log::info!("No previous main window found; opening the updated application.");
                let updater_pid = get_current_pid().to_string();
                if is_root {
                    let available_sessions = get_available_sessions(false);
                    if let Some(session_id) =
                        preferred_update_gui_session(&tray_sessions, &available_sessions)
                    {
                        allow_err!(run_exe_in_session(
                            &exe,
                            update_restore_arguments(use_portable_handoff, &updater_pid),
                            session_id,
                            true
                        ));
                    } else {
                        log::warn!(
                            "No interactive Windows session is available for the updated GUI."
                        );
                    }
                } else {
                    allow_err!(run_exe_direct(
                        &exe,
                        update_restore_arguments(use_portable_handoff, &updater_pid),
                        true
                    ));
                }
            } else {
                log::info!("Try to restore the main window process...");
                // When not running as root, only spawn once since run_exe_direct
                // doesn't target specific sessions.
                let mut spawned_non_root_main = false;
                let updater_pid = get_current_pid().to_string();
                for s in main_window_sessions.clone().into_iter() {
                    if s != 0 {
                        if is_root {
                            allow_err!(run_exe_in_session(
                                &exe,
                                update_restore_arguments(use_portable_handoff, &updater_pid),
                                s,
                                true
                            ));
                        } else if !spawned_non_root_main {
                            // Only spawn once for non-root since run_exe_direct doesn't take session parameter
                            allow_err!(run_exe_direct(
                                &exe,
                                update_restore_arguments(use_portable_handoff, &updater_pid),
                                false
                            ));
                            spawned_non_root_main = true;
                        }
                    }
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(300));
        }),
    };

    run_cmds(cmds, debug, "update")?;
    update_completed.store(true, Ordering::Release);

    std::thread::sleep(std::time::Duration::from_millis(2000));
    log::info!("Update completed.");

    Ok(())
}

fn preferred_update_gui_session(
    tray_sessions: &[u32],
    available_sessions: &[WindowsSession],
) -> Option<u32> {
    tray_sessions
        .iter()
        .copied()
        .find(|session_id| *session_id != 0)
        .or_else(|| {
            available_sessions
                .iter()
                .map(|session| session.sid)
                .find(|session_id| *session_id != 0)
        })
}

fn should_restore_service_after_update(was_running: bool, stop_service_option: &str) -> bool {
    was_running || stop_service_option != "Y"
}

fn update_restore_arguments(update_completed: bool, updater_pid: &str) -> Vec<&str> {
    if update_completed {
        vec!["--wait-for-portable", updater_pid]
    } else {
        Vec::new()
    }
}

fn get_reg_msi_key(subkey: &str, is_msi: Option<bool>) -> Option<String> {
    // Only proceed if it's a custom client and MSI is installed.
    // `is_msi.unwrap_or(true)` is intentional: subsequent code validates the registry,
    // hence no early return is required upon MSI detection failure.
    if !(crate::common::is_custom_client() && is_msi.unwrap_or(true)) {
        return None;
    }

    // Get the uninstall string from registry
    let uninstall_string = get_reg_of(subkey, "UninstallString");
    if uninstall_string.is_empty() {
        return None;
    }

    // Find the product code (GUID) in the uninstall string
    // Handle both quoted and unquoted GUIDs: /X {GUID} or /X "{GUID}"
    let start = uninstall_string.rfind('{')?;
    let end = uninstall_string.rfind('}')?;
    if start >= end {
        return None;
    }
    let product_code = &uninstall_string[start..=end];

    // Build the MSI registry key path
    let pos = subkey.rfind('\\')?;
    let reg_msi_key = format!("{}{}", &subkey[..=pos], product_code);

    Some(reg_msi_key)
}

#[derive(Debug, PartialEq, Eq)]
enum NativeUpdateProcessTermination {
    AlreadyExited,
    Terminated,
}

fn terminate_update_process_at_path(
    process_id: u32,
    expected_executable: &Path,
) -> ResultType<NativeUpdateProcessTermination> {
    use hbb_common::platform::windows::RAIIHandle;

    const MASTERDESK_UPDATE_EXIT_CODE: u32 = 0x4D44_5550;
    const PROCESS_IMAGE_PATH_BUFFER_LEN: usize = 32 * 1024;
    const TERMINATION_WAIT_MS: u32 = 5_000;

    unsafe {
        let process = OpenProcess(
            PROCESS_TERMINATE | SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
            FALSE,
            process_id,
        );
        if process.is_null() {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(ERROR_INVALID_PARAMETER as i32) {
                return Ok(NativeUpdateProcessTermination::AlreadyExited);
            }
            bail!(
                "Failed to open update process {} for native termination: {}",
                process_id,
                error
            );
        }
        let _process = RAIIHandle(process);

        let mut buffer = vec![0u16; PROCESS_IMAGE_PATH_BUFFER_LEN];
        let mut length = PROCESS_IMAGE_PATH_BUFFER_LEN as u32;
        if QueryFullProcessImageNameW(process, 0, buffer.as_mut_ptr(), &mut length) == FALSE {
            bail!(
                "Failed to verify update process {} executable path: {}",
                process_id,
                io::Error::last_os_error()
            );
        }
        buffer.truncate(length as usize);
        let actual_executable = PathBuf::from(OsString::from_wide(&buffer));
        if !actual_executable
            .to_string_lossy()
            .eq_ignore_ascii_case(&expected_executable.to_string_lossy())
        {
            bail!(
                "Refusing native update termination because PID {} changed executable path from {:?} to {:?}",
                process_id,
                expected_executable,
                actual_executable
            );
        }

        let initial_wait = WaitForSingleObject(process, 0);
        if initial_wait == WAIT_OBJECT_0 {
            return Ok(NativeUpdateProcessTermination::AlreadyExited);
        }
        if initial_wait != WAIT_TIMEOUT {
            bail!(
                "Failed to inspect update process {} state before native termination: {}",
                process_id,
                io::Error::last_os_error()
            );
        }
        if TerminateProcess(process, MASTERDESK_UPDATE_EXIT_CODE) == FALSE {
            bail!(
                "Failed to terminate update process {} with the native Windows API: {}",
                process_id,
                io::Error::last_os_error()
            );
        }
        let final_wait = WaitForSingleObject(process, TERMINATION_WAIT_MS);
        if final_wait != WAIT_OBJECT_0 {
            bail!(
                "Update process {} did not signal within {} ms after native termination",
                process_id,
                TERMINATION_WAIT_MS
            );
        }
        Ok(NativeUpdateProcessTermination::Terminated)
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
struct UpdateProcessTerminationSummary {
    requested: usize,
    terminated: usize,
    native_terminated: usize,
    deferred: usize,
    skipped_name_mismatch: usize,
    already_exited: usize,
}

// Close visible processes before the elevated batch copies the runtime. Some
// Windows crash paths leave a process object with one terminating thread:
// taskkill and sysinfo report that termination was requested, but the process
// remains unsignaled and keeps the image files mapped. Use one native process
// handle to verify the executable path, inspect the signaled state and perform
// termination. This also prevents PID reuse from targeting an unrelated
// process between independent kill and verification calls.
fn preterminate_update_processes(
    name: &str,
    role: &str,
    pids: Vec<Pid>,
) -> UpdateProcessTerminationSummary {
    let name = name.to_lowercase();
    let s = System::new_all();
    let mut summary = UpdateProcessTerminationSummary {
        requested: pids.len(),
        ..Default::default()
    };
    for pid in pids {
        let pid_value = pid.as_u32();
        let session_id = get_session_id_of_process(pid_value)
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unavailable".to_owned());
        if let Some(process) = s.process(pid) {
            if process.name().to_lowercase() != name {
                summary.skipped_name_mismatch += 1;
                log::warn!(
                    "Skipping MasterDesk update pre-termination because the process name changed: role={}, pid={}, session={}, expected_name={}, actual_name={}, executable={:?}",
                    role,
                    pid_value,
                    session_id,
                    name,
                    process.name(),
                    process.exe()
                );
                continue;
            }
            log::info!(
                "MasterDesk update pre-termination candidate: role={}, pid={}, session={}, executable={:?}",
                role,
                pid_value,
                session_id,
                process.exe()
            );
            match terminate_update_process_at_path(pid_value, process.exe()) {
                Ok(NativeUpdateProcessTermination::AlreadyExited) => {
                    summary.terminated += 1;
                    log::info!(
                        "MasterDesk update pre-termination target was already signaled: role={}, pid={}, session={}",
                        role,
                        pid_value,
                        session_id
                    );
                }
                Ok(NativeUpdateProcessTermination::Terminated) => {
                    summary.terminated += 1;
                    summary.native_terminated += 1;
                    log::warn!(
                        "MasterDesk update pre-termination used verified native Windows termination: role={}, pid={}, session={}, executable={:?}",
                        role,
                        pid_value,
                        session_id,
                        process.exe()
                    );
                }
                Err(error) => {
                    summary.deferred += 1;
                    log::warn!(
                        "MasterDesk update pre-termination could not confirm process exit; deferring to the elevated update batch: role={}, pid={}, session={}, executable={:?}, error={}",
                        role,
                        pid_value,
                        session_id,
                        process.exe(),
                        error
                    );
                }
            }
        } else {
            summary.already_exited += 1;
            log::info!(
                "MasterDesk update pre-termination target already exited: role={}, pid={}, session={}",
                role,
                pid_value,
                session_id
            );
        }
    }
    log::info!(
        "MasterDesk update pre-termination summary: role={}, requested={}, terminated={}, native_terminated={}, deferred={}, skipped_name_mismatch={}, already_exited={}",
        role,
        summary.requested,
        summary.terminated,
        summary.native_terminated,
        summary.deferred,
        summary.skipped_name_mismatch,
        summary.already_exited
    );
    summary
}

pub fn handle_custom_client_staging_dir_before_update(
    custom_client_staging_dir: &PathBuf,
) -> ResultType<()> {
    let Some(current_exe_dir) = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
    else {
        bail!("Failed to get current exe directory");
    };

    // Clean up existing staging directory
    if custom_client_staging_dir.exists() {
        log::debug!(
            "Removing existing custom client staging directory: {:?}",
            custom_client_staging_dir
        );
        if let Err(e) = remove_custom_client_staging_dir(custom_client_staging_dir) {
            bail!(
                "Failed to remove existing custom client staging directory {:?}: {}",
                custom_client_staging_dir,
                e
            );
        }
    }

    let src_path = current_exe_dir.join("custom.txt");
    if src_path.exists() {
        // Verify that custom.txt is not a symlink before copying
        let metadata = match std::fs::symlink_metadata(&src_path) {
            Ok(m) => m,
            Err(e) => {
                bail!(
                    "Failed to read metadata for custom.txt at {:?}: {}",
                    src_path,
                    e
                );
            }
        };

        if metadata.is_symlink() {
            allow_err!(remove_custom_client_staging_dir(&custom_client_staging_dir));
            bail!(
                "custom.txt at {:?} is a symlink, refusing to stage for security reasons.",
                src_path
            );
        }

        if metadata.is_file() {
            if !custom_client_staging_dir.exists() {
                if let Err(e) = std::fs::create_dir_all(custom_client_staging_dir) {
                    bail!("Failed to create parent directory {:?} when staging custom client files: {}", custom_client_staging_dir, e);
                }
            }
            let dst_path = custom_client_staging_dir.join("custom.txt");
            if let Err(e) = std::fs::copy(&src_path, &dst_path) {
                allow_err!(remove_custom_client_staging_dir(&custom_client_staging_dir));
                bail!(
                    "Failed to copy custom txt from {:?} to {:?}: {}",
                    src_path,
                    dst_path,
                    e
                );
            }
        } else {
            log::warn!(
                "custom.txt at {:?} is not a regular file, skipping.",
                src_path
            );
        }
    } else {
        log::info!("No custom txt found to stage for update.");
    }

    Ok(())
}

// Used for auto update and manual update in the main window.
pub fn update_to(file: &str) -> ResultType<()> {
    if file.ends_with(".exe") {
        let custom_client_staging_dir = get_custom_client_staging_dir();
        if crate::is_custom_client() {
            handle_custom_client_staging_dir_before_update(&custom_client_staging_dir)?;
        } else {
            // Clean up any residual staging directory from previous custom client
            allow_err!(remove_custom_client_staging_dir(&custom_client_staging_dir));
        }
        if !run_uac(file, "--update")? {
            bail!(
                "Failed to run the update exe with UAC, error: {:?}",
                std::io::Error::last_os_error()
            );
        }
    } else if file.ends_with(".msi") {
        if let Err(e) = update_me_msi(file, false) {
            bail!("Failed to run the update msi: {}", e);
        }
    } else {
        // unreachable!()
        bail!("Unsupported update file format: {}", file);
    }
    Ok(())
}

const MASTERDESK_RELEASE_DOWNLOAD_PREFIX: &str =
    "https://github.com/Alex777rast/MasterDesk/releases/download/";

fn parse_release_sha256(contents: &str, expected_file_name: &str) -> Option<String> {
    contents.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let hash = parts.next()?;
        let file_name = parts.next()?.trim_start_matches('*');
        if file_name == expected_file_name
            && hash.len() == 64
            && hash.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            Some(hash.to_ascii_lowercase())
        } else {
            None
        }
    })
}

/// Verify a downloaded MasterDesk release before elevating and executing it.
///
/// The package and SHA256.txt are fetched from the same GitHub release
/// directory. Authenticode remains the preferred production trust
/// mechanism once SignPath signing is enabled, while this check prevents a
/// corrupted or mismatched download from being launched.
pub fn verify_masterdesk_update_package(file: &str, download_url: &str) -> ResultType<()> {
    if !download_url.starts_with(MASTERDESK_RELEASE_DOWNLOAD_PREFIX) {
        bail!("The update URL is outside the MasterDesk release repository");
    }
    let Some((release_directory, file_name)) = download_url.rsplit_once('/') else {
        bail!("The update URL is invalid");
    };
    if !crate::custom_defaults::is_expected_masterdesk_update_asset(file_name) {
        bail!("Unexpected MasterDesk update file: {}", file_name);
    }

    let sha256_url = format!("{}/SHA256.txt", release_directory);
    let response = crate::hbbs_http::create_http_client_with_url(&sha256_url)
        .get(&sha256_url)
        .send()?;
    let response = response.error_for_status()?;
    let contents = response.bytes()?;
    if contents.len() > 16 * 1024 {
        bail!("The release checksum file is too large");
    }
    let contents = std::str::from_utf8(&contents)?;
    let Some(expected_hash) = parse_release_sha256(contents, file_name) else {
        bail!("SHA256.txt does not contain a checksum for {}", file_name);
    };

    use sha2::{Digest, Sha256};
    let mut input = std::fs::File::open(file)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    let actual_hash = format!("{:x}", hasher.finalize());
    if actual_hash != expected_hash {
        bail!(
            "SHA-256 mismatch: expected {}, got {}",
            expected_hash,
            actual_hash
        );
    }
    Ok(())
}

// Don't launch tray app when running with `\qn`.
// 1. Because `/qn` requires administrator permission and the tray app should be launched with user permission.
//   Or launching the main window from the tray app will cause the main window to be launched with administrator permission.
// 2. We are not able to launch the tray app if the UI is in the login screen.
// `fn update_me()` can handle the above cases, but for msi update, we need to do more work to handle the above cases.
//    1. Record the tray app session ids.
//    2. Do the update.
//    3. Restore the tray app sessions.
//    `1` and `3` must be done in custom actions.
//    We need also to handle the command line parsing to find the tray processes.
pub fn update_me_msi(msi: &str, quiet: bool) -> ResultType<()> {
    let quiet_args = if quiet { " /qn LAUNCH_TRAY_APP=N" } else { "" };
    let cmds =
        format!("chcp 65001 && msiexec /i \"{msi}\"{quiet_args} REBOOT=ReallySuppress /norestart");
    run_cmds(cmds, false, "update-msi")?;
    Ok(())
}

pub fn get_tray_shortcut(
    install_dir: &str,
    exe: &str,
    icon_source_exe: &str,
    tmp_path: &str,
) -> ResultType<String> {
    let shortcut_icon_location = get_shortcut_icon_location(install_dir, icon_source_exe);
    Ok(write_cmds(
        format!(
            "
Set oWS = WScript.CreateObject(\"WScript.Shell\")
sLinkFile = \"{tmp_path}\\{app_name} Tray.lnk\"

Set oLink = oWS.CreateShortcut(sLinkFile)
    oLink.TargetPath = \"{exe}\"
    oLink.Arguments = \"--tray\"
    {shortcut_icon_location}
oLink.Save
        ",
            app_name = crate::get_app_name(),
        ),
        "vbs",
        "tray_shortcut",
    )?
    .to_str()
    .unwrap_or("")
    .to_owned())
}

fn get_import_config(exe: &str) -> String {
    if config::is_outgoing_only() {
        return "".to_string();
    }
    format!("
sc stop {app_name}
sc delete {app_name}
sc create {app_name} binpath= \"\\\"{exe}\\\" --import-config \\\"{config_path}\\\"\" start= auto DisplayName= \"{app_name} Service\"
sc start {app_name}
sc stop {app_name}
sc delete {app_name}
",
    app_name = crate::get_app_name(),
    config_path=Config::file().to_str().unwrap_or(""),
)
}

fn get_create_service(exe: &str) -> String {
    if config::is_outgoing_only() {
        return "".to_string();
    }
    let stop = Config::get_option("stop-service") == "Y";
    if stop {
        format!("
if exist \"%PROGRAMDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\{app_name} Tray.lnk\" del /f /q \"%PROGRAMDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\{app_name} Tray.lnk\"
", app_name = crate::get_app_name())
    } else {
        format!("
sc create {app_name} binpath= \"\\\"{exe}\\\" --service\" start= auto DisplayName= \"{app_name} Service\"
sc start {app_name}
",
    app_name = crate::get_app_name())
    }
}

fn run_after_run_cmds(silent: bool, wait_for_current_process: bool) {
    let (_, _, _, exe) = get_install_info();
    if !silent {
        log::debug!("Spawn new window");
        if wait_for_current_process {
            let pid = get_current_pid().to_string();
            allow_err!(run_exe_direct(
                &exe,
                vec!["--wait-for-portable", &pid],
                true
            ));
        } else {
            allow_err!(std::process::Command::new("cmd")
                .args(&["/c", "timeout", "/t", "2", "&", &format!("{exe}")])
                .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
                .spawn());
        }
    }
    if Config::get_option("stop-service") != "Y" {
        allow_err!(std::process::Command::new(&exe).arg("--tray").spawn());
    }
    std::thread::sleep(std::time::Duration::from_millis(300));
}

pub fn wait_for_process_exit(process_id: u32, timeout_ms: u32) {
    unsafe {
        let process = OpenProcess(SYNCHRONIZE, FALSE, process_id);
        if process.is_null() {
            log::info!("Portable process {process_id} has already exited.");
            return;
        }
        let result = WaitForSingleObject(process, timeout_ms);
        CloseHandle(process);
        if result == WAIT_TIMEOUT {
            log::warn!(
                "Timed out waiting {timeout_ms} ms for portable process {process_id} to exit."
            );
        } else {
            log::info!("Portable process {process_id} exited; continuing installed GUI startup.");
        }
    }
}

#[inline]
pub fn try_remove_temp_update_files() {
    let temp_dir = std::env::temp_dir();
    let Ok(entries) = std::fs::read_dir(&temp_dir) else {
        log::debug!("Failed to read temp directory: {:?}", temp_dir);
        return;
    };

    let one_hour = std::time::Duration::from_secs(60 * 60);
    for entry in entries {
        if let Ok(entry) = entry {
            let path = entry.path();
            if let Some(file_name) = path.file_name().and_then(|n| n.to_str()) {
                // Match files like rustdesk-*.msi or rustdesk-*.exe
                if file_name.starts_with("rustdesk-")
                    && (file_name.ends_with(".msi") || file_name.ends_with(".exe"))
                {
                    // Skip files modified within the last hour to avoid deleting files being downloaded
                    if let Ok(metadata) = std::fs::metadata(&path) {
                        if let Ok(modified) = metadata.modified() {
                            if let Ok(elapsed) = modified.elapsed() {
                                if elapsed < one_hour {
                                    continue;
                                }
                            }
                        }
                    }
                    if let Err(e) = std::fs::remove_file(&path) {
                        log::debug!("Failed to remove temp update file {:?}: {}", path, e);
                    } else {
                        log::info!("Removed temp update file: {:?}", path);
                    }
                }
            }
        }
    }
}

#[inline]
pub fn try_kill_broker() {
    allow_err!(std::process::Command::new("cmd")
        .arg("/c")
        .arg(&format!(
            "taskkill /F /IM {}",
            WIN_TOPMOST_INJECTED_PROCESS_EXE
        ))
        .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
        .spawn());
}

pub fn message_box(text: &str) {
    let mut text = text.to_owned();
    let nodialog = std::env::var("NO_DIALOG").unwrap_or_default() == "Y";
    if !text.ends_with("!") || nodialog {
        use arboard::Clipboard as ClipboardContext;
        match ClipboardContext::new() {
            Ok(mut ctx) => {
                ctx.set_text(&text).ok();
                if !nodialog {
                    text = format!("{}\n\nAbove text has been copied to clipboard", &text);
                }
            }
            _ => {}
        }
    }
    if nodialog {
        if std::env::var("PRINT_OUT").unwrap_or_default() == "Y" {
            println!("{text}");
        }
        if let Ok(x) = std::env::var("WRITE_TO_FILE") {
            if !x.is_empty() {
                allow_err!(std::fs::write(x, text));
            }
        }
        return;
    }
    let text = text
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect::<Vec<u16>>();
    let caption = "RustDesk Output"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect::<Vec<u16>>();
    unsafe { MessageBoxW(std::ptr::null_mut(), text.as_ptr(), caption.as_ptr(), MB_OK) };
}

pub fn alloc_console() {
    unsafe {
        alloc_console_and_redirect();
    }
}

fn get_license() -> Option<CustomServer> {
    let mut lic: CustomServer = Default::default();
    if let Ok(tmp) = get_license_from_exe_name() {
        lic = tmp;
    } else {
        // for back compatibility from migrating from <= 1.2.1 to 1.2.2
        lic.key = get_reg("Key");
        lic.host = get_reg("Host");
        lic.api = get_reg("Api");
    }
    if lic.key.is_empty() || lic.host.is_empty() {
        return None;
    }
    Some(lic)
}

pub struct WallPaperRemover {
    old_path: String,
}

impl WallPaperRemover {
    pub fn new() -> ResultType<Self> {
        let start = std::time::Instant::now();
        if !Self::need_remove() {
            bail!("already solid color");
        }
        let old_path = match Self::get_recent_wallpaper() {
            Ok(old_path) => old_path,
            Err(e) => {
                log::info!("Failed to get recent wallpaper: {:?}, use fallback", e);
                wallpaper::get().map_err(|e| anyhow!(e.to_string()))?
            }
        };
        Self::set_wallpaper(None)?;
        log::info!(
            "created wallpaper remover,  old_path: {:?},  elapsed: {:?}",
            old_path,
            start.elapsed(),
        );
        Ok(Self { old_path })
    }

    pub fn support() -> bool {
        wallpaper::get().is_ok() || !Self::get_recent_wallpaper().unwrap_or_default().is_empty()
    }

    fn get_recent_wallpaper() -> ResultType<String> {
        // SystemParametersInfoW may return %appdata%\Microsoft\Windows\Themes\TranscodedWallpaper, not real path and may not real cache
        // https://www.makeuseof.com/find-desktop-wallpapers-file-location-windows-11/
        // https://superuser.com/questions/1218413/write-to-current-users-registry-through-a-different-admin-account
        let (hkcu, sid) = if is_root() {
            let sid = get_current_process_session_id().ok_or(anyhow!("failed to get sid"))?;
            (RegKey::predef(HKEY_USERS), format!("{}\\", sid))
        } else {
            (RegKey::predef(HKEY_CURRENT_USER), "".to_string())
        };
        let explorer_key = hkcu.open_subkey_with_flags(
            &format!(
                "{}Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Wallpapers",
                sid
            ),
            KEY_READ,
        )?;
        Ok(explorer_key.get_value("BackgroundHistoryPath0")?)
    }

    fn need_remove() -> bool {
        if let Ok(wallpaper) = wallpaper::get() {
            return !wallpaper.is_empty();
        }
        false
    }

    fn set_wallpaper(path: Option<String>) -> ResultType<()> {
        wallpaper::set_from_path(&path.unwrap_or_default()).map_err(|e| anyhow!(e.to_string()))
    }
}

impl Drop for WallPaperRemover {
    fn drop(&mut self) {
        // If the old background is a slideshow, it will be converted into an image. AnyDesk does the same.
        allow_err!(Self::set_wallpaper(Some(self.old_path.clone())));
    }
}

fn get_uninstall_amyuni_idd() -> String {
    match std::env::current_exe() {
        Ok(path) => format!("\"{}\" --uninstall-amyuni-idd", path.to_str().unwrap_or("")),
        Err(e) => {
            log::warn!("Failed to get current exe path, cannot get command of uninstalling idd, Zzerror: {:?}", e);
            "".to_string()
        }
    }
}

#[inline]
pub fn is_self_service_running() -> bool {
    is_service_running(&crate::get_app_name())
}

pub fn is_service_running(service_name: &str) -> bool {
    unsafe {
        let service_name = wide_string(service_name);
        is_service_running_w(service_name.as_ptr() as _)
    }
}

pub fn is_x64() -> bool {
    const PROCESSOR_ARCHITECTURE_AMD64: u16 = 9;

    let mut sys_info = SYSTEM_INFO::default();
    unsafe {
        GetNativeSystemInfo(&mut sys_info as _);
    }
    unsafe { sys_info.u.s().wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64 }
}

pub fn release_arch_suffix() -> Option<&'static str> {
    match std::env::consts::ARCH {
        "x86_64" => Some("x86_64"),
        "aarch64" => Some("aarch64"),
        _ => None,
    }
}

pub fn try_kill_rustdesk_main_window_process() -> ResultType<()> {
    // Kill rustdesk.exe without extra arg, should only be called by --server
    // We can find the exact process which occupies the ipc, see more from https://github.com/winsiderss/systeminformer
    let app_name = crate::get_app_name().to_lowercase();
    log::info!("try kill main window process");
    use hbb_common::sysinfo::System;
    let mut sys = System::new();
    sys.refresh_processes();
    let my_uid = sys
        .process((std::process::id() as usize).into())
        .map(|x| x.user_id())
        .unwrap_or_default();
    let my_pid = std::process::id();
    if app_name.is_empty() {
        bail!("app name is empty");
    }
    for (_, p) in sys.processes().iter() {
        let p_name = p.name().to_lowercase();
        // name equal
        if !(p_name == app_name || p_name == app_name.clone() + ".exe") {
            continue;
        }
        // arg more than 1
        if p.cmd().len() < 1 {
            continue;
        }
        // first arg contain app name
        if !p.cmd()[0].to_lowercase().contains(&p_name) {
            continue;
        }
        // only one arg or the second arg is empty uni link
        let is_empty_uni = p.cmd().len() == 2 && crate::common::is_empty_uni_link(&p.cmd()[1]);
        if !(p.cmd().len() == 1 || is_empty_uni) {
            continue;
        }
        // skip self
        if p.pid().as_u32() == my_pid {
            continue;
        }
        // because we call it with --server, so we can check user_id, remove this if call it with user process
        if p.user_id() == my_uid {
            log::info!("user id equal, continue");
            continue;
        }
        log::info!("try kill process: {:?}, pid = {:?}", p.cmd(), p.pid());
        nt_terminate_process(p.pid().as_u32())?;
        log::info!("kill process success: {:?}, pid = {:?}", p.cmd(), p.pid());
        return Ok(());
    }
    bail!("failed to find rustdesk main window process");
}

fn nt_terminate_process(process_id: DWORD) -> ResultType<()> {
    type NtTerminateProcess = unsafe extern "system" fn(HANDLE, DWORD) -> DWORD;
    unsafe {
        let h_module = if is_win_10_or_greater() {
            LoadLibraryExA(
                CString::new("ntdll.dll")?.as_ptr(),
                std::ptr::null_mut(),
                LOAD_LIBRARY_SEARCH_SYSTEM32,
            )
        } else {
            LoadLibraryA(CString::new("ntdll.dll")?.as_ptr())
        };
        if !h_module.is_null() {
            let f_nt_terminate_process: NtTerminateProcess = std::mem::transmute(GetProcAddress(
                h_module,
                CString::new("NtTerminateProcess")?.as_ptr(),
            ));
            let h_token = OpenProcess(PROCESS_ALL_ACCESS, 0, process_id);
            if !h_token.is_null() {
                if f_nt_terminate_process(h_token, 1) == 0 {
                    log::info!("terminate process {} success", process_id);
                    CloseHandle(h_token);
                    return Ok(());
                } else {
                    CloseHandle(h_token);
                    bail!("NtTerminateProcess {} failed", process_id);
                }
            } else {
                bail!("OpenProcess {} failed", process_id);
            }
        } else {
            bail!("Failed to load ntdll.dll");
        }
    }
}

pub fn try_set_window_foreground(window: HWND) {
    let env_key = SET_FOREGROUND_WINDOW;
    if let Ok(value) = std::env::var(env_key) {
        if value == "1" {
            unsafe {
                SetForegroundWindow(window);
            }
            std::env::remove_var(env_key);
        }
    }
}

pub mod reg_display_settings {
    use hbb_common::ResultType;
    use serde_derive::{Deserialize, Serialize};
    use std::collections::HashMap;
    use winreg::{enums::*, RegValue};
    const REG_GRAPHICS_DRIVERS_PATH: &str = "SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers";
    const REG_CONNECTIVITY_PATH: &str = "Connectivity";

    #[derive(Serialize, Deserialize, Debug)]
    pub struct RegRecovery {
        path: String,
        key: String,
        old: (Vec<u8>, isize),
        new: (Vec<u8>, isize),
    }

    pub fn read_reg_connectivity() -> ResultType<HashMap<String, HashMap<String, RegValue>>> {
        let hklm = winreg::RegKey::predef(HKEY_LOCAL_MACHINE);
        let reg_connectivity = hklm.open_subkey_with_flags(
            format!("{}\\{}", REG_GRAPHICS_DRIVERS_PATH, REG_CONNECTIVITY_PATH),
            KEY_READ,
        )?;

        let mut map_connectivity = HashMap::new();
        for key in reg_connectivity.enum_keys() {
            let key = key?;
            let mut map_item = HashMap::new();
            let reg_item = reg_connectivity.open_subkey_with_flags(&key, KEY_READ)?;
            for value in reg_item.enum_values() {
                let (name, value) = value?;
                map_item.insert(name, value);
            }
            map_connectivity.insert(key, map_item);
        }
        Ok(map_connectivity)
    }

    pub fn diff_recent_connectivity(
        map1: HashMap<String, HashMap<String, RegValue>>,
        map2: HashMap<String, HashMap<String, RegValue>>,
    ) -> Option<RegRecovery> {
        for (subkey, map_item2) in map2 {
            if let Some(map_item1) = map1.get(&subkey) {
                let key = "Recent";
                if let Some(value1) = map_item1.get(key) {
                    if let Some(value2) = map_item2.get(key) {
                        if value1 != value2 {
                            return Some(RegRecovery {
                                path: format!(
                                    "{}\\{}\\{}",
                                    REG_GRAPHICS_DRIVERS_PATH, REG_CONNECTIVITY_PATH, subkey
                                ),
                                key: key.to_owned(),
                                old: (value1.bytes.clone(), value1.vtype.clone() as isize),
                                new: (value2.bytes.clone(), value2.vtype.clone() as isize),
                            });
                        }
                    }
                }
            }
        }
        None
    }

    pub fn restore_reg_connectivity(reg_recovery: RegRecovery, force: bool) -> ResultType<()> {
        let hklm = winreg::RegKey::predef(HKEY_LOCAL_MACHINE);
        let reg_item = hklm.open_subkey_with_flags(&reg_recovery.path, KEY_READ | KEY_WRITE)?;
        if !force {
            let cur_reg_value = reg_item.get_raw_value(&reg_recovery.key)?;
            let new_reg_value = RegValue {
                bytes: reg_recovery.new.0,
                vtype: isize_to_reg_type(reg_recovery.new.1),
            };
            // Compare if the current value is the same as the new value.
            // If they are not the same, the registry value has been changed by other processes.
            // So we do not restore the registry value.
            if cur_reg_value != new_reg_value {
                return Ok(());
            }
        }
        let reg_value = RegValue {
            bytes: reg_recovery.old.0,
            vtype: isize_to_reg_type(reg_recovery.old.1),
        };
        reg_item.set_raw_value(&reg_recovery.key, &reg_value)?;
        Ok(())
    }

    #[inline]
    fn isize_to_reg_type(i: isize) -> RegType {
        match i {
            0 => RegType::REG_NONE,
            1 => RegType::REG_SZ,
            2 => RegType::REG_EXPAND_SZ,
            3 => RegType::REG_BINARY,
            4 => RegType::REG_DWORD,
            5 => RegType::REG_DWORD_BIG_ENDIAN,
            6 => RegType::REG_LINK,
            7 => RegType::REG_MULTI_SZ,
            8 => RegType::REG_RESOURCE_LIST,
            9 => RegType::REG_FULL_RESOURCE_DESCRIPTOR,
            10 => RegType::REG_RESOURCE_REQUIREMENTS_LIST,
            11 => RegType::REG_QWORD,
            _ => RegType::REG_NONE,
        }
    }
}

pub fn get_printer_names() -> ResultType<Vec<String>> {
    let mut needed_bytes = 0;
    let mut returned_count = 0;

    unsafe {
        // First call to get required buffer size
        EnumPrintersW(
            PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS,
            std::ptr::null_mut(),
            1,
            std::ptr::null_mut(),
            0,
            &mut needed_bytes,
            &mut returned_count,
        );

        let mut buffer = vec![0u8; needed_bytes as usize];

        if EnumPrintersW(
            PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS,
            std::ptr::null_mut(),
            1,
            buffer.as_mut_ptr() as *mut _,
            needed_bytes,
            &mut needed_bytes,
            &mut returned_count,
        ) == 0
        {
            return Err(anyhow!("Failed to enumerate printers"));
        }

        let ptr = buffer.as_ptr() as *const PRINTER_INFO_1W;
        let printers = std::slice::from_raw_parts(ptr, returned_count as usize);

        Ok(printers
            .iter()
            .filter_map(|p| {
                let name = p.pName;
                if !name.is_null() {
                    let mut len = 0;
                    while len < 500 {
                        if name.add(len).is_null() || *name.add(len) == 0 {
                            break;
                        }
                        len += 1;
                    }
                    if len > 0 && len < 500 {
                        Some(String::from_utf16_lossy(std::slice::from_raw_parts(
                            name, len,
                        )))
                    } else {
                        None
                    }
                } else {
                    None
                }
            })
            .collect())
    }
}

extern "C" {
    fn PrintXPSRawData(printer_name: *const u16, raw_data: *const u8, data_size: c_ulong) -> DWORD;
}

pub fn send_raw_data_to_printer(printer_name: Option<String>, data: Vec<u8>) -> ResultType<()> {
    let mut printer_name = printer_name.unwrap_or_default();
    if printer_name.is_empty() {
        // use GetDefaultPrinter to get the default printer name
        let mut needed_bytes = 0;
        unsafe {
            GetDefaultPrinterW(std::ptr::null_mut(), &mut needed_bytes);
        }
        if needed_bytes > 0 {
            let mut default_printer_name = vec![0u16; needed_bytes as usize];
            unsafe {
                GetDefaultPrinterW(
                    default_printer_name.as_mut_ptr() as *mut _,
                    &mut needed_bytes,
                );
            }
            printer_name = String::from_utf16_lossy(&default_printer_name[..needed_bytes as usize]);
        }
    } else {
        if let Ok(names) = crate::platform::windows::get_printer_names() {
            if !names.contains(&printer_name) {
                // Don't set the first printer as current printer.
                // It may not be the desired printer.
                bail!("Printer name \"{}\" not found", &printer_name);
            }
        }
    }
    if printer_name.is_empty() {
        return Err(anyhow!("Failed to get printer name"));
    }

    log::info!("Sending data to printer: {}", &printer_name);
    let printer_name = wide_string(&printer_name);
    unsafe {
        let res = PrintXPSRawData(
            printer_name.as_ptr(),
            data.as_ptr() as *const u8,
            data.len() as c_ulong,
        );
        if res != 0 {
            bail!("Failed to send data to the printer, see logs in C:\\Windows\\temp\\test_rustdesk.log for more details.");
        } else {
            log::info!("Successfully sent data to the printer");
        }
    }

    Ok(())
}

fn get_pids<S: AsRef<str>>(name: S) -> ResultType<Vec<u32>> {
    let name = name.as_ref().to_lowercase();
    let mut pids = Vec::new();

    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)?;
        if snapshot == WinHANDLE::default() {
            return Ok(pids);
        }

        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;

        if Process32FirstW(snapshot, &mut entry).is_ok() {
            loop {
                let proc_name = OsString::from_wide(&entry.szExeFile)
                    .to_string_lossy()
                    .to_lowercase();

                if proc_name.contains(&name) {
                    pids.push(entry.th32ProcessID);
                }

                if !Process32NextW(snapshot, &mut entry).is_ok() {
                    break;
                }
            }
        }

        let _ = WinCloseHandle(snapshot);
    }

    Ok(pids)
}

pub fn is_msi_installed() -> std::io::Result<bool> {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let uninstall_key = hklm.open_subkey(format!(
        "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{}",
        crate::get_app_name()
    ))?;
    Ok(1 == uninstall_key.get_value::<u32, _>("WindowsInstaller")?)
}

pub fn is_cur_exe_the_installed() -> bool {
    let (_, _, _, exe) = get_install_info();
    // Check if is installed, because `exe` is the default path if is not installed.
    if !std::fs::metadata(&exe).is_ok() {
        return false;
    }
    let mut path = std::env::current_exe().unwrap_or_default();
    if let Ok(linked) = path.read_link() {
        path = linked;
    }
    let path = path.to_string_lossy().to_lowercase();
    path == exe.to_lowercase()
}

#[cfg(not(target_pointer_width = "64"))]
pub fn get_pids_with_first_arg_check_session<S1: AsRef<str>, S2: AsRef<str>>(
    name: S1,
    arg: S2,
    same_session_id: bool,
) -> ResultType<Vec<hbb_common::sysinfo::Pid>> {
    // Though `wmic` can return the sessionId, for simplicity we only return processid.
    let pids = get_pids_with_first_arg_by_wmic(name, arg);
    if !same_session_id {
        return Ok(pids);
    }
    let Some(cur_sid) = get_current_process_session_id() else {
        bail!("Can't get current process session id");
    };
    let mut same_session_pids = vec![];
    for pid in pids.into_iter() {
        let mut sid = 0;
        if unsafe { ProcessIdToSessionId(pid.as_u32(), &mut sid) == TRUE } {
            if sid == cur_sid {
                same_session_pids.push(pid);
            }
        } else {
            // Only log here, because this call almost never fails.
            log::warn!(
                "Failed to get session id of the process id, error: {:?}",
                std::io::Error::last_os_error()
            );
        }
    }
    Ok(same_session_pids)
}

#[cfg(not(target_pointer_width = "64"))]
fn get_pids_with_args_from_wmic_output<S2: AsRef<str>>(
    output: std::borrow::Cow<'_, str>,
    name: &str,
    args: &[S2],
) -> Vec<hbb_common::sysinfo::Pid> {
    // CommandLine=
    // ProcessId=33796
    //
    // CommandLine=
    // ProcessId=34668
    //
    // CommandLine="C:\Program Files\RustDesk\RustDesk.exe" --tray
    // ProcessId=13728
    //
    // CommandLine="C:\Program Files\RustDesk\RustDesk.exe"
    // ProcessId=10136
    let mut pids = Vec::new();
    let mut proc_found = false;
    for line in output.lines() {
        if line.starts_with("ProcessId=") {
            if proc_found {
                if let Ok(pid) = line["ProcessId=".len()..].trim().parse::<u32>() {
                    pids.push(hbb_common::sysinfo::Pid::from_u32(pid));
                }
                proc_found = false;
            }
        } else if line.starts_with("CommandLine=") {
            proc_found = false;
            let cmd = line["CommandLine=".len()..].trim().to_lowercase();
            if args.is_empty() {
                if cmd.ends_with(&name) || cmd.ends_with(&format!("{}\"", &name)) {
                    proc_found = true;
                }
            } else {
                proc_found = args.iter().all(|arg| cmd.contains(arg.as_ref()));
            }
        }
    }
    pids
}

// Note the args are not compared strictly, only check if the args are contained in the command line.
// If we want to check the args strictly, we need to parse the command line and compare each arg.
// Maybe we have to introduce some external crate like `shell_words` to do this.
#[cfg(not(target_pointer_width = "64"))]
pub(super) fn get_pids_with_args_by_wmic<S1: AsRef<str>, S2: AsRef<str>>(
    name: S1,
    args: &[S2],
) -> Vec<hbb_common::sysinfo::Pid> {
    let name = name.as_ref().to_lowercase();
    std::process::Command::new("wmic.exe")
        .args([
            "process",
            "where",
            &format!("name='{}'", name),
            "get",
            "commandline,processid",
            "/value",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map(|output| {
            get_pids_with_args_from_wmic_output::<S2>(
                String::from_utf8_lossy(&output.stdout),
                &name,
                args,
            )
        })
        .unwrap_or_default()
}

#[cfg(not(target_pointer_width = "64"))]
fn get_pids_with_first_arg_from_wmic_output(
    output: std::borrow::Cow<'_, str>,
    name: &str,
    arg: &str,
) -> Vec<hbb_common::sysinfo::Pid> {
    let mut pids = Vec::new();
    let mut proc_found = false;
    for line in output.lines() {
        if line.starts_with("ProcessId=") {
            if proc_found {
                if let Ok(pid) = line["ProcessId=".len()..].trim().parse::<u32>() {
                    pids.push(hbb_common::sysinfo::Pid::from_u32(pid));
                }
                proc_found = false;
            }
        } else if line.starts_with("CommandLine=") {
            proc_found = false;
            let cmd = line["CommandLine=".len()..].trim().to_lowercase();
            if cmd.is_empty() {
                continue;
            }
            if !arg.is_empty() && cmd.starts_with(arg) {
                proc_found = true;
            } else {
                for x in [&format!("{}\"", name), &format!("{}", name)] {
                    if cmd.contains(x) {
                        let cmd = cmd.split(x).collect::<Vec<_>>()[1..].join("");
                        if arg.is_empty() {
                            if cmd.trim().is_empty() {
                                proc_found = true;
                            }
                        } else if cmd.trim().starts_with(arg) {
                            proc_found = true;
                        }
                        break;
                    }
                }
            }
        }
    }
    pids
}

// Note the args are not compared strictly, only check if the args are contained in the command line.
// If we want to check the args strictly, we need to parse the command line and compare each arg.
// Maybe we have to introduce some external crate like `shell_words` to do this.
#[cfg(not(target_pointer_width = "64"))]
pub(super) fn get_pids_with_first_arg_by_wmic<S1: AsRef<str>, S2: AsRef<str>>(
    name: S1,
    arg: S2,
) -> Vec<hbb_common::sysinfo::Pid> {
    let name = name.as_ref().to_lowercase();
    let arg = arg.as_ref().to_lowercase();
    std::process::Command::new("wmic.exe")
        .args([
            "process",
            "where",
            &format!("name='{}'", name),
            "get",
            "commandline,processid",
            "/value",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map(|output| {
            get_pids_with_first_arg_from_wmic_output(
                String::from_utf8_lossy(&output.stdout),
                &name,
                &arg,
            )
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_only_the_expected_release_checksum() {
        let expected = "822a049e85156f76920c824f83a8fa9530f2f781f19ebc943ed69e94fb640607";
        let asset = "MasterDesk-1.4.9-10-beta-61-2026-09-05-RDS-x86_64.exe";
        let contents = format!("{}  {}\n{}  other.exe\n", expected, asset, "0".repeat(64));
        assert_eq!(
            parse_release_sha256(&contents, asset),
            Some(expected.to_owned())
        );
        assert_eq!(parse_release_sha256(&contents, "missing.exe"), None);
        assert_eq!(
            parse_release_sha256(&format!("not-a-hash  {}", asset), asset),
            None
        );
    }

    #[test]
    fn update_gui_handoff_never_selects_session_zero() {
        let available = vec![
            WindowsSession {
                sid: 0,
                ..Default::default()
            },
            WindowsSession {
                sid: 3,
                ..Default::default()
            },
        ];
        assert_eq!(preferred_update_gui_session(&[0, 2], &available), Some(2));
        assert_eq!(preferred_update_gui_session(&[0], &available), Some(3));
        assert_eq!(
            preferred_update_gui_session(
                &[0],
                &[WindowsSession {
                    sid: 0,
                    ..Default::default()
                }]
            ),
            None
        );
    }

    #[test]
    fn failed_update_restores_legacy_gui_without_new_handoff_argument() {
        assert!(update_restore_arguments(false, "42").is_empty());
        assert_eq!(
            update_restore_arguments(true, "42"),
            vec!["--wait-for-portable", "42"]
        );
    }

    #[test]
    fn update_restores_the_desired_service_state_after_a_previous_failed_attempt() {
        assert!(should_restore_service_after_update(true, ""));
        assert!(should_restore_service_after_update(false, ""));
        assert!(!should_restore_service_after_update(false, "Y"));
    }

    #[test]
    fn update_service_wait_has_a_force_stop_fallback_and_failure_route() {
        let command = wait_for_update_service_stop_cmd("MasterDesk", "update_failed");
        assert!(command.contains("AddSeconds(10)"));
        assert!(command.contains("Get-CimInstance Win32_Service"));
        assert!(command.contains("taskkill.exe /F /T /PID $servicePid"));
        assert!(command.contains("goto update_failed"));
        assert!(command.contains("%MASTERDESK_UPDATE_LOG%"));
    }

    #[test]
    fn update_process_wait_targets_only_the_installed_executable() {
        let command = wait_for_installed_application_exit_cmd(
            "MasterDesk",
            r"C:\Program Files\MasterDesk\MasterDesk.exe",
        );
        assert!(command.contains(r"C:\Program Files\MasterDesk\MasterDesk.exe"));
        assert!(command.contains("Get-CimInstance Win32_Process"));
        assert!(command.contains("ExecutablePath"));
        assert!(command.contains("AddSeconds(5)"));
        assert!(command.contains("WMI still reports the installed application"));
        assert!(!command.contains("exit 1"));
    }

    #[test]
    fn update_runtime_copy_is_verified_by_hash_before_restart() {
        let command = verify_update_runtime_copy_cmd(
            r"C:\portable\MasterDesk.exe",
            r"C:\Program Files\MasterDesk\MasterDesk.exe",
            r"C:\portable",
            r"C:\Program Files\MasterDesk",
            "masterdesk_update_failed",
        );
        assert!(command.contains("Get-FileHash -Algorithm SHA256"));
        assert!(command.contains("libmasterdesk.dll"));
        assert!(command.contains(r"data\app.so"));
        assert!(command.contains("masterdesk-build-manifest.json"));
        assert!(command.contains("AssetManifest.bin"));
        assert!(command.contains("FontManifest.json"));
        assert!(command.contains("goto masterdesk_update_failed"));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn update_copy_failures_reach_the_cleanup_label() {
        let command = copy_exe_cmd_with_failure(
            r"C:\portable\MasterDesk.exe",
            r"C:\Program Files\MasterDesk\MasterDesk.exe",
            r"C:\Program Files\MasterDesk",
            "goto masterdesk_update_failed",
            r#">> "%MASTERDESK_UPDATE_LOG%" 2>&1"#,
        )
        .unwrap();
        assert!(command.contains("goto masterdesk_update_failed"));
        assert!(!command.contains("exit /b 1"));
        assert!(command.contains(r#">> "%MASTERDESK_UPDATE_LOG%" 2>&1"#));
        assert!(command.contains("MASTERDESK_UPDATE_ERROR=1"));
    }

    #[test]
    fn update_pretermination_does_not_fail_for_stale_or_reused_pids() {
        let missing = preterminate_update_processes(
            "MasterDesk.exe",
            "test-missing",
            vec![(u32::MAX as usize).into()],
        );
        assert_eq!(missing.requested, 1);
        assert_eq!(missing.already_exited, 1);
        assert_eq!(missing.terminated, 0);
        assert_eq!(missing.deferred, 0);

        let current_pid: Pid = (std::process::id() as usize).into();
        let reused = preterminate_update_processes(
            "definitely-not-the-test-process.exe",
            "test-reused",
            vec![current_pid],
        );
        assert_eq!(reused.requested, 1);
        assert_eq!(reused.skipped_name_mismatch, 1);
        assert_eq!(reused.terminated, 0);
        assert_eq!(reused.deferred, 0);
    }

    #[test]
    fn native_update_termination_treats_a_missing_pid_as_already_exited() {
        assert_eq!(
            terminate_update_process_at_path(
                u32::MAX,
                Path::new(r"C:\Program Files\MasterDesk\MasterDesk.exe")
            )
            .unwrap(),
            NativeUpdateProcessTermination::AlreadyExited
        );
    }

    #[test]
    fn native_update_termination_rejects_a_reused_pid_by_executable_path() {
        let error = terminate_update_process_at_path(
            std::process::id(),
            Path::new(r"C:\definitely-not-the-test-process\MasterDesk.exe"),
        )
        .unwrap_err();
        assert!(error.to_string().contains("changed executable path"));
    }

    #[test]
    fn native_update_termination_ends_a_verified_test_process() {
        let mut child = std::process::Command::new("cmd.exe")
            .args(["/D", "/C", "ping.exe 127.0.0.1 -n 30 >nul"])
            .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
            .spawn()
            .unwrap();
        let process_id = child.id();
        let executable = get_process_executable_path(process_id).unwrap();
        let result = terminate_update_process_at_path(process_id, &executable);
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(result.unwrap(), NativeUpdateProcessTermination::Terminated);
    }

    #[test]
    fn update_pretermination_confirms_a_real_test_process_exit() {
        let mut child = std::process::Command::new("cmd.exe")
            .args(["/D", "/C", "ping.exe 127.0.0.1 -n 30 >nul"])
            .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
            .spawn()
            .unwrap();
        let process_id = child.id();
        let summary = preterminate_update_processes(
            "cmd.exe",
            "controlled-test",
            vec![(process_id as usize).into()],
        );
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(summary.requested, 1);
        assert_eq!(summary.terminated, 1);
        assert_eq!(summary.deferred, 0);
    }

    #[test]
    fn settings_cleanup_accepts_only_exact_masterdesk_child_directory() {
        let base = Path::new(r"C:\Users\User\AppData\Roaming");
        assert!(owned_masterdesk_state_path_is_safe(
            base,
            Path::new(r"C:\Users\User\AppData\Roaming\MasterDesk"),
            "MasterDesk"
        ));
        assert!(!owned_masterdesk_state_path_is_safe(
            base,
            Path::new(r"C:\Users\User\AppData\Roaming\RustDesk"),
            "MasterDesk"
        ));
        assert!(!owned_masterdesk_state_path_is_safe(
            base,
            Path::new(r"C:\Users\Other\AppData\Roaming\MasterDesk"),
            "MasterDesk"
        ));
    }

    // Test-only reusable Win32 HANDLE RAII helper.
    // If a future non-test path needs the same pattern, move it out of this test module.
    //
    // This struct is similar to `hbb_common::platform::windows::RAIIHandle`,
    // but `RAIIHandle` depends on `WinApi` crate, while this `HandleGuard` only depends on `windows` crate.
    struct HandleGuard(WinHANDLE);

    impl HandleGuard {
        #[inline]
        fn new(handle: WinHANDLE) -> Self {
            Self(handle)
        }

        #[inline]
        fn get(&self) -> WinHANDLE {
            self.0
        }
    }

    impl Drop for HandleGuard {
        fn drop(&mut self) {
            unsafe {
                if !self.0.is_invalid() {
                    let _ = WinCloseHandle(self.0);
                }
            }
        }
    }

    #[test]
    fn test_is_process_running_as_system_invalid_pid_errors() {
        assert!(is_process_running_as_system(u32::MAX).is_err());
    }

    #[test]
    fn test_is_process_running_as_system_matches_current_process_token_user() {
        let pid = unsafe { windows::Win32::System::Threading::GetCurrentProcessId() };
        let actual = is_process_running_as_system(pid).unwrap();

        let expected = unsafe {
            // Keep this test consistent: use only the `windows` crate APIs/types.
            let process = HandleGuard::new(
                WinOpenProcess(WIN_PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
                    .expect("WinOpenProcess should succeed for current process"),
            );
            let mut token = WinHANDLE::default();
            WinOpenProcessToken(process.get(), WIN_TOKEN_QUERY, &mut token)
                .expect("WinOpenProcessToken should succeed for current process");
            let token = HandleGuard::new(token);

            let mut token_user_size = 0u32;
            let _ = WinGetTokenInformation(token.get(), TokenUser, None, 0, &mut token_user_size);
            assert_ne!(token_user_size, 0, "TokenUser size should be non-zero");

            let mut buffer = vec![0u8; token_user_size as usize];
            WinGetTokenInformation(
                token.get(),
                TokenUser,
                Some(buffer.as_mut_ptr() as *mut core::ffi::c_void),
                token_user_size,
                &mut token_user_size,
            )
            .expect("WinGetTokenInformation(TokenUser) should succeed for current process");

            let min_size = std::mem::size_of::<TOKEN_USER>();
            assert!(
                buffer.len() >= min_size,
                "TokenUser buffer too small (got {}, need >= {})",
                buffer.len(),
                min_size
            );
            let token_user: TOKEN_USER =
                std::ptr::read_unaligned(buffer.as_ptr() as *const TOKEN_USER);
            let expected = IsWellKnownSid(token_user.User.Sid, WinLocalSystemSid).as_bool();
            expected
        };

        assert_eq!(actual, expected);
    }

    #[test]
    fn test_uninstall_cert() {
        println!("uninstall driver certs: {:?}", cert::uninstall_cert());
    }

    #[test]
    fn test_get_unicode_char_by_vk() {
        let chr = get_char_from_vk(0x41); // VK_A
        assert_eq!(chr, Some('a'));
        let chr = get_char_from_vk(VK_ESCAPE as u32); // VK_ESC
        assert_eq!(chr, None)
    }

    #[test]
    fn test_normalized_keyboard_layout_klid() {
        assert_eq!(
            normalized_keyboard_layout_klid("00000409").unwrap(),
            "00000409"
        );
        assert_eq!(
            normalized_keyboard_layout_klid(" 00000419 ").unwrap(),
            "00000419"
        );
        assert_eq!(
            normalized_keyboard_layout_klid("04190419").unwrap(),
            "00000419"
        );
        assert_eq!(
            normalized_keyboard_layout_klid("04090409").unwrap(),
            "00000409"
        );
        assert_eq!(
            normalized_keyboard_layout_klid("00010409").unwrap(),
            "00010409"
        );
        for invalid in ["409", "0000040Z", "000000000409", ""] {
            assert!(normalized_keyboard_layout_klid(invalid).is_err());
        }
    }

    #[test]
    fn test_runtime_hkl_is_converted_to_loadable_klid() {
        // This is the exact beta 18 failure: GetKeyboardLayout returned the
        // repeated-language runtime HKL, which LoadKeyboardLayoutW interpreted
        // as a different request and fell back to English on the test VM.
        assert_eq!(
            canonical_keyboard_layout_klid_from_runtime_hkl(0x0419_0419),
            "00000419"
        );
        assert_eq!(
            canonical_keyboard_layout_klid_from_runtime_hkl(0x0409_0409),
            "00000409"
        );
    }

    #[test]
    fn test_keyboard_layout_uses_secure_input_desktop_when_needed() {
        assert!(!keyboard_layout_requires_input_desktop(false, false));
        assert!(keyboard_layout_requires_input_desktop(true, false));
        assert!(keyboard_layout_requires_input_desktop(false, true));
        assert!(keyboard_layout_requires_input_desktop(true, true));
    }

    #[test]
    fn test_safe_mode_network_plan_contains_service_and_wifi_chain() {
        let entries = safe_mode_network_entries("MasterDesk");
        let names = entries
            .iter()
            .map(|(name, _)| name.as_str())
            .collect::<std::collections::HashSet<_>>();
        assert_eq!(entries.len(), names.len());
        for required in ["MasterDesk", "WlanSvc", "Wcmsvc", "Ndisuio", "nativewifip"] {
            assert!(names.contains(required));
        }
    }

    #[test]
    fn test_windows_safe_mode_metric() {
        assert!(!is_windows_safe_mode(0));
        assert!(is_windows_safe_mode(1));
        assert!(is_windows_safe_mode(2));
    }

    #[test]
    fn test_bcd_safeboot_detection_is_exact() {
        assert!(bcd_output_has_safeboot(
            "identifier {current}\r\nsafeboot Network\r\n"
        ));
        assert!(bcd_output_has_safeboot("  SAFEBOOT Minimal\n"));
        assert!(!bcd_output_has_safeboot(
            "identifier {current}\r\ndescription Windows 10\r\n"
        ));
        assert!(!bcd_output_has_safeboot("safebootalternateshell Yes\n"));
    }

    #[test]
    fn test_stale_stop_service_is_cleared_only_without_an_installation() {
        assert!(should_clear_stale_stop_service(false, "Y"));
        assert!(!should_clear_stale_stop_service(true, "Y"));
        assert!(!should_clear_stale_stop_service(false, ""));
        assert!(!should_clear_stale_stop_service(false, "N"));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn test_flutter_install_copy_requires_complete_runtime_payload() {
        let command = copy_raw_cmd(
            r"C:\portable\rustdesk.exe",
            r"C:\Program Files\MasterDesk\MasterDesk.exe",
            r"C:\Program Files\MasterDesk",
        )
        .unwrap();
        for required in [
            r"C:\portable\data\app.so",
            r"C:\portable\data\icudtl.dat",
            r"C:\portable\data\flutter_assets\AssetManifest.bin",
            r"C:\Program Files\MasterDesk\data\app.so",
            r"C:\Program Files\MasterDesk\data\icudtl.dat",
            r"C:\Program Files\MasterDesk\data\flutter_assets\AssetManifest.bin",
        ] {
            assert!(
                command.contains(required),
                "missing payload check: {required}"
            );
        }
        assert!(command.contains("for /L %%I in (1,1,15)"));
        assert!(command.contains("if not defined MASTERDESK_COPY_OK exit /b 1"));
        assert!(!command.contains(" /C "));
    }

    #[test]
    fn test_update_waits_for_old_processes_before_copying_runtime() {
        let command = wait_for_application_exit_cmd("MasterDesk", " /FI \"PID ne 42\"", "update");
        assert!(command.contains("IMAGENAME eq MasterDesk.exe"));
        assert!(command.contains("PID ne 42"));
        assert!(command.contains("taskkill /F /IM MasterDesk.exe"));
        assert!(command.contains(":masterdesk_update_processes_stopped"));
        assert!(command.contains("if not errorlevel 1 exit /b 1"));

        let service = wait_for_service_stop_cmd("MasterDesk");
        assert!(service.contains("Get-Service -Name 'MasterDesk'"));
        assert!(service.contains("if ($null -eq $service) { exit 0 }"));
        assert!(service.contains("WaitForStatus('Stopped'"));
        assert!(service.contains("if errorlevel 1 exit /b 1"));
    }

    #[test]
    fn test_uninstall_disables_service_and_kills_process_trees_before_waiting() {
        let command = get_before_uninstall(false);
        assert!(command.contains("sc config MasterDesk start= disabled"));
        assert!(command.contains("sc failure MasterDesk reset= 0 actions= \"\""));
        assert!(command.contains("taskkill /F /T /IM MasterDesk.exe /FI \"PID ne "));
        assert!(command.contains(":masterdesk_uninstall_processes_stopped"));

        let parent_wait = wait_for_process_exit_cmd("MasterDesk", 42, "uninstall");
        assert!(parent_wait.contains("PID eq 42"));
        assert!(parent_wait.contains(":masterdesk_uninstall_launcher_stopped"));
        assert!(parent_wait.contains("exit /b 1"));

        let launcher = detached_batch_launcher(Path::new(r"C:\Temp\MasterDesk cleanup.bat"));
        assert!(launcher.contains("start \"\" /B cmd.exe /D /C call"));
        assert!(launcher.contains(r#""C:\Temp\MasterDesk cleanup.bat""#));
    }

    #[cfg(not(target_pointer_width = "64"))]
    #[test]
    fn test_get_pids_with_args_from_wmic_output() {
        let output = r#"
CommandLine=
ProcessId=33796

CommandLine=
ProcessId=34668

CommandLine="C:\Program Files\testapp\TestApp.exe" --tray
ProcessId=13728

CommandLine="C:\Program Files\testapp\TestApp.exe"
ProcessId=10136
"#;
        let name = "testapp.exe";
        let args = vec!["--tray"];
        let pids = super::get_pids_with_args_from_wmic_output(
            String::from_utf8_lossy(output.as_bytes()),
            name,
            &args,
        );
        assert_eq!(pids.len(), 1);
        assert_eq!(pids[0].as_u32(), 13728);

        let args: Vec<&str> = vec![];
        let pids = super::get_pids_with_args_from_wmic_output(
            String::from_utf8_lossy(output.as_bytes()),
            name,
            &args,
        );
        assert_eq!(pids.len(), 1);
        assert_eq!(pids[0].as_u32(), 10136);

        let args = vec!["--other"];
        let pids = super::get_pids_with_args_from_wmic_output(
            String::from_utf8_lossy(output.as_bytes()),
            name,
            &args,
        );
        assert_eq!(pids.len(), 0);
    }

    #[cfg(not(target_pointer_width = "64"))]
    #[test]
    fn test_get_pids_with_first_arg_from_wmic_output() {
        let output = r#"
CommandLine=
ProcessId=33796

CommandLine=
ProcessId=34668

CommandLine="C:\Program Files\testapp\TestApp.exe" --tray
ProcessId=13728

CommandLine="C:\Program Files\testapp\TestApp.exe"
ProcessId=10136
    "#;
        let name = "testapp.exe";
        let arg = "--tray";
        let pids = super::get_pids_with_first_arg_from_wmic_output(
            String::from_utf8_lossy(output.as_bytes()),
            name,
            arg,
        );
        assert_eq!(pids.len(), 1);
        assert_eq!(pids[0].as_u32(), 13728);

        let arg = "";
        let pids = super::get_pids_with_first_arg_from_wmic_output(
            String::from_utf8_lossy(output.as_bytes()),
            name,
            arg,
        );
        assert_eq!(pids.len(), 1);
        assert_eq!(pids[0].as_u32(), 10136);

        let arg = "--other";
        let pids = super::get_pids_with_first_arg_from_wmic_output(
            String::from_utf8_lossy(output.as_bytes()),
            name,
            arg,
        );
        assert_eq!(pids.len(), 0);
    }
}
