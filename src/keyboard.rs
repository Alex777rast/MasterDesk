#[cfg(feature = "flutter")]
use crate::flutter;
#[cfg(target_os = "windows")]
use crate::platform::windows::{get_char_from_vk, get_unicode_from_vk};
#[cfg(not(feature = "flutter"))]
use crate::ui::CUR_SESSION;
use crate::ui_session_interface::{InvokeUiSession, Session};
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use crate::{client::get_key_state, common::GrabState};
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use hbb_common::log;
use hbb_common::message_proto::*;
#[cfg(any(target_os = "windows", target_os = "macos"))]
use rdev::KeyCode;
use rdev::{Event, EventType, Key};
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

#[cfg(windows)]
static mut IS_ALT_GR: bool = false;

#[allow(dead_code)]
const OS_LOWER_WINDOWS: &str = "windows";
#[allow(dead_code)]
const OS_LOWER_LINUX: &str = "linux";
#[allow(dead_code)]
const OS_LOWER_MACOS: &str = "macos";
#[allow(dead_code)]
const OS_LOWER_ANDROID: &str = "android";

#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
static KEYBOARD_HOOKED: AtomicBool = AtomicBool::new(false);

#[cfg(target_os = "windows")]
static WINDOWS_LAYOUT_TRACE_ID: AtomicU64 = AtomicU64::new(0);

#[cfg(target_os = "windows")]
const WINDOWS_LAYOUT_SYNC_POLL_INTERVAL: std::time::Duration =
    std::time::Duration::from_millis(20);
#[cfg(target_os = "windows")]
const WINDOWS_LAYOUT_SYNC_SETTLE_DELAY: std::time::Duration =
    std::time::Duration::from_millis(60);
#[cfg(target_os = "windows")]
const WINDOWS_LAYOUT_SYNC_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(1_000);

#[cfg(target_os = "windows")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WindowsLayoutHotkeyTransition {
    None,
    Started,
    Ended,
}

#[cfg(target_os = "windows")]
#[derive(Default)]
struct WindowsLayoutHotkeyState {
    alt_left: bool,
    control_left: bool,
    control_right: bool,
    shift_left: bool,
    shift_right: bool,
    chord_active: bool,
    sync_pending: bool,
}

#[cfg(target_os = "windows")]
struct WindowsLayoutSyncTarget {
    trace_id: u64,
    window_handle: usize,
    initial_layout: String,
}

#[cfg(target_os = "windows")]
impl WindowsLayoutHotkeyState {
    fn update(
        &mut self,
        key: Key,
        is_press: bool,
        position_code: u32,
    ) -> WindowsLayoutHotkeyTransition {
        match key {
            Key::Alt => self.alt_left = is_press,
            // 0x021D is the synthetic control event generated for AltGr.
            Key::ControlLeft if position_code != 0x021D => self.control_left = is_press,
            Key::ControlRight => self.control_right = is_press,
            Key::ShiftLeft => self.shift_left = is_press,
            Key::ShiftRight => self.shift_right = is_press,
            _ => {}
        }
        let shift = self.shift_left || self.shift_right;
        let chord = shift && (self.alt_left || self.control_left || self.control_right);
        let any_layout_modifier =
            shift || self.alt_left || self.control_left || self.control_right;
        let transition = if chord && !self.chord_active && !self.sync_pending {
            self.sync_pending = true;
            WindowsLayoutHotkeyTransition::Started
        } else if !any_layout_modifier && self.sync_pending {
            self.sync_pending = false;
            WindowsLayoutHotkeyTransition::Ended
        } else {
            WindowsLayoutHotkeyTransition::None
        };
        self.chord_active = chord;
        transition
    }
}

// Track key down state for relative mouse mode exit shortcut.
// macOS: Cmd+G (track G key)
// Windows/Linux: Ctrl+Alt (track whichever modifier was pressed last)
// This prevents the exit from retriggering on OS key-repeat.
#[cfg(all(
    feature = "flutter",
    any(target_os = "windows", target_os = "macos", target_os = "linux")
))]
static EXIT_SHORTCUT_KEY_DOWN: AtomicBool = AtomicBool::new(false);

// Track whether relative mouse mode is currently active.
// This is set by Flutter via set_relative_mouse_mode_state() and checked
// by the rdev grab loop to determine if exit shortcuts should be processed.
#[cfg(all(
    feature = "flutter",
    any(target_os = "windows", target_os = "macos", target_os = "linux")
))]
static RELATIVE_MOUSE_MODE_ACTIVE: AtomicBool = AtomicBool::new(false);

/// Set the relative mouse mode state from Flutter.
/// This is called when entering or exiting relative mouse mode.
#[cfg(all(
    feature = "flutter",
    any(target_os = "windows", target_os = "macos", target_os = "linux")
))]
pub fn set_relative_mouse_mode_state(active: bool) {
    RELATIVE_MOUSE_MODE_ACTIVE.store(active, Ordering::SeqCst);
    // Reset exit shortcut state when mode changes to avoid stale state
    if !active {
        EXIT_SHORTCUT_KEY_DOWN.store(false, Ordering::SeqCst);
    }
}

#[cfg(feature = "flutter")]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
static IS_RDEV_ENABLED: AtomicBool = AtomicBool::new(false);

lazy_static::lazy_static! {
    static ref TO_RELEASE: Arc<Mutex<HashMap<Key, Event>>> = Arc::new(Mutex::new(HashMap::new()));
    static ref MODIFIERS_STATE: Mutex<HashMap<Key, bool>> = {
        let mut m = HashMap::new();
        m.insert(Key::ShiftLeft, false);
        m.insert(Key::ShiftRight, false);
        m.insert(Key::ControlLeft, false);
        m.insert(Key::ControlRight, false);
        m.insert(Key::Alt, false);
        m.insert(Key::AltGr, false);
        m.insert(Key::MetaLeft, false);
        m.insert(Key::MetaRight, false);
        Mutex::new(m)
    };
    #[cfg(target_os = "windows")]
    static ref WINDOWS_LAYOUT_HOTKEY_STATE: Mutex<WindowsLayoutHotkeyState> =
        Mutex::new(WindowsLayoutHotkeyState::default());
}

#[cfg(target_os = "windows")]
fn send_windows_keyboard_layout_target(trace_id: u64, klid: String) {
    #[cfg(not(feature = "flutter"))]
    if let Some(session) = CUR_SESSION.lock().unwrap().as_ref() {
        log::info!(
            "MD_LAYOUT trace={trace_id} stage=controller-session-resolved source=legacy klid={klid}"
        );
        session.send_keyboard_layout_target(klid);
        return;
    }
    #[cfg(feature = "flutter")]
    if let Some(session) = flutter::get_cur_session() {
        log::info!(
            "MD_LAYOUT trace={trace_id} stage=controller-session-resolved source=flutter klid={klid}"
        );
        session.send_keyboard_layout_target(klid);
        return;
    }
    log::warn!("MD_LAYOUT trace={trace_id} stage=controller-session-missing klid={klid}");
}

#[cfg(target_os = "windows")]
#[inline]
fn windows_keyboard_layout_changed(initial: Option<&str>, current: &str) -> bool {
    initial.map(|value| value != current).unwrap_or(true)
}

#[cfg(target_os = "windows")]
#[inline]
fn windows_layout_sync_source_matches_selection(
    event_source: &str,
    selected_input_source: &str,
) -> bool {
    matches!(
        (event_source, selected_input_source),
        (
            "input-source-1-rdev",
            input_source::CONFIG_INPUT_SOURCE_1
        ) | (
            "input-source-2-flutter",
            input_source::CONFIG_INPUT_SOURCE_1
        ) | (
            "input-source-2-flutter",
            input_source::CONFIG_INPUT_SOURCE_2
        )
    )
}

