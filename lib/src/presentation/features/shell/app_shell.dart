import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/app_state.dart';
import '../../../application/copy_deck.dart';
import '../dashboard/weakness_dashboard_screen.dart';
import '../library/game_library_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../review/game_review_screen.dart';
import '../settings/settings_hub_screen.dart';

/// Main App Shell managing Onboarding (Screen 1) and Main Navigation across Screens 2..16.
class MoveMentorAppShell extends ConsumerStatefulWidget {
  const MoveMentorAppShell({super.key});

  @override
  ConsumerState<MoveMentorAppShell> createState() => _MoveMentorAppShellState();
}

class _MoveMentorAppShellState extends ConsumerState<MoveMentorAppShell> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(appUiProvider);
    if (!uiState.onboardingDone) {
      return const OnboardingScreen();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('MoveMentor'),
        actions: [
          // Persistent Offline / Online Status Chip (Story A-3 AC1 & Part 28.5)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: ActionChip(
              avatar: Icon(
                uiState.offlineOnly ? Icons.airplanemode_active : Icons.cloud_done,
                size: 16,
              ),
              label: Text(
                uiState.offlineOnly ? 'Offline mode' : 'Online ready',
                style: const TextStyle(fontSize: 12),
              ),
              tooltip: uiState.offlineOnly
                  ? CopyDeck.tr('status.offline')
                  : CopyDeck.tr('status.online'),
              onPressed: () {
                ref.read(appUiProvider.notifier).setOfflineOnly(!uiState.offlineOnly);
              },
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: const [
          GameLibraryScreen(), // Screen 2 (+ pushes Screens 3..7)
          GameReviewScreen(), // Screen 8 & 9
          WeaknessDashboardScreen(), // Screen 10
          SettingsHubScreen(), // Screens 11..16
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (idx) => setState(() => _tabIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.analytics_outlined),
            selectedIcon: Icon(Icons.analytics),
            label: 'Review',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
