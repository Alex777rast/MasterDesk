import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/popup_menu.dart';

void main() {
  testWidgets('radio submenu header follows the selected option',
      (tester) async {
    var selected = '8';
    final entry = MenuEntrySubRadios<String>(
      text: 'Transfer file: 8x',
      textBuilder: (value) => 'Transfer file: ${value}x',
      optionsGetter: () => [
        MenuEntryRadioOption(text: '4x', value: '4'),
        MenuEntryRadioOption(text: '8x', value: '8'),
      ],
      curOptionGetter: () async => selected,
      optionSetter: (_, value) async {
        selected = value;
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: entry
              .build(context, const MenuConfig(commonColor: Colors.blue))
              .single,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Transfer file: 8x'), findsOneWidget);

    await entry.setOption('4');
    await tester.pump();
    expect(find.text('Transfer file: 4x'), findsOneWidget);
  });
}