#[cfg(target_os = "windows")]
fn schedule_windows_keyboard_layout_sync(
    key: Key,
    is_press: bool,
    position_code: u32,
    input_source: &'static str,
    event_origin: &'static str,
) {
    static SYNC_TARGET: Mutex<Option<WindowsLayoutSyncTarget>> = Mutex::new(None);

    if !matches!(
        key,
        Key::Alt
            | Key::ControlLeft
            | Key::ControlRight
            | Key::ShiftLeft
            | Key::ShiftRight
            | Key::AltGr
    ) {
        return;
    }
    let selected_input_source = input_source::get_cur_session_input_source();
    if !windows_layout_sync_source_matches_selection(input_source, &selected_input_source) {
        log::debug!(
            "MD_LAYOUT stage=controller-modifier-ignored source={input_source} selected={selected_input_source}"
        );
        return;
    }
    let (transition, modifier_state) = {
        let mut state = WINDOWS_LAYOUT_HOTKEY_STATE.lock().unwrap();
        let transition = state.update(key, is_press, position_code);
        let modifier_state = format!(
            "alt={} ctrl_left={} ctrl_right={} shift_left={} shift_right={} pending={}",
            state.alt_left,
            state.control_left,
            state.control_right,
            state.shift_left,
            state.shift_right,
            state.sync_pending
        );
        (transition, modifier_state)
    };
    log::info!(
        "MD_LAYOUT stage=controller-modifier source={input_source} origin={event_origin} key={key:?} action={} scan=0x{position_code:X} transition={transition:?} {modifier_state}",
        if is_press { "down" } else { "up" }
    );
    if transition == WindowsLayoutHotkeyTransition::Started {
        let trace_id = WINDOWS_LAYOUT_TRACE_ID.fetch_add(1, Ordering::SeqCst) + 1;
        let foreground_owned = crate::platform::windows::current_process_owns_foreground_window();
        *SYNC_TARGET.lock().unwrap() = if foreground_owned {
            match crate::platform::windows::foreground_keyboard_layout_context() {
                Ok((window_handle, initial_layout)) => {
                    log::info!(
                        "MD_LAYOUT trace={trace_id} stage=controller-chord-start source={input_source} foreground_owned=true hwnd={window_handle} pre_klid={initial_layout}"
                    );
                    Some(WindowsLayoutSyncTarget {
                        trace_id,
                        window_handle,
                        initial_layout,
                    })
                }
                Err(err) => {
                    log::warn!(
                        "MD_LAYOUT trace={trace_id} stage=controller-context-failed source={input_source} error={err}"
                    );
                    None
                }
            }
        } else {
            log::warn!(
                "MD_LAYOUT trace={trace_id} stage=controller-context-rejected source={input_source} foreground_owned=false"
            );
            None
        };
        return;
    }
    if transition != WindowsLayoutHotkeyTransition::Ended {
        return;
    }
    // Do not send the authoritative KLID while the physical chord is still
    // active. Windows can commit a layout on key-up, and a later forwarded
    // release would otherwise toggle the controlled desktop back again.
    let Some(target) = SYNC_TARGET.lock().unwrap().take() else {
        log::warn!(
            "MD_LAYOUT stage=controller-chord-end source={input_source} target_context=missing"
        );
        return;
    };
    log::info!(
        "MD_LAYOUT trace={} stage=controller-all-modifiers-released source={input_source}",
        target.trace_id
    );
    std::thread::spawn(move || {
        let started = std::time::Instant::now();
        loop {
            std::thread::sleep(WINDOWS_LAYOUT_SYNC_POLL_INTERVAL);
            let Ok(current_layout) =
                crate::platform::windows::keyboard_layout_klid_for_window(target.window_handle)
            else {
                if started.elapsed() >= WINDOWS_LAYOUT_SYNC_TIMEOUT {
                    log::warn!(
                        "MD_LAYOUT trace={} stage=controller-post-klid-timeout hwnd={}",
                        target.trace_id,
                        target.window_handle
                    );
                    return;
                }
                continue;
            };
            if windows_keyboard_layout_changed(
                Some(target.initial_layout.as_str()),
                &current_layout,
            ) {
                log::info!(
                    "MD_LAYOUT trace={} stage=controller-post-klid pre_klid={} post_klid={current_layout}",
                    target.trace_id,
                    target.initial_layout
                );
                // Let the already-forwarded modifier sequence finish remotely, then
                // make the controller's exact final KLID authoritative.
                std::thread::sleep(WINDOWS_LAYOUT_SYNC_SETTLE_DELAY);
                log::info!(
                    "MD_LAYOUT trace={} stage=controller-message-form klid={current_layout}",
                    target.trace_id
                );
                send_windows_keyboard_layout_target(target.trace_id, current_layout);
                return;
            }
            if started.elapsed() >= WINDOWS_LAYOUT_SYNC_TIMEOUT {
                // One installed layout (or a disabled Windows shortcut): keep the
                // controlled side aligned with the unchanged controller layout.
                log::info!(
                    "MD_LAYOUT trace={} stage=controller-post-klid-unchanged klid={current_layout}",
                    target.trace_id
                );
                send_windows_keyboard_layout_target(target.trace_id, current_layout);
                return;
            }
        }
    });
}

#[cfg(all(target_os = "windows", feature = "flutter"))]
fn windows_layout_modifier_from_usb_hid(usb_hid: i32) -> Option<(Key, u32)> {
    match usb_hid {
        0xE0 => Some((Key::ControlLeft, 0x1D)),
        0xE1 => Some((Key::ShiftLeft, 0x2A)),
        0xE2 => Some((Key::Alt, 0x38)),
        0xE4 => Some((Key::ControlRight, 0xE01D)),
        0xE5 => Some((Key::ShiftRight, 0x36)),
        0xE6 => Some((Key::AltGr, 0xE038)),
        _ => None,
    }
}

#[cfg(all(target_os = "windows", feature = "flutter"))]
pub fn schedule_windows_keyboard_layout_sync_from_flutter(usb_hid: i32, is_press: bool) {
    if let Some((key, position_code)) = windows_layout_modifier_from_usb_hid(usb_hid) {
        schedule_windows_keyboard_layout_sync(
            key,
            is_press,
            position_code,
            "input-source-2-flutter",
            "flutter-event-origin-unavailable",
        );
    }
}

pub mod client {
    use super::*;

    /// Tracks grab ownership and serializes transitions across threads.
    ///
    /// Multiple Flutter isolates (one per session window) call
    /// `change_grab_status(Run/Wait)` concurrently. Without serialization a
    /// stale `Wait` from session A can clobber session B's freshly acquired
    /// grab on any desktop OS.
    ///
    /// Windows and macOS are less susceptible in practice because the Flutter
    /// side triggers `enterView` only after a mouse click inside the window,
    /// but we cannot rely on that. On Linux/X11, `XGrabKeyboard` can also
    /// cause a focus-change feedback loop (~10 Hz), so `last_grab` debounces
    /// spurious `Wait` events that arrive shortly after a `Run`.
    #[derive(Default)]
    struct GrabOwnerState {
        owner: Option<u128>,
        last_grab: Option<std::time::Instant>,
        /// True while a deferred-release thread is in flight. Prevents
        /// spawning redundant threads during the X11 feedback loop.
        deferred_pending: bool,
    }

    /// How long after a grab acquisition we suppress Wait from the same session.
    /// Must exceed one full X11 feedback cycle (~100 ms: 50 ms enable + 50 ms disable).
    #[cfg(target_os = "linux")]
    const GRAB_DEBOUNCE_MS: u128 = 300;

    lazy_static::lazy_static! {
        static ref IS_GRAB_STARTED: Arc<Mutex<bool>> = Arc::new(Mutex::new(false));
        static ref GRAB_STATE: Arc<Mutex<GrabOwnerState>> = Arc::new(Mutex::new(GrabOwnerState::default()));
    }

    #[cfg(target_os = "linux")]
    lazy_static::lazy_static! {
        static ref GRAB_OP_LOCK: Mutex<()> = Mutex::new(());
    }

    #[cfg(target_os = "linux")]
    fn apply_run_grab_if_owner(session_id: u128, disable_first: bool) {
        let _lock = GRAB_OP_LOCK.lock().unwrap();
        let gs = GRAB_STATE.lock().unwrap();
        if gs.owner != Some(session_id) {
            return;
        }
        drop(gs);
        if disable_first {
            log::debug!("[grab] handoff: disable_grab before re-grab");
            rdev::disable_grab();
        }
        rdev::enable_grab();
    }

    #[cfg(target_os = "linux")]
    fn disable_grab_if_released() {
        let _lock = GRAB_OP_LOCK.lock().unwrap();
        let should_disable = {
            let gs = GRAB_STATE.lock().unwrap();
            gs.owner.is_none() && gs.last_grab.is_none()
        };
        if should_disable {
            rdev::disable_grab();
        }
    }

