import 'package:flutter/services.dart';

/// Returns true for Windows modifier events which must reach the native
/// platform after MasterDesk has forwarded them to the remote peer.
///
/// Flutter otherwise marks every remote-view key event as handled. Passing
/// Ctrl/Alt/Shift back to Windows lets the configured Alt+Shift or Ctrl+Shift
/// language shortcut run locally without releasing ordinary remote shortcuts
/// such as Alt+F4 or Ctrl+C to the controller OS.
bool shouldPassWindowsModifierToPlatform({
  required bool isWindows,
  required PhysicalKeyboardKey physicalKey,
}) {
  if (!isWindows) return false;
  return physicalKey == PhysicalKeyboardKey.altLeft ||
      physicalKey == PhysicalKeyboardKey.altRight ||
      physicalKey == PhysicalKeyboardKey.controlLeft ||
      physicalKey == PhysicalKeyboardKey.controlRight ||
      physicalKey == PhysicalKeyboardKey.shiftLeft ||
      physicalKey == PhysicalKeyboardKey.shiftRight;
}

/// Returns true when a stale mobile one-shot Shift state should be released
/// by replaying a tracked Shift key-down as a synthesized key-up.
///
/// This is only valid on mobile when Flutter's cached Shift state is still on
/// (`cachedShiftPressed == true`) but the current hardware/raw event reports
/// Shift as off (`actualShiftPressed == false`).
///
/// A tracked Shift key-down is required so the caller can safely synthesize the
/// matching key-up. Both `shiftLeft` and `shiftRight` are excluded because the
/// Shift key event itself must be processed first; otherwise we could release
/// the tracked key while still handling the original Shift press/release.
/// Callers should evaluate this only after their cached modifier state has been
/// updated for the current event.
///
/// When this returns true, the caller logs a line like:
/// `input: releasing stale mobile Shift before replaying tracked raw key-up`
/// immediately before calling `_releaseTrackedRawShiftKeyEventIfNeeded()`.
bool shouldReleaseStaleMobileShift({
  required bool isMobile,
  required bool cachedShiftPressed,
  required bool actualShiftPressed,
  required LogicalKeyboardKey logicalKey,
  required bool hasTrackedShiftKeyDown,
}) {
  if (!isMobile || !cachedShiftPressed || actualShiftPressed) {
    return false;
  }
  if (!hasTrackedShiftKeyDown) {
    return false;
  }
  if (logicalKey == LogicalKeyboardKey.shiftLeft ||
      logicalKey == LogicalKeyboardKey.shiftRight) {
    return false;
  }
  return true;
}
