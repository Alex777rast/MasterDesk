import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('viewer file paste uses the physical V key mapping', () {
    expect(InputModel.viewerFilePasteKey, 'VK_V');
  });
}