    pub fn start_grab_loop() {
        let mut lock = IS_GRAB_STARTED.lock().unwrap();
        if *lock {
            return;
        }
        super::start_grab_loop();
        *lock = true;
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub fn change_grab_status(state: GrabState, keyboard_mode: &str, session_id: u128) {
        #[cfg(feature = "flutter")]
        if !IS_RDEV_ENABLED.load(Ordering::SeqCst) {
            return;
        }
        // Serialize transitions so a stale `Wait` from a previous owner cannot
        // clobber a fresh `Run` from a different session window.
        let mut release_after_unlock = None;
        #[cfg(target_os = "linux")]
        let mut run_grab_after_unlock = None;
        #[cfg(target_os = "linux")]
        let mut disable_after_unlock = false;
        let mut gs = GRAB_STATE.lock().unwrap();
        match state {
            GrabState::Ready => {}
            GrabState::Run => {
                #[cfg(windows)]
                update_grab_get_key_name(keyboard_mode);

                // Idempotent: if this session already owns the grab, just
                // refresh the debounce timer (proves the session is still
                // actively focused) and skip the actual grab call.
                if gs.owner == Some(session_id) {
                    gs.last_grab = Some(std::time::Instant::now());
                    // Reset so the next Wait can spawn a fresh deferred-release
                    // timer with an up-to-date snapshot of last_grab.
                    gs.deferred_pending = false;
                    log::debug!(
                        "[grab] Run(0x{:x}): already owner, refresh debounce",
                        session_id
                    );
                    return;
                }

                log::debug!(
                    "[grab] Run(0x{:x}): prev_owner={}, mode={}",
                    session_id,
                    gs.owner
                        .map_or("none".to_string(), |id| format!("0x{:x}", id)),
                    keyboard_mode,
                );

                #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
                KEYBOARD_HOOKED.store(true, Ordering::SeqCst);

                #[cfg(target_os = "linux")]
                let had_owner = gs.owner.is_some();
                gs.owner = Some(session_id);
                gs.last_grab = Some(std::time::Instant::now());
                // Invalidate any in-flight deferred release from the previous
                // owner so it cannot suppress a fresh timer for the new owner.
                gs.deferred_pending = false;
                #[cfg(target_os = "linux")]
                {
                    run_grab_after_unlock = Some(had_owner);
                }
            }
            GrabState::Wait => {
                // Drop stale `Wait` events that do not correspond to the
                // current grab owner. This prevents a late PointerExit from
                // session A from releasing session B's freshly acquired grab.
                if gs.owner != Some(session_id) {
                    log::debug!(
                        "[grab] Wait(0x{:x}): ignored, owner={}",
                        session_id,
                        gs.owner
                            .map_or("none".to_string(), |id| format!("0x{:x}", id)),
                    );
                    return;
                }

                // Debounce: on Linux/X11, XGrabKeyboard causes a focus-change
                // feedback loop (grab -> PointerExit -> ungrab -> PointerEnter ->
                // grab -> ...). Suppress Wait if the grab was acquired recently
                // by this same session -- it is X11 feedback, not a real leave.
                // A deferred release is scheduled so that a genuine leave within
                // the debounce window is not permanently lost.
                #[cfg(target_os = "linux")]
                if let Some(t) = gs.last_grab {
                    let elapsed = t.elapsed().as_millis();
                    if elapsed < GRAB_DEBOUNCE_MS {
                        if !gs.deferred_pending {
                            log::debug!(
                                "[grab] Wait(0x{:x}): debounced ({}ms < {}ms), scheduling deferred release",
                                session_id, elapsed, GRAB_DEBOUNCE_MS,
                            );
                            gs.deferred_pending = true;
                            let remaining = (GRAB_DEBOUNCE_MS - elapsed) as u64 + 50;
                            let snapshot = gs.last_grab;
                            let mode = keyboard_mode.to_string();
                            std::thread::spawn(move || {
                                std::thread::sleep(std::time::Duration::from_millis(remaining));
                                let release_keys = {
                                    let mut gs = GRAB_STATE.lock().unwrap();
                                    // Release only if no new Run has refreshed the grab since.
                                    if gs.owner == Some(session_id) && gs.last_grab == snapshot {
                                        let to_release = take_remote_keys();
                                        gs.deferred_pending = false;
                                        log::debug!(
                                            "[grab] Wait(0x{:x}): deferred release",
                                            session_id
                                        );
                                        KEYBOARD_HOOKED.store(false, Ordering::SeqCst);
                                        gs.owner = None;
                                        gs.last_grab = None;
                                        Some(to_release)
                                    } else {
                                        log::debug!(
                                            "[grab] Wait(0x{:x}): deferred release cancelled (grab refreshed)",
                                            session_id,
                                        );
                                        None
                                    }
                                };
                                if let Some(to_release) = release_keys {
                                    disable_grab_if_released();
                                    release_remote_keys_for_events(&mode, to_release);
                                }
                            });
                        } else {
                            log::debug!(
                                "[grab] Wait(0x{:x}): debounced, deferred release already pending",
                                session_id,
                            );
                        }
                        return;
                    }
                }

                log::debug!("[grab] Wait(0x{:x}): releasing grab", session_id);

                #[cfg(windows)]
                rdev::set_get_key_unicode(false);

                #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
                KEYBOARD_HOOKED.store(false, Ordering::SeqCst);

                gs.owner = None;
                gs.last_grab = None;
                gs.deferred_pending = false;
                release_after_unlock = Some(take_remote_keys());
                #[cfg(target_os = "linux")]
                {
                    disable_after_unlock = true;
                }
            }
            GrabState::Exit => {}
        }
        drop(gs);
        #[cfg(target_os = "linux")]
        {
            if disable_after_unlock {
                disable_grab_if_released();
            }
            if let Some(disable_first) = run_grab_after_unlock {
                apply_run_grab_if_owner(session_id, disable_first);
            }
        }
        if let Some(to_release) = release_after_unlock {
            release_remote_keys_for_events(keyboard_mode, to_release);
        }
    }

    pub fn process_event(keyboard_mode: &str, event: &Event, lock_modes: Option<i32>) {
        let keyboard_mode = get_keyboard_mode_enum(keyboard_mode);
        if is_long_press(&event) {
            return;
        }
        let peer = get_peer_platform().to_lowercase();
        for key_event in event_to_key_events(peer, &event, keyboard_mode, lock_modes) {
            send_key_event(&key_event);
        }
    }

    pub fn process_event_with_session<T: InvokeUiSession>(
        keyboard_mode: &str,
        event: &Event,
        lock_modes: Option<i32>,
        session: &Session<T>,
    ) {
        let keyboard_mode = get_keyboard_mode_enum(keyboard_mode);
        if is_long_press(&event) {
            return;
        }
        let peer = session.peer_platform().to_lowercase();
        for key_event in event_to_key_events(peer, &event, keyboard_mode, lock_modes) {
            session.send_key_event(&key_event);
        }
    }

    pub fn get_modifiers_state(
        alt: bool,
        ctrl: bool,
        shift: bool,
        command: bool,
    ) -> (bool, bool, bool, bool) {
        let modifiers_lock = MODIFIERS_STATE.lock().unwrap();
        let ctrl = *modifiers_lock.get(&Key::ControlLeft).unwrap()
            || *modifiers_lock.get(&Key::ControlRight).unwrap()
            || ctrl;
        let shift = *modifiers_lock.get(&Key::ShiftLeft).unwrap()
            || *modifiers_lock.get(&Key::ShiftRight).unwrap()
            || shift;
        let command = *modifiers_lock.get(&Key::MetaLeft).unwrap()
            || *modifiers_lock.get(&Key::MetaRight).unwrap()
            || command;
        let alt = *modifiers_lock.get(&Key::Alt).unwrap()
            || *modifiers_lock.get(&Key::AltGr).unwrap()
            || alt;

        (alt, ctrl, shift, command)
    }

    pub fn legacy_modifiers(
        key_event: &mut KeyEvent,
        alt: bool,
        ctrl: bool,
        shift: bool,
        command: bool,
    ) {
        if alt
            && !crate::is_control_key(&key_event, &ControlKey::Alt)
            && !crate::is_control_key(&key_event, &ControlKey::RAlt)
        {
            key_event.modifiers.push(ControlKey::Alt.into());
        }
        if shift
            && !crate::is_control_key(&key_event, &ControlKey::Shift)
            && !crate::is_control_key(&key_event, &ControlKey::RShift)
        {
            key_event.modifiers.push(ControlKey::Shift.into());
        }
        if ctrl
            && !crate::is_control_key(&key_event, &ControlKey::Control)
            && !crate::is_control_key(&key_event, &ControlKey::RControl)
        {
            key_event.modifiers.push(ControlKey::Control.into());
        }
        if command
            && !crate::is_control_key(&key_event, &ControlKey::Meta)
            && !crate::is_control_key(&key_event, &ControlKey::RWin)
        {
            key_event.modifiers.push(ControlKey::Meta.into());
        }
    }

    #[cfg(target_os = "android")]
    pub fn map_key_to_control_key(key: &rdev::Key) -> Option<ControlKey> {
        match key {
            Key::Alt => Some(ControlKey::Alt),
            Key::ShiftLeft => Some(ControlKey::Shift),
            Key::ControlLeft => Some(ControlKey::Control),
            Key::MetaLeft => Some(ControlKey::Meta),
            Key::AltGr => Some(ControlKey::RAlt),
            Key::ShiftRight => Some(ControlKey::RShift),
            Key::ControlRight => Some(ControlKey::RControl),
            Key::MetaRight => Some(ControlKey::RWin),
            _ => None,
        }
    }

    pub fn event_lock_screen() -> KeyEvent {
        let mut key_event = KeyEvent::new();
        key_event.set_control_key(ControlKey::LockScreen);
        key_event.down = true;
        key_event.mode = KeyboardMode::Legacy.into();
        key_event
    }

    #[inline]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub fn lock_screen() {
        send_key_event(&event_lock_screen());
    }

    pub fn event_ctrl_alt_del() -> KeyEvent {
        let mut key_event = KeyEvent::new();
        if get_peer_platform() == "Windows" {
            key_event.set_control_key(ControlKey::CtrlAltDel);
            key_event.down = true;
        } else {
            key_event.set_control_key(ControlKey::Delete);
            legacy_modifiers(&mut key_event, true, true, false, false);
            key_event.press = true;
        }
        key_event.mode = KeyboardMode::Legacy.into();
        key_event
    }

    #[inline]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub fn ctrl_alt_del() {
        send_key_event(&event_ctrl_alt_del());
    }
}

#[cfg(windows)]
pub fn update_grab_get_key_name(keyboard_mode: &str) {
    match keyboard_mode {
        "map" => rdev::set_get_key_unicode(false),
        "translate" => rdev::set_get_key_unicode(true),
        "legacy" => rdev::set_get_key_unicode(true),
        _ => {}
    };
}

#[cfg(target_os = "windows")]
static mut IS_0X021D_DOWN: bool = false;

#[cfg(target_os = "macos")]
static mut IS_LEFT_OPTION_DOWN: bool = false;

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn get_keyboard_mode() -> String {
    #[cfg(not(feature = "flutter"))]
    if let Some(session) = CUR_SESSION.lock().unwrap().as_ref() {
        return session.get_keyboard_mode();
    }
    #[cfg(feature = "flutter")]
    if let Some(session) = flutter::get_cur_session() {
        return session.get_keyboard_mode();
    }
    "legacy".to_string()
}

