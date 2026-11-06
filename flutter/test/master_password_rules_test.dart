import 'package:flutter_hbb/common/widgets/custom_password.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('protected profile master password', () {
    test('accepts all required character classes', () {
      expect(isValidMasterPassword('MasterDesk9!safe'), isTrue);
    });

    test('requires at least twelve characters', () {
      expect(isValidMasterPassword('Short9!Aa'), isFalse);
    });

    test('requires upper, lower, digit, and special characters', () {
      expect(isValidMasterPassword('masterdesk9!safe'), isFalse);
      expect(isValidMasterPassword('MASTERDESK9!SAFE'), isFalse);
      expect(isValidMasterPassword('MasterDesk!!safe'), isFalse);
      expect(isValidMasterPassword('MasterDesk99safe'), isFalse);
    });

    test('rejects surrounding whitespace and control characters', () {
      expect(isValidMasterPassword(' MasterDesk9!safe'), isFalse);
      expect(isValidMasterPassword('MasterDesk9!safe\n'), isFalse);
    });

    test('rejects values longer than the backend limit', () {
      expect(isValidMasterPassword('Aa9!${List.filled(125, 'x').join()}'),
          isFalse);
    });
  });
}
