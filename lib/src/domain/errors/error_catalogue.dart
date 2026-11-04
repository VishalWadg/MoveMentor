/// Part 22.4: Complete Error Catalogue with triggers and user-facing actions.
class AppErrorSpec {
  final String code;
  final String trigger;
  final String userAction;
  final bool retryable;

  const AppErrorSpec({
    required this.code,
    required this.trigger,
    required this.userAction,
    this.retryable = false,
  });
}

class ErrorCatalogue {
  static const Map<String, AppErrorSpec> entries = {
    'E-IMP-01': AppErrorSpec(
      code: 'E-IMP-01',
      trigger: 'Lichess or Chess.com 404 for username',
      userAction: 'No account with that name. Edit name.',
      retryable: false,
    ),
    'E-IMP-02': AppErrorSpec(
      code: 'E-IMP-02',
      trigger: 'HTTP 429',
      userAction: 'The site asked us to slow down. Resuming automatically after countdown; partial results kept.',
      retryable: true,
    ),
    'E-IMP-03': AppErrorSpec(
      code: 'E-IMP-03',
      trigger: 'Network error or timeout',
      userAction: 'Network interrupted. Retry resumes from last received game timestamp.',
      retryable: true,
    ),
    'E-IMP-04': AppErrorSpec(
      code: 'E-IMP-04',
      trigger: 'Offline when starting online import',
      userAction: 'Needs internet. Queue for later?',
      retryable: true,
    ),
    'E-IMP-05': AppErrorSpec(
      code: 'E-IMP-05',
      trigger: 'PGN contains no games',
      userAction: 'No valid chess games found in input. Paste or pick another file.',
      retryable: false,
    ),
    'E-IMP-06': AppErrorSpec(
      code: 'E-IMP-06',
      trigger: 'Illegal move at ply N',
      userAction: 'Game marked partially valid; keep valid prefix or skip.',
      retryable: false,
    ),
    'E-IMP-07': AppErrorSpec(
      code: 'E-IMP-07',
      trigger: 'File over 50 MB or 5,000 games',
      userAction: 'File exceeds limit. Offer to import the first 5,000 games.',
      retryable: false,
    ),
    'E-IMP-08': AppErrorSpec(
      code: 'E-IMP-08',
      trigger: 'Non-standard variant',
      userAction: 'Stored in library, marked not analysable in MVP.',
      retryable: false,
    ),
    'E-IMP-09': AppErrorSpec(
      code: 'E-IMP-09',
      trigger: 'Chess.com 410 or closed account',
      userAction: 'Account unavailable. Do not retry that URL.',
      retryable: false,
    ),
    'E-IMP-10': AppErrorSpec(
      code: 'E-IMP-10',
      trigger: 'Chess.com 403',
      userAction: 'This version may be blocked. Please update the app.',
      retryable: false,
    ),
    'E-ENG-01': AppErrorSpec(
      code: 'E-ENG-01',
      trigger: 'Engine fails to start',
      userAction: 'Engine failed to start. Open Diagnostics or restart engine.',
      retryable: true,
    ),
    'E-ENG-02': AppErrorSpec(
      code: 'E-ENG-02',
      trigger: 'Analysis interrupted',
      userAction: 'Analysis paused. Resuming from last saved position.',
      retryable: true,
    ),
    'E-ENG-03': AppErrorSpec(
      code: 'E-ENG-03',
      trigger: 'Thermal pause',
      userAction: 'Your phone is warm, so analysis is running at lower threads.',
      retryable: true,
    ),
    'E-AI-01': AppErrorSpec(
      code: 'E-AI-01',
      trigger: 'Model file missing or corrupt',
      userAction: 'Model file unavailable. Falling back to Template Coach; re-download offered.',
      retryable: true,
    ),
    'E-AI-02': AppErrorSpec(
      code: 'E-AI-02',
      trigger: 'Model too large for free RAM',
      userAction: 'This model is too big for the memory free right now. Try a smaller version.',
      retryable: false,
    ),
    'E-AI-03': AppErrorSpec(
      code: 'E-AI-03',
      trigger: 'Output invalid twice',
      userAction: 'Explained by template. Tap Retry to try again with your chosen provider.',
      retryable: true,
    ),
    'E-AI-04': AppErrorSpec(
      code: 'E-AI-04',
      trigger: 'Remote 401/403',
      userAction: 'Key rejected. Open profile editor to update credentials.',
      retryable: false,
    ),
    'E-AI-05': AppErrorSpec(
      code: 'E-AI-05',
      trigger: 'Remote 429 or 5xx',
      userAction: 'Remote service busy. Retried once, now using Template Coach for this session.',
      retryable: true,
    ),
    'E-AI-06': AppErrorSpec(
      code: 'E-AI-06',
      trigger: 'Remote timeout',
      userAction: 'Remote service timed out. Using Template Coach for this session.',
      retryable: true,
    ),
    'E-AI-07': AppErrorSpec(
      code: 'E-AI-07',
      trigger: 'Offline-only blocks remote',
      userAction: 'Offline-only mode is active. Switch provider or disable Offline-only.',
      retryable: false,
    ),
    'E-AI-08': AppErrorSpec(
      code: 'E-AI-08',
      trigger: 'Cleartext LAN endpoint',
      userAction: 'Not encrypted (local network only). Proceed only on a trusted LAN.',
      retryable: false,
    ),
    'E-DAT-01': AppErrorSpec(
      code: 'E-DAT-01',
      trigger: 'Migration failed',
      userAction: 'Database opened in read-only recovery mode. Export your games now.',
      retryable: false,
    ),
    'E-DAT-02': AppErrorSpec(
      code: 'E-DAT-02',
      trigger: 'Storage low',
      userAction: 'Free storage is below 1.5x required space. Open Storage settings to clear cache.',
      retryable: false,
    ),
  };

  static AppErrorSpec lookup(String code) =>
      entries[code] ??
      AppErrorSpec(
        code: code,
        trigger: 'Unexpected error',
        userAction: 'Something went wrong. Please retry.',
      );
}