/// Check if exit shortcut for relative mouse mode is active.
/// Exit shortcuts (only exits, not toggles):
/// - macOS: Cmd+G
/// - Windows/Linux: Ctrl+Alt (triggered when both are pressed)
/// Note: This shortcut is only available in Flutter client. Sciter client does not support relative mouse mode.
#[cfg(feature = "flutter")]
#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
fn is_exit_relative_mouse_shortcut(key: Key) -> bool {
    let modifiers = MODIFIERS_STATE.lock().unwrap();

    #[cfg(target_os = "macos")]
    {
        // macOS: Cmd+G to exit
        if key != Key::KeyG {
            return false;
        }
        let meta = *modifiers.get(&Key::MetaLeft).unwrap_or(&false)
            || *modifiers.get(&Key::MetaRight).unwrap_or(&false);
        return meta;
    }

    #[cfg(not(target_os = "macos"))]
    {
        // Windows/Linux: Ctrl+Alt to exit
        // Triggered when Ctrl is pressed while Alt is down, or Alt is pressed while Ctrl is down
        let is_ctrl_key = key == Key::ControlLeft || key == Key::ControlRight;
        let is_alt_key = key == Key::Alt || key == Key::AltGr;

        if !is_ctrl_key && !is_alt_key {
            return false;
        }

        let ctrl = *modifiers.get(&Key::ControlLeft).unwrap_or(&false)
            || *modifiers.get(&Key::ControlRight).unwrap_or(&false);
        let alt = *modifiers.get(&Key::Alt).unwrap_or(&false)
            || *modifiers.get(&Key::AltGr).unwrap_or(&false);

        // When Ctrl is pressed and Alt is already down, or vice versa
        (is_ctrl_key && alt) || (is_alt_key && ctrl)
    }
}

/// Notify Flutter to exit relative mouse mode.
/// Note: This is Flutter-only. Sciter client does not support relative mouse mode.
#[cfg(feature = "flutter")]
#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
fn notify_exit_relative_mouse_mode() {
    let session_id = flutter::get_cur_session_id();
    flutter::push_session_event(&session_id, "exit_relative_mouse_mode", vec![]);
}

/// Handle relative mouse mode shortcuts in the rdev grab loop.
/// Returns true if the event should be blocked from being sent to the peer.
#[cfg(feature = "flutter")]
#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
#[inline]
fn can_exit_relative_mouse_mode_from_grab_loop() -> bool {
    // Only process exit shortcuts when relative mouse mode is actually active.
    // This prevents blocking Ctrl+Alt (or Cmd+G) when not in relative mouse mode.
    if !RELATIVE_MOUSE_MODE_ACTIVE.load(Ordering::SeqCst) {
        return false;
    }

    let Some(session) = flutter::get_cur_session() else {
        return false;
    };

    // Only for remote desktop sessions.
    if !session.is_default() {
        return false;
    }

    // Must have keyboard permission and not be in view-only mode.
    if !*session.server_keyboard_enabled.read().unwrap() {
        return false;
    }
    let lc = session.lc.read().unwrap();
    if lc.view_only.v {
        return false;
    }

    // Peer must support relative mouse mode.
    crate::common::is_support_relative_mouse_mode_num(lc.version)
}

#[cfg(feature = "flutter")]
#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
#[inline]
fn should_block_relative_mouse_shortcut(key: Key, is_press: bool) -> bool {
    if !KEYBOARD_HOOKED.load(Ordering::SeqCst) {
        return false;
    }

    // Determine which key to track for key-up blocking based on platform
    #[cfg(target_os = "macos")]
    let is_tracked_key = key == Key::KeyG;
    #[cfg(not(target_os = "macos"))]
    let is_tracked_key =
        key == Key::ControlLeft || key == Key::ControlRight || key == Key::Alt || key == Key::AltGr;

    // Block key up if key down was blocked (to avoid orphan key up event on remote).
    // This must be checked before clearing the flag below.
    if is_tracked_key && !is_press && EXIT_SHORTCUT_KEY_DOWN.swap(false, Ordering::SeqCst) {
        return true;
    }

    // Exit relative mouse mode shortcuts:
    // - macOS: Cmd+G
    // - Windows/Linux: Ctrl+Alt
    // Guard it to supported/eligible sessions to avoid blocking the chord unexpectedly.
    if is_exit_relative_mouse_shortcut(key) {
        if !can_exit_relative_mouse_mode_from_grab_loop() {
            return false;
        }
        if is_press {
            // Only trigger exit on transition from "not pressed" to "pressed".
            // This prevents retriggering on OS key-repeat.
            if !EXIT_SHORTCUT_KEY_DOWN.swap(true, Ordering::SeqCst) {
                notify_exit_relative_mouse_mode();
            }
        }
        return true;
    }

    false
}

/// Input source 1 uses the native rdev hook instead of Flutter key routing.
/// Let Windows observe only modifier events after they have also been sent to
/// the peer. This preserves local Alt+Shift/Ctrl+Shift layout shortcuts while
/// ordinary remote keys and shortcuts remain captured by MasterDesk.
#[cfg(target_os = "windows")]
#[inline]
fn should_pass_windows_modifier_to_platform(key: &Key) -> bool {
    matches!(
        key,
        Key::ControlLeft
            | Key::ControlRight
            | Key::ShiftLeft
            | Key::ShiftRight
            | Key::Alt
            | Key::AltGr
    )
}

/// Print Screen belongs to capture tools on the Windows controller. Unlike
/// layout modifiers, it must be passed to Windows without first being sent to
/// the peer, for both key-down and key-up.
#[cfg(target_os = "windows")]
#[inline]
fn should_keep_windows_key_local(key: &Key) -> bool {
    matches!(key, Key::PrintScreen)
}

fn start_grab_loop() {
    std::env::set_var("KEYBOARD_ONLY", "y");
    #[cfg(any(target_os = "windows", target_os = "macos"))]
    std::thread::spawn(move || {
        let try_handle_keyboard = move |event: Event, key: Key, is_press: bool| -> Option<Event> {
            // fix #2211：CAPS LOCK don't work
            if key == Key::CapsLock || key == Key::NumLock {
                return Some(event);
            }

            #[cfg(target_os = "windows")]
            if should_keep_windows_key_local(&key) {
                return Some(event);
            }

            let _scan_code = event.position_code;
            let _code = event.platform_code as KeyCode;

            #[cfg(feature = "flutter")]
            if should_block_relative_mouse_shortcut(key, is_press) {
                return None;
            }

            #[cfg(target_os = "windows")]
            schedule_windows_keyboard_layout_sync(
                key,
                is_press,
                _scan_code,
                "input-source-1-rdev",
                if event.extra_data == enigo::ENIGO_INPUT_EXTRA_VALUE {
                    "masterdesk-injected"
                } else if event.extra_data == 0 {
                    "physical-or-unmarked-injected"
                } else {
                    "foreign-tagged"
                },
            );

            let res = if KEYBOARD_HOOKED.load(Ordering::SeqCst) {
                client::process_event(&get_keyboard_mode(), &event, None);

                #[cfg(target_os = "windows")]
                let pass_modifier_to_platform = should_pass_windows_modifier_to_platform(&key);
                #[cfg(not(target_os = "windows"))]
                let pass_modifier_to_platform = false;

                if is_press && !pass_modifier_to_platform {
                    None
                } else {
                    Some(event)
                }
            } else {
                Some(event)
            };

            #[cfg(target_os = "windows")]
            match _scan_code {
                0x1D | 0x021D => rdev::set_modifier(Key::ControlLeft, is_press),
                0xE01D => rdev::set_modifier(Key::ControlRight, is_press),
                0x2A => rdev::set_modifier(Key::ShiftLeft, is_press),
                0x36 => rdev::set_modifier(Key::ShiftRight, is_press),
                0x38 => rdev::set_modifier(Key::Alt, is_press),
                // Right Alt
                0xE038 => rdev::set_modifier(Key::AltGr, is_press),
                0xE05B => rdev::set_modifier(Key::MetaLeft, is_press),
                0xE05C => rdev::set_modifier(Key::MetaRight, is_press),
                _ => {}
            }

            #[cfg(target_os = "windows")]
            unsafe {
                // AltGr
                if _scan_code == 0x021D {
                    IS_0X021D_DOWN = is_press;
                }
            }

            #[cfg(target_os = "macos")]
            unsafe {
                if _code == rdev::kVK_Option {
                    IS_LEFT_OPTION_DOWN = is_press;
                }
            }

            return res;
        };
        let func = move |event: Event| match event.event_type {
            EventType::KeyPress(key) => try_handle_keyboard(event, key, true),
            EventType::KeyRelease(key) => try_handle_keyboard(event, key, false),
            _ => Some(event),
        };
        #[cfg(target_os = "macos")]
        rdev::set_is_main_thread(false);
        #[cfg(target_os = "windows")]
        rdev::set_event_popup(false);
        if let Err(error) = rdev::grab(func) {
            log::error!("rdev Error: {:?}", error)
        }
    });

    #[cfg(target_os = "linux")]
    if let Err(err) = rdev::start_grab_listen(move |event: Event| match event.event_type {
        EventType::KeyPress(key) | EventType::KeyRelease(key) => {
            let is_press = matches!(event.event_type, EventType::KeyPress(_));
            if let Key::Unknown(keycode) = key {
                log::error!("rdev get unknown key, keycode is {:?}", keycode);
            } else {
                #[cfg(feature = "flutter")]
                if should_block_relative_mouse_shortcut(key, is_press) {
                    return None;
                }
                client::process_event(&get_keyboard_mode(), &event, None);
            }
            None
        }
        _ => Some(event),
    }) {
        log::error!("Failed to init rdev grab thread: {:?}", err);
    };
}

#[cfg(all(test, target_os = "windows"))]
mod tests {
    use super::*;

