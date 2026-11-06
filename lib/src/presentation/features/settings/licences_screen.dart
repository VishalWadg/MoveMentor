import 'package:flutter/material.dart';
import '../../../application/copy_deck.dart';

/// Screen 16: Licences, Credits & Privacy Policy (Story I-2 & Part 29.3).
class LicencesAndPrivacyScreen extends StatelessWidget {
  const LicencesAndPrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Licences & Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Privacy Policy (Part 29.3)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'What this app stores: Games you import, the analysis the app computes, explanations, your settings and any model files. All of it is stored only on your device. API keys are kept in your device secure storage.\n\n'
            'What leaves your device, and only when you ask: (1) Importing by username sends that username to Lichess or Chess.com to fetch your public games. (2) Downloading a model contacts the download host. (3) If you choose "My own API", the position and move facts for each explained moment are sent to the endpoint you configured. Player names and full game files are not sent. If you turn on Offline only, none of these happen.\n\n'
            'What we do not do: We run no accounts and no servers that hold your data. We do not use analytics, advertising or tracking.',
          ),
          const Divider(height: 24),
          const Text(
            'Open Source Licences & Credits (Story I-2)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const ListTile(
            title: Text('Stockfish Chess Engine & NNUE Network'),
            subtitle: Text('GNU General Public License v3.0 (GPLv3)'),
          ),
          const ListTile(
            title: Text('llama.cpp On-Device Inference'),
            subtitle: Text('MIT License'),
          ),
          const ListTile(
            title: Text('Lichess chess-openings & Puzzle Themes Dataset'),
            subtitle: Text('Creative Commons Zero v1.0 Universal (CC0)'),
          ),
          const ListTile(
            title: Text('Qwen3 (0.6B / 1.7B) & SmolLM3 3B'),
            subtitle: Text('Apache License 2.0'),
          ),
          const ListTile(
            title: Text('Llama 3.2 & Gemma 3 (Catalogue Models)'),
            subtitle: Text('Community / Terms of Use — requires acceptance before first load'),
          ),
          const SizedBox(height: 8),
          Text(
            CopyDeck.tr('disclaimer.affiliation'),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

typedef LicencesScreen = LicencesAndPrivacyScreen;
