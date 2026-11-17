import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patok/src/ui/field_screen.dart';

void main() {
  testWidgets('Save returns the trimmed name', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await askFieldName(context, 'Waypoint 1');
              },
              child: const Text('Ask'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '  Summit  ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(result, 'Summit');
  });

  testWidgets('Save is disabled while the name is empty', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                await askFieldName(context, 'Waypoint 1');
              },
              child: const Text('Ask'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();

    // Prefilled hint: Save starts enabled.
    expect(tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save')).onPressed, isNotNull);

    // Clearing the field disables Save; whitespace-only counts as empty.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);

    // Typing a name re-enables it.
    await tester.enterText(find.byType(TextField), 'Camp');
    await tester.pump();
    expect(tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save')).onPressed, isNotNull);
  });

  testWidgets('Save starts disabled for an empty hint', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                await askFieldName(context, '');
              },
              child: const Text('Ask'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);
  });
}