    #[test]
    fn windows_native_grab_passes_only_layout_modifiers_to_platform() {
        for key in [
            Key::ControlLeft,
            Key::ControlRight,
            Key::ShiftLeft,
            Key::ShiftRight,
            Key::Alt,
            Key::AltGr,
        ] {
            assert!(should_pass_windows_modifier_to_platform(&key));
        }

        for key in [Key::KeyA, Key::F4, Key::Tab, Key::MetaLeft] {
            assert!(!should_pass_windows_modifier_to_platform(&key));
        }
    }

    #[test]
    fn windows_native_grab_keeps_print_screen_local_only() {
        assert!(should_keep_windows_key_local(&Key::PrintScreen));

        for key in [Key::Print, Key::KeyA, Key::F12] {
            assert!(!should_keep_windows_key_local(&key));
        }
    }

    #[test]
    fn windows_layout_hotkey_triggers_once_per_physical_chord() {
        let mut state = WindowsLayoutHotkeyState::default();
        assert_eq!(
            state.update(Key::Alt, true, 0x38),
            WindowsLayoutHotkeyTransition::None
        );
        assert_eq!(
            state.update(Key::ShiftLeft, true, 0x2A),
            WindowsLayoutHotkeyTransition::Started
        );
        assert_eq!(
            state.update(Key::ShiftLeft, true, 0x2A),
            WindowsLayoutHotkeyTransition::None
        );
        assert_eq!(
            state.update(Key::ShiftLeft, false, 0x2A),
            WindowsLayoutHotkeyTransition::None
        );
        assert_eq!(
            state.update(Key::ShiftLeft, true, 0x2A),
            WindowsLayoutHotkeyTransition::None
        );
        assert_eq!(
            state.update(Key::ShiftLeft, false, 0x2A),
            WindowsLayoutHotkeyTransition::None
        );
        assert_eq!(
            state.update(Key::Alt, false, 0x38),
            WindowsLayoutHotkeyTransition::Ended
        );
    }

    #[test]
    fn windows_layout_hotkey_supports_ctrl_shift_and_ignores_altgr_control() {
        let mut state = WindowsLayoutHotkeyState::default();
        assert_eq!(
            state.update(Key::ShiftRight, true, 0x36),
            WindowsLayoutHotkeyTransition::None
        );
        assert_eq!(
            state.update(Key::ControlRight, true, 0xE01D),
            WindowsLayoutHotkeyTransition::Started
        );

        let mut altgr = WindowsLayoutHotkeyState::default();
        assert_eq!(
            altgr.update(Key::ShiftLeft, true, 0x2A),
            WindowsLayoutHotkeyTransition::None
        );
        assert_eq!(
            altgr.update(Key::ControlLeft, true, 0x021D),
            WindowsLayoutHotkeyTransition::None
        );
        assert_eq!(
            altgr.update(Key::AltGr, true, 0xE038),
            WindowsLayoutHotkeyTransition::None
        );
    }

    #[test]
    fn windows_layout_sync_waits_for_the_first_changed_layout() {
        assert!(!windows_keyboard_layout_changed(
            Some("00000409"),
            "00000409"
        ));
        assert!(windows_keyboard_layout_changed(
            Some("00000409"),
            "00000419"
        ));
        assert!(windows_keyboard_layout_changed(None, "00000419"));
    }

