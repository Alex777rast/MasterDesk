import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/input_modifier_utils.dart';

void main() {
  group('shouldKeepPrintScreenLocal', () {
    test('keeps Print Screen on the Windows controller', () {
      expect(
        shouldKeepPrintScreenLocal(
          isWindows: true,
          physicalKey: PhysicalKeyboardKey.printScreen,
        ),
        isTrue,
      );
    });

    test('does not keep ordinary Windows keys locally', () {
      expect(
        shouldKeepPrintScreenLocal(
          isWindows: true,
          physicalKey: PhysicalKeyboardKey.keyA,
        ),
        isFalse,
      );
    });

    test('does not change Print Screen routing on other platforms', () {
      expect(
        shouldKeepPrintScreenLocal(
          isWindows: false,
          physicalKey: PhysicalKeyboardKey.printScreen,
        ),
        isFalse,
      );
    });
  });

  group('shouldPassWindowsModifierToPlatform', () {
    test('passes both sides of ctrl alt and shift on Windows', () {
      for (final key in [
        PhysicalKeyboardKey.controlLeft,
        PhysicalKeyboardKey.controlRight,
        PhysicalKeyboardKey.altLeft,
        PhysicalKeyboardKey.altRight,
        PhysicalKeyboardKey.shiftLeft,
        PhysicalKeyboardKey.shiftRight,
      ]) {
        expect(
          shouldPassWindowsModifierToPlatform(
            isWindows: true,
            physicalKey: key,
          ),
          isTrue,
        );
      }
    });

    test('keeps ordinary keys inside the remote view', () {
      expect(
        shouldPassWindowsModifierToPlatform(
          isWindows: true,
          physicalKey: PhysicalKeyboardKey.keyA,
        ),
        isFalse,
      );
    });

    test('does not change modifier routing on other platforms', () {
      expect(
        shouldPassWindowsModifierToPlatform(
          isWindows: false,
          physicalKey: PhysicalKeyboardKey.shiftLeft,
        ),
        isFalse,
      );
    });
  });

  group('shouldReleaseStaleMobileShift', () {
    test('does not release when cached shift is already false', () {
      expect(
        shouldReleaseStaleMobileShift(
          isMobile: true,
          cachedShiftPressed: false,
          actualShiftPressed: false,
          logicalKey: LogicalKeyboardKey.keyD,
          hasTrackedShiftKeyDown: true,
        ),
        isFalse,
      );
    });

    test('releases one-shot mobile shift after a text key', () {
      expect(
        shouldReleaseStaleMobileShift(
          isMobile: true,
          cachedShiftPressed: true,
          actualShiftPressed: false,
          logicalKey: LogicalKeyboardKey.keyD,
          hasTrackedShiftKeyDown: true,
        ),
        isTrue,
      );
    });

    test('does not release manually toggled shift without tracked key down',
        () {
      expect(
        shouldReleaseStaleMobileShift(
          isMobile: true,
          cachedShiftPressed: true,
          actualShiftPressed: false,
          logicalKey: LogicalKeyboardKey.keyD,
          hasTrackedShiftKeyDown: false,
        ),
        isFalse,
      );
    });

    test('does not release when shift is still physically pressed', () {
      expect(
        shouldReleaseStaleMobileShift(
          isMobile: true,
          cachedShiftPressed: true,
          actualShiftPressed: true,
          logicalKey: LogicalKeyboardKey.keyD,
          hasTrackedShiftKeyDown: true,
        ),
        isFalse,
      );
    });

    test('does not release on non-mobile platforms', () {
      expect(
        shouldReleaseStaleMobileShift(
          isMobile: false,
          cachedShiftPressed: true,
          actualShiftPressed: false,
          logicalKey: LogicalKeyboardKey.keyD,
          hasTrackedShiftKeyDown: true,
        ),
        isFalse,
      );
    });

    test('releases on enter key', () {
      expect(
        shouldReleaseStaleMobileShift(
          isMobile: true,
          cachedShiftPressed: true,
          actualShiftPressed: false,
          logicalKey: LogicalKeyboardKey.enter,
          hasTrackedShiftKeyDown: true,
        ),
        isTrue,
      );
    });

    test('releases on arrow key', () {
      expect(
        shouldReleaseStaleMobileShift(
          isMobile: true,
          cachedShiftPressed: true,
          actualShiftPressed: false,
          logicalKey: LogicalKeyboardKey.arrowLeft,
          hasTrackedShiftKeyDown: true,
        ),
        isTrue,
      );
    });

    test('does not release on modifier events', () {
      expect(
        shouldReleaseStaleMobileShift(
          isMobile: true,
          cachedShiftPressed: true,
          actualShiftPressed: false,
          logicalKey: LogicalKeyboardKey.shiftLeft,
          hasTrackedShiftKeyDown: true,
        ),
        isFalse,
      );
    });

    test('does not release on shiftRight modifier events', () {
      expect(
        shouldReleaseStaleMobileShift(
          isMobile: true,
          cachedShiftPressed: true,
          actualShiftPressed: false,
          logicalKey: LogicalKeyboardKey.shiftRight,
          hasTrackedShiftKeyDown: true,
        ),
        isFalse,
      );
    });
  });
}
