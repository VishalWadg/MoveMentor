import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'src/application/app_state.dart';
import 'src/presentation/screens/movementor_screens.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const ProviderScope(
      child: MoveMentorApp(),
    ),
  );
}

class MoveMentorApp extends ConsumerWidget {
  const MoveMentorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uiState = ref.watch(appUiProvider);

    return MaterialApp(
      title: 'MoveMentor',
      debugShowCheckedModeBanner: false,
      themeMode: uiState.themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF00695C),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF26A69A),
        brightness: Brightness.dark,
      ),
      home: const MoveMentorAppShell(),
    );
  }
}
