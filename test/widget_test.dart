import 'package:flutter_test/flutter_test.dart';
import 'package:activation_tracker/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ActivationTrackerApp());
    expect(find.text('Activation Tracker'), findsOneWidget);
  });
}
