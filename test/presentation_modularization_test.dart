import 'package:flutter_test/flutter_test.dart';
import 'package:movementor/src/presentation/screens/movementor_screens.dart';

void main() {
  test('Verify all modularized screens and facades exist and instantiate', () {
    expect(const OnboardingScreen(), isNotNull);
    expect(const GameLibraryScreen(), isNotNull);
    expect(const GameReviewScreen(), isNotNull);
    expect(const ImportHubScreen(), isNotNull);
    expect(const WeaknessDashboardScreen(), isNotNull);
    expect(const SettingsHubScreen(), isNotNull);
    expect(const ProviderEditorScreen(), isNotNull);
    expect(const ModelAndStorageScreen(), isNotNull);
    expect(const ExportDataScreen(), isNotNull);
    expect(const DiagnosticsScreen(), isNotNull);
    expect(const LicencesAndPrivacyScreen(), isNotNull);
    expect(const LicencesScreen(), isNotNull);
    expect(const MoveMentorAppShell(), isNotNull);
    expect(
      const EvalGraphWidget(analyses: [], currentPly: 0, onSelectPly: _noop),
      isNotNull,
    );
  });
}

void _noop(int ply) {}
