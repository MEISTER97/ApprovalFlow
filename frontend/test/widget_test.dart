import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';

void main() {
  testWidgets('ZioNet portal smoke test', (WidgetTester tester) async {
    // 1. Set simulated screen size to a desktop/web viewport (1280 x 800)
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;

    // 2. Build our app and trigger a frame.
    await tester.pumpWidget(const ZionetWorkflowApp());

    // 3. Verify that our portal title and form headers appear.
    expect(find.text('1. Submit New Invoice'), findsOneWidget);
    expect(find.text('2. Live Tracker & Manager Override'), findsOneWidget);

    // 4. Verify the RackSpace preset button is present.
    expect(find.text('💥 Saga Rollback (\$9,500 RackSpace)'), findsOneWidget);

    // 5. Reset viewport size after test completes so it doesn't affect other tests
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });
}