    #[test]
    fn windows_layout_sync_accepts_flutter_fallback_for_native_source() {
        assert!(windows_layout_sync_source_matches_selection(
            "input-source-1-rdev",
            input_source::CONFIG_INPUT_SOURCE_1
        ));
        // RDP can consume Alt+Shift before the native low-level hook sees it,
        // while Flutter still receives the focused Viewer key events.
        assert!(windows_layout_sync_source_matches_selection(
            "input-source-2-flutter",
            input_source::CONFIG_INPUT_SOURCE_1
        ));
        assert!(windows_layout_sync_source_matches_selection(
            "input-source-2-flutter",
            input_source::CONFIG_INPUT_SOURCE_2
        ));
        assert!(!windows_layout_sync_source_matches_selection(
            "input-source-1-rdev",
            input_source::CONFIG_INPUT_SOURCE_2
        ));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn windows_flutter_layout_modifier_hid_mapping_covers_both_hotkeys() {
        for (usb_hid, key, scan_code) in [
            (0xE0, Key::ControlLeft, 0x1D),
            (0xE1, Key::ShiftLeft, 0x2A),
            (0xE2, Key::Alt, 0x38),
            (0xE4, Key::ControlRight, 0xE01D),
            (0xE5, Key::ShiftRight, 0x36),
            (0xE6, Key::AltGr, 0xE038),
        ] {
            assert_eq!(
                windows_layout_modifier_from_usb_hid(usb_hid),
                Some((key, scan_code))
            );
        }
        assert_eq!(windows_layout_modifier_from_usb_hid(0x2C), None);
    }

    #[test]
    fn windows_map_mode_preserves_space_and_letter_scan_codes() {
        for (key, scan_code) in [(Key::Space, 0x39), (Key::KeyP, 0x19)] {
            let event = Event {
                event_type: EventType::KeyPress(key),
                time: std::time::SystemTime::now(),
                unicode: None,
                platform_code: 0,
                position_code: scan_code,
                usb_hid: 0,
                extra_data: 0,
            };
            let mapped = map_keyboard_mode(OS_LOWER_WINDOWS, &event, KeyEvent::new());
            assert_eq!(mapped.len(), 1);
            assert!(mapped[0].down);
            assert_eq!(mapped[0].union, Some(key_event::Union::Chr(scan_code)));
        }
    }
}

// #[allow(dead_code)] is ok here. No need to stop grabbing loop.
#[allow(dead_code)]
fn stop_grab_loop() -> Result<(), rdev::GrabError> {
    #[cfg(any(target_os = "windows", target_os = "macos"))]
    rdev::exit_grab()?;
    #[cfg(target_os = "linux")]
    rdev::exit_grab_listen();
    Ok(())
}

pub fn is_long_press(event: &Event) -> bool {
    let keys = MODIFIERS_STATE.lock().unwrap();
    match event.event_type {
        EventType::KeyPress(k) => {
            if let Some(&state) = keys.get(&k) {
                if state == true {
                    return true;
                }
            }
        }
        _ => {}
    };
    return false;
}

fn take_remote_keys() -> HashMap<Key, Event> {
    let mut to_release = TO_RELEASE.lock().unwrap();
    std::mem::take(&mut *to_release)
}

fn release_remote_keys_for_events(keyboard_mode: &str, to_release: HashMap<Key, Event>) {
    for (key, mut event) in to_release.into_iter() {
        event.event_type = EventType::KeyRelease(key);
        client::process_event(keyboard_mode, &event, None);
        // If Alt or AltGr is pressed, we need to send another key stoke to release it.
        // Because the controlled side may hold the alt state, if local window is switched by [Alt + Tab].
        if key == Key::Alt || key == Key::AltGr {
            event.event_type = EventType::KeyPress(key);
            client::process_event(keyboard_mode, &event, None);
            event.event_type = EventType::KeyRelease(key);
            client::process_event(keyboard_mode, &event, None);
        }
    }
}

#[allow(dead_code)]
pub fn release_remote_keys(keyboard_mode: &str) {
    // todo!: client quit suddenly, how to release keys?
    release_remote_keys_for_events(keyboard_mode, take_remote_keys());
}

pub fn get_keyboard_mode_enum(keyboard_mode: &str) -> KeyboardMode {
    match keyboard_mode {
        "map" => KeyboardMode::Map,
        "translate" => KeyboardMode::Translate,
        "legacy" => KeyboardMode::Legacy,
        _ => KeyboardMode::Map,
    }
}

#[inline]
pub fn is_modifier(key: &rdev::Key) -> bool {
    matches!(
        key,
        Key::ShiftLeft
            | Key::ShiftRight
            | Key::ControlLeft
            | Key::ControlRight
            | Key::MetaLeft
            | Key::MetaRight
            | Key::Alt
            | Key::AltGr
    )
}

#[inline]
#[allow(dead_code)]
pub fn is_modifier_code(evt: &KeyEvent) -> bool {
    match evt.union {
        Some(key_event::Union::Chr(code)) => {
            let key = rdev::linux_key_from_code(code);
            is_modifier(&key)
        }
        _ => false,
    }
}

#[inline]
pub fn is_numpad_rdev_key(key: &rdev::Key) -> bool {
    matches!(
        key,
        Key::Kp0
            | Key::Kp1
            | Key::Kp2
            | Key::Kp3
            | Key::Kp4
            | Key::Kp5
            | Key::Kp6
            | Key::Kp7
            | Key::Kp8
            | Key::Kp9
            | Key::KpMinus
            | Key::KpMultiply
            | Key::KpDivide
            | Key::KpPlus
            | Key::KpDecimal
    )
}

#[inline]
pub fn is_letter_rdev_key(key: &rdev::Key) -> bool {
    matches!(
        key,
        Key::KeyA
            | Key::KeyB
            | Key::KeyC
            | Key::KeyD
            | Key::KeyE
            | Key::KeyF
            | Key::KeyG
            | Key::KeyH
            | Key::KeyI
            | Key::KeyJ
            | Key::KeyK
            | Key::KeyL
            | Key::KeyM
            | Key::KeyN
            | Key::KeyO
            | Key::KeyP
            | Key::KeyQ
            | Key::KeyR
            | Key::KeyS
            | Key::KeyT
            | Key::KeyU
            | Key::KeyV
            | Key::KeyW
            | Key::KeyX
            | Key::KeyY
            | Key::KeyZ
    )
}

// https://github.com/rustdesk/rustdesk/issues/8599
// We just add these keys as letter keys.
#[inline]
pub fn is_letter_rdev_key_ex(key: &rdev::Key) -> bool {
    matches!(
        key,
        Key::LeftBracket | Key::RightBracket | Key::SemiColon | Key::Quote | Key::Comma | Key::Dot
    )
}

#[inline]
fn is_numpad_key(event: &Event) -> bool {
    matches!(event.event_type, EventType::KeyPress(key) | EventType::KeyRelease(key) if is_numpad_rdev_key(&key))
}

// Check is letter key for lock modes.
// Only letter keys need to check and send Lock key state.
#[inline]
fn is_letter_key_4_lock_modes(event: &Event) -> bool {
    matches!(event.event_type, EventType::KeyPress(key) | EventType::KeyRelease(key) if (is_letter_rdev_key(&key) || is_letter_rdev_key_ex(&key)))
}

fn parse_add_lock_modes_modifiers(
    key_event: &mut KeyEvent,
    lock_modes: i32,
    is_numpad_key: bool,
    is_letter_key: bool,
) {
    const CAPS_LOCK: i32 = 1;
    const NUM_LOCK: i32 = 2;
    // const SCROLL_LOCK: i32 = 3;
    if is_letter_key && (lock_modes & (1 << CAPS_LOCK) != 0) {
        key_event.modifiers.push(ControlKey::CapsLock.into());
    }
    if is_numpad_key && lock_modes & (1 << NUM_LOCK) != 0 {
        key_event.modifiers.push(ControlKey::NumLock.into());
    }
    // if lock_modes & (1 << SCROLL_LOCK) != 0 {
    //     key_event.modifiers.push(ControlKey::ScrollLock.into());
    // }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn add_lock_modes_modifiers(key_event: &mut KeyEvent, is_numpad_key: bool, is_letter_key: bool) {
    if is_letter_key && get_key_state(enigo::Key::CapsLock) {
        key_event.modifiers.push(ControlKey::CapsLock.into());
    }
    if is_numpad_key && get_key_state(enigo::Key::NumLock) {
        key_event.modifiers.push(ControlKey::NumLock.into());
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn convert_numpad_keys(key: Key) -> Key {
    if get_key_state(enigo::Key::NumLock) {
        return key;
    }
    match key {
        Key::Kp0 => Key::Insert,
        Key::KpDecimal => Key::Delete,
        Key::Kp1 => Key::End,
        Key::Kp2 => Key::DownArrow,
        Key::Kp3 => Key::PageDown,
        Key::Kp4 => Key::LeftArrow,
        Key::Kp5 => Key::Clear,
        Key::Kp6 => Key::RightArrow,
        Key::Kp7 => Key::Home,
        Key::Kp8 => Key::UpArrow,
        Key::Kp9 => Key::PageUp,
        _ => key,
    }
}

fn update_modifiers_state(event: &Event) {
    // for mouse
    let mut keys = MODIFIERS_STATE.lock().unwrap();
    match event.event_type {
        EventType::KeyPress(k) => {
            if keys.contains_key(&k) {
                keys.insert(k, true);
            }
        }
        EventType::KeyRelease(k) => {
            if keys.contains_key(&k) {
                keys.insert(k, false);
            }
        }
        _ => {}
    };
}

pub fn event_to_key_events(
    mut peer: String,
    event: &Event,
    keyboard_mode: KeyboardMode,
    _lock_modes: Option<i32>,
) -> Vec<KeyEvent> {
    peer.retain(|c| !c.is_whitespace());

    update_modifiers_state(event);

    match event.event_type {
        EventType::KeyPress(key) => {
            TO_RELEASE.lock().unwrap().insert(key, event.clone());
        }
        EventType::KeyRelease(key) => {
            TO_RELEASE.lock().unwrap().remove(&key);
        }
        _ => {}
    }

    let mut key_event = KeyEvent::new();
    key_event.mode = keyboard_mode.into();

    let mut key_events = match keyboard_mode {
        KeyboardMode::Map => map_keyboard_mode(peer.as_str(), event, key_event),
        KeyboardMode::Translate => translate_keyboard_mode(peer.as_str(), event, key_event),
        _ => {
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            {
                legacy_keyboard_mode(event, key_event)
            }
            #[cfg(any(target_os = "android", target_os = "ios"))]
            {
                Vec::new()
            }
        }
    };

    let is_numpad_key = is_numpad_key(&event);
    if keyboard_mode != KeyboardMode::Translate || is_numpad_key {
        let is_letter_key = is_letter_key_4_lock_modes(&event);
        for key_event in &mut key_events {
            if let Some(lock_modes) = _lock_modes {
                parse_add_lock_modes_modifiers(key_event, lock_modes, is_numpad_key, is_letter_key);
            } else {
                #[cfg(not(any(target_os = "android", target_os = "ios")))]
                add_lock_modes_modifiers(key_event, is_numpad_key, is_letter_key);
            }
        }
    }
    key_events
}

pub fn send_key_event(key_event: &KeyEvent) {
    #[cfg(not(feature = "flutter"))]
    if let Some(session) = CUR_SESSION.lock().unwrap().as_ref() {
        session.send_key_event(key_event);
    }

    #[cfg(feature = "flutter")]
    if let Some(session) = flutter::get_cur_session() {
        session.send_key_event(key_event);
    }
}

pub fn get_peer_platform() -> String {
    #[cfg(not(feature = "flutter"))]
    if let Some(session) = CUR_SESSION.lock().unwrap().as_ref() {
        return session.peer_platform();
    }
    #[cfg(feature = "flutter")]
    if let Some(session) = flutter::get_cur_session() {
        return session.peer_platform();
    }
    "Windows".to_string()
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn legacy_keyboard_mode(event: &Event, mut key_event: KeyEvent) -> Vec<KeyEvent> {
    let mut events = Vec::new();
    // legacy mode(0): Generate characters locally, look for keycode on other side.
    let (mut key, down_or_up) = match event.event_type {
        EventType::KeyPress(key) => (key, true),
        EventType::KeyRelease(key) => (key, false),
        _ => {
            return events;
        }
    };

    let peer = get_peer_platform();
    let is_win = peer == "Windows";
    if is_win {
        key = convert_numpad_keys(key);
    }

    let alt = get_key_state(enigo::Key::Alt);
    #[cfg(windows)]
    let ctrl = {
        let mut tmp = get_key_state(enigo::Key::Control) || get_key_state(enigo::Key::RightControl);
        unsafe {
            if IS_ALT_GR {
                if alt || key == Key::AltGr {
                    if tmp {
                        tmp = false;
                    }
                } else {
                    IS_ALT_GR = false;
                }
            }
        }
        tmp
    };
    #[cfg(not(windows))]
    let ctrl = get_key_state(enigo::Key::Control) || get_key_state(enigo::Key::RightControl);
    let shift = get_key_state(enigo::Key::Shift) || get_key_state(enigo::Key::RightShift);
    #[cfg(windows)]
    let command = crate::platform::windows::get_win_key_state();
    #[cfg(not(windows))]
    let command = get_key_state(enigo::Key::Meta);
    let control_key = match key {
        Key::Alt => Some(ControlKey::Alt),
        Key::AltGr => Some(ControlKey::RAlt),
        Key::Backspace => Some(ControlKey::Backspace),
        Key::ControlLeft => {
            // when pressing AltGr, an extra VK_LCONTROL with a special
            // scancode with bit 9 set is sent, let's ignore this.
            #[cfg(windows)]
            if (event.position_code >> 8) == 0xE0 {
                unsafe {
                    IS_ALT_GR = true;
                }
                return events;
            }
            Some(ControlKey::Control)
        }
        Key::ControlRight => Some(ControlKey::RControl),
        Key::DownArrow => Some(ControlKey::DownArrow),
        Key::Escape => Some(ControlKey::Escape),
        Key::F1 => Some(ControlKey::F1),
        Key::F10 => Some(ControlKey::F10),
        Key::F11 => Some(ControlKey::F11),
        Key::F12 => Some(ControlKey::F12),
        Key::F2 => Some(ControlKey::F2),
        Key::F3 => Some(ControlKey::F3),
        Key::F4 => Some(ControlKey::F4),
        Key::F5 => Some(ControlKey::F5),
        Key::F6 => Some(ControlKey::F6),
        Key::F7 => Some(ControlKey::F7),
        Key::F8 => Some(ControlKey::F8),
        Key::F9 => Some(ControlKey::F9),
        Key::LeftArrow => Some(ControlKey::LeftArrow),
        Key::MetaLeft => Some(ControlKey::Meta),
        Key::MetaRight => Some(ControlKey::RWin),
        Key::Return => Some(ControlKey::Return),
        Key::RightArrow => Some(ControlKey::RightArrow),
        Key::ShiftLeft => Some(ControlKey::Shift),
        Key::ShiftRight => Some(ControlKey::RShift),
        Key::Space => Some(ControlKey::Space),
        Key::Tab => Some(ControlKey::Tab),
        Key::UpArrow => Some(ControlKey::UpArrow),
        Key::Delete => {
            if is_win && ctrl && alt {
                client::ctrl_alt_del();
                return events;
            }
            Some(ControlKey::Delete)
        }
        Key::Apps => Some(ControlKey::Apps),
        Key::Cancel => Some(ControlKey::Cancel),
        Key::Clear => Some(ControlKey::Clear),
        Key::Kana => Some(ControlKey::Kana),
        Key::Hangul => Some(ControlKey::Hangul),
        Key::Junja => Some(ControlKey::Junja),
        Key::Final => Some(ControlKey::Final),
        Key::Hanja => Some(ControlKey::Hanja),
        Key::Hanji => Some(ControlKey::Hanja),
        Key::Lang2 => Some(ControlKey::Convert),
        Key::Print => Some(ControlKey::Print),
        Key::Select => Some(ControlKey::Select),
        Key::Execute => Some(ControlKey::Execute),
        Key::PrintScreen => Some(ControlKey::Snapshot),
        Key::Help => Some(ControlKey::Help),
        Key::Sleep => Some(ControlKey::Sleep),
        Key::Separator => Some(ControlKey::Separator),
        Key::KpReturn => Some(ControlKey::NumpadEnter),
        Key::Kp0 => Some(ControlKey::Numpad0),
        Key::Kp1 => Some(ControlKey::Numpad1),
        Key::Kp2 => Some(ControlKey::Numpad2),
        Key::Kp3 => Some(ControlKey::Numpad3),
        Key::Kp4 => Some(ControlKey::Numpad4),
        Key::Kp5 => Some(ControlKey::Numpad5),
        Key::Kp6 => Some(ControlKey::Numpad6),
        Key::Kp7 => Some(ControlKey::Numpad7),
        Key::Kp8 => Some(ControlKey::Numpad8),
        Key::Kp9 => Some(ControlKey::Numpad9),
        Key::KpDivide => Some(ControlKey::Divide),
        Key::KpMultiply => Some(ControlKey::Multiply),
        Key::KpDecimal => Some(ControlKey::Decimal),
        Key::KpMinus => Some(ControlKey::Subtract),
        Key::KpPlus => Some(ControlKey::Add),
        Key::CapsLock | Key::NumLock | Key::ScrollLock => {
            return events;
        }
        Key::Home => Some(ControlKey::Home),
        Key::End => Some(ControlKey::End),
        Key::Insert => Some(ControlKey::Insert),
        Key::PageUp => Some(ControlKey::PageUp),
        Key::PageDown => Some(ControlKey::PageDown),
        Key::Pause => Some(ControlKey::Pause),
        _ => None,
    };
    if let Some(k) = control_key {
        key_event.set_control_key(k);
    } else {
        let name = event
            .unicode
            .as_ref()
            .and_then(|unicode| unicode.name.clone());
        let mut chr = match &name {
            Some(ref s) => {
                if s.len() <= 2 {
                    // exclude chinese characters
                    s.chars().next().unwrap_or('\0')
                } else {
                    '\0'
                }
            }
            _ => '\0',
        };
        if chr == '·' {
            // special for Chinese
            chr = '`';
        }
        if chr == '\0' {
            chr = match key {
                Key::Num1 => '1',
                Key::Num2 => '2',
                Key::Num3 => '3',
                Key::Num4 => '4',
                Key::Num5 => '5',
                Key::Num6 => '6',
                Key::Num7 => '7',
                Key::Num8 => '8',
                Key::Num9 => '9',
                Key::Num0 => '0',
                Key::KeyA => 'a',
                Key::KeyB => 'b',
                Key::KeyC => 'c',
                Key::KeyD => 'd',
                Key::KeyE => 'e',
                Key::KeyF => 'f',
                Key::KeyG => 'g',
                Key::KeyH => 'h',
                Key::KeyI => 'i',
                Key::KeyJ => 'j',
                Key::KeyK => 'k',
                Key::KeyL => 'l',
                Key::KeyM => 'm',
                Key::KeyN => 'n',
                Key::KeyO => 'o',
                Key::KeyP => 'p',
                Key::KeyQ => 'q',
                Key::KeyR => 'r',
                Key::KeyS => 's',
                Key::KeyT => 't',
                Key::KeyU => 'u',
                Key::KeyV => 'v',
                Key::KeyW => 'w',
                Key::KeyX => 'x',
                Key::KeyY => 'y',
                Key::KeyZ => 'z',
                Key::Comma => ',',
                Key::Dot => '.',
                Key::SemiColon => ';',
                Key::Quote => '\'',
                Key::LeftBracket => '[',
                Key::RightBracket => ']',
                Key::Slash => '/',
                Key::BackSlash => '\\',
                Key::Minus => '-',
                Key::Equal => '=',
                Key::BackQuote => '`',
                _ => '\0',
            }
        }
        if chr != '\0' {
            if chr == 'l' && is_win && command {
                client::lock_screen();
                return events;
            }
            key_event.set_chr(chr as _);
        } else {
            log::error!("Unknown key {:?}", &event);
            return events;
        }
    }
    let (alt, ctrl, shift, command) = client::get_modifiers_state(alt, ctrl, shift, command);
    client::legacy_modifiers(&mut key_event, alt, ctrl, shift, command);

    if down_or_up == true {
        key_event.down = true;
    }
    events.push(key_event);
    events
}

#[inline]
pub fn map_keyboard_mode(_peer: &str, event: &Event, key_event: KeyEvent) -> Vec<KeyEvent> {
    if let Some(evt) = windows_peer_special_key(_peer, event) {
        return vec![evt];
    }

    _map_keyboard_mode(_peer, event, key_event)
        .map(|e| vec![e])
        .unwrap_or_default()
}

fn windows_peer_special_key(peer: &str, event: &Event) -> Option<KeyEvent> {
    if peer != OS_LOWER_WINDOWS {
        return None;
    }

    let (key, down) = match event.event_type {
        EventType::KeyPress(key) => (key, true),
        EventType::KeyRelease(key) => (key, false),
        _ => return None,
    };

    // Handle only `Pause` for Windows peers for now.
    // Windows has no normal scan code for `Pause`, so send it as a legacy control key.
    #[cfg(target_os = "windows")]
    let is_pause = {
        // The Windows scan code can look like `NumLock`; VK_PAUSE distinguishes it.
        let pause_vk_code = rdev::win_code_from_key(Key::Pause);
        key == Key::Pause || pause_vk_code == Some(event.platform_code as _)
    };
    #[cfg(not(target_os = "windows"))]
    let is_pause = key == Key::Pause;
    if !is_pause {
        return None;
    }

    let mut key_event = KeyEvent::new();
    key_event.mode = KeyboardMode::Legacy.into();
    key_event.down = down;
    key_event.set_control_key(ControlKey::Pause);
    let (alt, ctrl, shift, command) = client::get_modifiers_state(false, false, false, false);
    client::legacy_modifiers(&mut key_event, alt, ctrl, shift, command);
    Some(key_event)
}

fn _map_keyboard_mode(_peer: &str, event: &Event, mut key_event: KeyEvent) -> Option<KeyEvent> {
    match event.event_type {
        EventType::KeyPress(..) => {
            key_event.down = true;
        }
        EventType::KeyRelease(..) => {
            key_event.down = false;
        }
        _ => return None,
    };

    #[cfg(target_os = "windows")]
    let keycode = match _peer {
        OS_LOWER_WINDOWS => {
            // https://github.com/rustdesk/rustdesk/issues/1371
            // Filter scancodes that are greater than 255 and the height word is not 0xE0.
            if event.position_code > 255 && (event.position_code >> 8) != 0xE0 {
                return None;
            }
            event.position_code
        }
        OS_LOWER_MACOS => {
            if hbb_common::config::LocalConfig::get_kb_layout_type() == "ISO" {
                rdev::win_scancode_to_macos_iso_code(event.position_code)?
            } else {
                rdev::win_scancode_to_macos_code(event.position_code)?
            }
        }
        OS_LOWER_ANDROID => rdev::win_scancode_to_android_key_code(event.position_code)?,
        _ => rdev::win_scancode_to_linux_code(event.position_code)?,
    };
    #[cfg(target_os = "macos")]
    let keycode = match _peer {
        OS_LOWER_WINDOWS => rdev::macos_code_to_win_scancode(event.platform_code as _)?,
        OS_LOWER_MACOS => event.platform_code as _,
        OS_LOWER_ANDROID => rdev::macos_code_to_android_key_code(event.platform_code as _)?,
        _ => rdev::macos_code_to_linux_code(event.platform_code as _)?,
    };
    #[cfg(target_os = "linux")]
    let keycode = match _peer {
        OS_LOWER_WINDOWS => rdev::linux_code_to_win_scancode(event.position_code as _)?,
        OS_LOWER_MACOS => {
            if hbb_common::config::LocalConfig::get_kb_layout_type() == "ISO" {
                rdev::linux_code_to_macos_iso_code(event.position_code as _)?
            } else {
                rdev::linux_code_to_macos_code(event.position_code as _)?
            }
        }
        OS_LOWER_ANDROID => rdev::linux_code_to_android_key_code(event.position_code as _)?,
        _ => event.position_code as _,
    };
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let keycode = match _peer {
        OS_LOWER_WINDOWS => rdev::usb_hid_code_to_win_scancode(event.usb_hid as _)?,
        OS_LOWER_LINUX => rdev::usb_hid_code_to_linux_code(event.usb_hid as _)?,
        OS_LOWER_MACOS => {
            if hbb_common::config::LocalConfig::get_kb_layout_type() == "ISO" {
                rdev::usb_hid_code_to_macos_iso_code(event.usb_hid as _)?
            } else {
                rdev::usb_hid_code_to_macos_code(event.usb_hid as _)?
            }
        }
        OS_LOWER_ANDROID => rdev::usb_hid_code_to_android_key_code(event.usb_hid as _)?,
        _ => event.usb_hid as _,
    };
    key_event.set_chr(keycode as _);
    Some(key_event)
}

#[cfg(not(any(target_os = "ios")))]
fn try_fill_unicode(_peer: &str, event: &Event, key_event: &KeyEvent, events: &mut Vec<KeyEvent>) {
    match &event.unicode {
        Some(unicode_info) => {
            if let Some(name) = &unicode_info.name {
                if name.len() > 0 {
                    let mut evt = key_event.clone();
                    evt.set_seq(name.to_string());
                    evt.down = true;
                    events.push(evt);
                }
            }
        }
        None =>
        {
            #[cfg(target_os = "windows")]
            if _peer == OS_LOWER_LINUX {
                if is_hot_key_modifiers_down() && unsafe { !IS_0X021D_DOWN } {
                    if let Some(chr) = get_char_from_vk(event.platform_code as u32) {
                        let mut evt = key_event.clone();
                        evt.set_seq(chr.to_string());
                        evt.down = true;
                        events.push(evt);
                    }
                }
            }
        }
    }
}

#[cfg(target_os = "windows")]
fn try_fill_win2win_hotkey(
    peer: &str,
    event: &Event,
    key_event: &KeyEvent,
    events: &mut Vec<KeyEvent>,
) {
    if peer == OS_LOWER_WINDOWS && is_hot_key_modifiers_down() && unsafe { !IS_0X021D_DOWN } {
        let mut down = false;
        let win2win_hotkey = match event.event_type {
            EventType::KeyPress(..) => {
                down = true;
                if let Some(unicode) = get_unicode_from_vk(event.platform_code as u32) {
                    Some((unicode as u32 & 0x0000FFFF) | (event.platform_code << 16))
                } else {
                    None
                }
            }
            EventType::KeyRelease(..) => Some(event.platform_code << 16),
            _ => None,
        };
        if let Some(code) = win2win_hotkey {
            let mut evt = key_event.clone();
            evt.set_win2win_hotkey(code);
            evt.down = down;
            events.push(evt);
        }
    }
}

#[cfg(target_os = "windows")]
fn is_hot_key_modifiers_down() -> bool {
    if rdev::get_modifier(Key::ControlLeft) || rdev::get_modifier(Key::ControlRight) {
        return true;
    }
    if rdev::get_modifier(Key::Alt) || rdev::get_modifier(Key::AltGr) {
        return true;
    }
    if rdev::get_modifier(Key::MetaLeft) || rdev::get_modifier(Key::MetaRight) {
        return true;
    }
    return false;
}

#[inline]
#[cfg(any(target_os = "linux", target_os = "windows"))]
fn is_altgr(event: &Event) -> bool {
    #[cfg(target_os = "linux")]
    if event.platform_code == 0xFE03 {
        true
    } else {
        false
    }

    #[cfg(target_os = "windows")]
    if unsafe { IS_0X021D_DOWN } && event.position_code == 0xE038 {
        true
    } else {
        false
    }
}

#[inline]
#[cfg(any(target_os = "linux", target_os = "windows"))]
fn is_press(event: &Event) -> bool {
    matches!(event.event_type, EventType::KeyPress(_))
}

// https://github.com/rustdesk/rustdesk/wiki/FAQ#keyboard-translation-modes
pub fn translate_keyboard_mode(peer: &str, event: &Event, key_event: KeyEvent) -> Vec<KeyEvent> {
    let mut events: Vec<KeyEvent> = Vec::new();

    if let Some(evt) = windows_peer_special_key(peer, event) {
        events.push(evt);
        return events;
    }

    if let Some(unicode_info) = &event.unicode {
        if unicode_info.is_dead {
            #[cfg(target_os = "macos")]
            if peer != OS_LOWER_MACOS && unsafe { IS_LEFT_OPTION_DOWN } {
                // try clear dead key state
                // rdev::clear_dead_key_state();
            } else {
                return events;
            }
            #[cfg(not(target_os = "macos"))]
            return events;
        }
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    if is_numpad_key(&event) {
        events.append(&mut map_keyboard_mode(peer, event, key_event));
        return events;
    }

    #[cfg(target_os = "macos")]
    // ignore right option key
    if event.platform_code == rdev::kVK_RightOption as u32 {
        return events;
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    if is_altgr(event) {
        return events;
    }

    #[cfg(target_os = "windows")]
    if event.position_code == 0x021D {
        return events;
    }

    #[cfg(target_os = "windows")]
    try_fill_win2win_hotkey(peer, event, &key_event, &mut events);

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    if events.is_empty() && is_press(event) {
        try_fill_unicode(peer, event, &key_event, &mut events);
    }

    // If AltGr is down, no need to send events other than unicode.
    #[cfg(target_os = "windows")]
    unsafe {
        if IS_0X021D_DOWN {
            return events;
        }
    }

    #[cfg(target_os = "macos")]
    if !unsafe { IS_LEFT_OPTION_DOWN } {
        try_fill_unicode(peer, event, &key_event, &mut events);
    }

    if events.is_empty() {
        events.append(&mut map_keyboard_mode(peer, event, key_event));
    }
    events
}

#[cfg(not(any(target_os = "ios")))]
pub fn keycode_to_rdev_key(keycode: u32) -> Key {
    #[cfg(target_os = "windows")]
    return rdev::win_key_from_scancode(keycode);
    #[cfg(any(target_os = "linux"))]
    return rdev::linux_key_from_code(keycode);
    #[cfg(any(target_os = "android"))]
    return rdev::android_key_from_code(keycode);
    #[cfg(target_os = "macos")]
    return rdev::macos_key_from_code(keycode.try_into().unwrap_or_default());
}

#[cfg(feature = "flutter")]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub mod input_source {
    #[cfg(target_os = "macos")]
    use hbb_common::log;
    use hbb_common::SessionID;

    use crate::ui_interface::{get_local_option, set_local_option};

    pub const CONFIG_OPTION_INPUT_SOURCE: &str = "input-source";
    // rdev grab mode
    pub const CONFIG_INPUT_SOURCE_1: &str = "Input source 1";
    pub const CONFIG_INPUT_SOURCE_1_TIP: &str = "input_source_1_tip";
    // flutter grab mode
    pub const CONFIG_INPUT_SOURCE_2: &str = "Input source 2";
    pub const CONFIG_INPUT_SOURCE_2_TIP: &str = "input_source_2_tip";

    pub const CONFIG_INPUT_SOURCE_DEFAULT: &str = CONFIG_INPUT_SOURCE_1;

    pub fn init_input_source() {
        #[cfg(target_os = "linux")]
        if !crate::platform::linux::is_x11() {
            // If switching from X11 to Wayland, the grab loop will not be started.
            // Do not change the config here.
            return;
        }
        #[cfg(target_os = "macos")]
        if !crate::platform::macos::is_can_input_monitoring(false) {
            log::error!("init_input_source, is_can_input_monitoring() false");
            set_local_option(
                CONFIG_OPTION_INPUT_SOURCE.to_string(),
                CONFIG_INPUT_SOURCE_2.to_string(),
            );
            return;
        }
        let cur_input_source = get_cur_session_input_source();
        if cur_input_source == CONFIG_INPUT_SOURCE_1 {
            super::IS_RDEV_ENABLED.store(true, super::Ordering::SeqCst);
        }
        super::client::start_grab_loop();
    }

    pub fn change_input_source(session_id: SessionID, input_source: String) {
        let cur_input_source = get_cur_session_input_source();
        if cur_input_source == input_source {
            return;
        }
        if input_source == CONFIG_INPUT_SOURCE_1 {
            #[cfg(target_os = "macos")]
            if !crate::platform::macos::is_can_input_monitoring(false) {
                log::error!("change_input_source, is_can_input_monitoring() false");
                return;
            }
            // It is ok to start grab loop multiple times.
            super::client::start_grab_loop();
            super::IS_RDEV_ENABLED.store(true, super::Ordering::SeqCst);
            crate::flutter_ffi::session_enter_or_leave(session_id, true);
        } else if input_source == CONFIG_INPUT_SOURCE_2 {
            // No need to stop grab loop.
            crate::flutter_ffi::session_enter_or_leave(session_id, false);
            super::IS_RDEV_ENABLED.store(false, super::Ordering::SeqCst);
        }
        set_local_option(CONFIG_OPTION_INPUT_SOURCE.to_string(), input_source);
    }

    #[inline]
    pub fn get_cur_session_input_source() -> String {
        #[cfg(target_os = "linux")]
        if !crate::platform::linux::is_x11() {
            return CONFIG_INPUT_SOURCE_2.to_string();
        }
        let input_source = get_local_option(CONFIG_OPTION_INPUT_SOURCE.to_string());
        if input_source.is_empty() {
            CONFIG_INPUT_SOURCE_DEFAULT.to_string()
        } else {
            input_source
        }
    }

    #[inline]
    pub fn get_supported_input_source() -> Vec<(String, String)> {
        #[cfg(target_os = "linux")]
        if !crate::platform::linux::is_x11() {
            return vec![(
                CONFIG_INPUT_SOURCE_2.to_string(),
                CONFIG_INPUT_SOURCE_2_TIP.to_string(),
            )];
        }
        vec![
            (
                CONFIG_INPUT_SOURCE_1.to_string(),
                CONFIG_INPUT_SOURCE_1_TIP.to_string(),
            ),
            (
                CONFIG_INPUT_SOURCE_2.to_string(),
                CONFIG_INPUT_SOURCE_2_TIP.to_string(),
            ),
        ]
    }
}
