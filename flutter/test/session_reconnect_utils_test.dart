import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/session_reconnect_utils.dart';

void main() {
  test('retries only transient established-session handoff errors', () {
    for (final text in [
      'Remote desktop is offline',
      'Failed to connect to rendezvous server',
      'Failed to connect via rendezvous server',
      'Rendezvous connection is reset by the peer',
      'Reset by the peer',
    ]) {
      expect(
          isTransientInstalledServerHandoffError(
              'error', 'Connection Error', text),
          isTrue);
    }
    expect(
        isTransientInstalledServerHandoffError(
            'error', 'Login Error', 'Remote desktop is offline'),
        isFalse);
    expect(
        isTransientInstalledServerHandoffError(
            'error', 'Connection Error', 'Wrong Password'),
        isFalse);
  });
}
