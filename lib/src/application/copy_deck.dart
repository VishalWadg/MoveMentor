/// Part 28.5 & FR-20: Externalised user-visible strings with tone rules enforced:
/// never shame; no centipawns in default UI; always name one next action.
class CopyDeck {
  static const Map<String, String> en = {
    'status.offline':
        'Offline mode. Your games and analysis stay on this phone.',
    'status.online': 'Online features available.',
    'import.queue':
        'Needs internet. We can import these games when you are back online.',
    'import.ratelimit':
        'The site asked us to slow down. Resuming in {seconds} s.',
    'import.dupes':
        '{n} games were already in your library and were skipped.',
    'analysis.running': 'Analysing on your phone. You can leave the app.',
    'analysis.thermal':
        'Your phone is warm, so analysis is running more slowly.',
    'coach.template_marker': 'Explained by template',
    'coach.retry': 'Try again with {provider}',
    'remote.consent_title': 'Send this to your chosen AI service?',
    'remote.consent_body':
        'Only the position and move facts shown below leave your phone. No player names.',
    'model.too_large':
        'This model is too big for the memory free right now. Try a smaller version.',
    'delete.confirm':
        'Delete {n} games and their analysis? This cannot be undone.',
    'empty.library': 'No games yet. Add one to get your first review.',
    'error.generic_action': 'Something went wrong. {action}',
    'disclaimer.affiliation':
        'Not affiliated with or endorsed by Lichess or Chess.com.',
    'engine.unreliable_analysis_title':
        'Approximate review (fallback engine)',
    'engine.unreliable_analysis_body':
        'This game used the 2-ply fallback because Stockfish was unavailable. Configure Stockfish and re-analyse for reliable move labels.',
    'engine.unavailable_title': 'Stockfish engine unavailable',
    'engine.unavailable_body':
        'No local Stockfish binary was found, so new analysis will fall back to an unreliable 2-ply estimate. Configure Stockfish before running review.',
    'engine.diagnostics_fallback_title':
        'Fallback engine active (unreliable)',
    'engine.diagnostics_fallback_body':
        'Real Stockfish could not start, so MoveMentor is using Minimax-2Ply fallback. Set STOCKFISH_PATH or place a Stockfish binary in a standard path.',
  };

  static String tr(String key, [Map<String, String> params = const {}]) {
    var text = en[key] ?? key;
    params.forEach((k, v) {
      text = text.replaceAll('{$k}', v);
    });
    return text;
  }
}
