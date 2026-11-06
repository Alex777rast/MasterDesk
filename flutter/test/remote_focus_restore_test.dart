import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('restores the remote keyboard target after application activation', () {
    final policy = RemoteKeyboardFocusRestorePolicy();
    policy.recordWindowBlur(remoteCanvasHadFocus: true);

    expect(policy.consumeWindowFocus(relativeMouseMode: false), isTrue);
    expect(policy.consumeWindowFocus(relativeMouseMode: false), isFalse);
  });

  test('does not steal focus from a local viewer control', () {
    final policy = RemoteKeyboardFocusRestorePolicy();
    policy.recordWindowBlur(remoteCanvasHadFocus: false);

    expect(policy.consumeWindowFocus(relativeMouseMode: false), isFalse);
  });

  test('relative mouse mode always restores the remote keyboard target', () {
    final policy = RemoteKeyboardFocusRestorePolicy();
    policy.recordWindowBlur(remoteCanvasHadFocus: false);

    expect(policy.consumeWindowFocus(relativeMouseMode: true), isTrue);
  });
}
