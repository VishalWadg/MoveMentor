# MoveMentor — Offline AI Chess Mentor

**MoveMentor** is an autonomous, offline-first AI Chess Mentorship mobile application built with **Flutter (Material 3)**, **Riverpod**, **SQLite / Drift schema**, **Stockfish 16.1 NNUE**, a deterministic **15+ motif Tactic & Positional Tag Detector**, and a pluggable **Modular AI Explanation Layer** (**Template Coach**, **Built-in Local GGUF Model via `llama.cpp`**, **User-Imported Local `.gguf` Model**, and **Bring-Your-Own Remote API**).

> *"Every chess player gets a patient coach in their pocket that works on a plane, costs nothing per game, and never sends their games anywhere unless they choose."*

---

## 📚 Complete Project Documentation Suite

For developers, beginners, and reviewers, comprehensive documentation is organized in the [`docs/`](docs/) directory:

- 🏛️ [**01. Architecture Overview**](docs/01_ARCHITECTURE_OVERVIEW.md) — Hexagonal (Ports & Adapters) design, 5 core layers, dependency inversion, and Mermaid system architecture diagram.
- 🛠️ [**02. Tech Stack Deep Dive**](docs/02_TECH_STACK_DEEP_DIVE.md) — Why Flutter, Riverpod, Stockfish 16 NNUE, SQLite/FTS5, and on-device GGUF inference were chosen.
- 📜 [**03. Architectural Decision Records (ADRs)**](docs/03_ARCHITECTURAL_DECISION_RECORDS.md) — Historical trade-offs: offline-first privacy chokepoint, deterministic tactic detection vs LLM hallucinations, staged execution, and Win% accuracy formulas.
- ⚡ [**04. Pipeline & Data Flow**](docs/04_PIPELINE_AND_DATA_FLOW.md) — Tracing a game move through the 6-stage pipeline from raw PGN to Stockfish evaluations, $\Delta W$ drop, critical moments, tags, and AI coaching.
- 🎓 [**05. Beginner's Guide & Walkthrough**](docs/05_BEGINNER_GUIDE_AND_WALKTHROUGH.md) — "Explain Like I'm 5" (ELI5), folder mental map, code walkthrough, and technical interview questions & answers.

---

## Key Features & Architecture

1. **Hexagonal (Ports & Adapters) Architecture**:
   - **Presentation Layer (`lib/src/presentation/`)**: All 16 screens from the Product & Engineering Documentation Pack (Parts I & II), interactive custom `InteractiveChessBoard` widget with TalkBack/VoiceOver semantics on every square (`"White knight on f3"`), best-move arrow overlay, tap-to-jump `EvalGraphWidget`, and original shape+icon+text move classification badges (`Book`, `Brilliant`, `Great`, `Best`, `Excellent`, `Good`, `Inaccuracy`, `Mistake`, `Blunder`).
   - **Application Layer (`lib/src/application/`)**: 6-stage `AnalysisPipelineService` (Engine evaluation $ightarrow$ Win% & Volatility-weighted + Harmonic mean Accuracy $ightarrow$ Move Classification $ightarrow$ Critical Moment Selection $ightarrow$ Deterministic Tagging $ightarrow$ Streaming AI Coach Explanation), `ExportService` (Offline PDF Game Report, Annotated PGN, Full JSON+PGN ZIP export, Redacted Diagnostics), and externalised `CopyDeck` (`FR-20`).
   - **Domain Layer (`lib/src/domain/`)**:
     - **Formulas (`Part 11.3, 11.4, 19-8, 30.2`)**: Exact Lichess win-probability mapping, move accuracy curve, sliding-window volatility $k = \text{clamp}(\lfloor \text{plies}/10 \rfloor, 2, 8)$, and precedence-ordered move classification (`Lichess 10/20/30` default preset and `PDF 5/10/20` preset).
     - **Tactic & Positional Detectors (`Part 24`)**: Static Exchange Evaluation (`SeeEvaluator`) powering `MATE_THREAT`, `HANGING_PIECE`, `MATERIAL_LOSS/GAIN`, `FORK_KNIGHT`, `FORK_PAWN`, `PIN_ABSOLUTE`, `PIN_RELATIVE`, `DISCOVERED_CHECK/ATTACK`, `BACK_RANK`, `PIECE_SACRIFICE`, `PROMOTION_RACE`, `UNCASTLED`, `PASSED_PAWN`, `OPEN_FILE`, and `CAPTURE_RECAPTURE`.
     - **AI Contracts, Dynamic GBNF Grammar & 12-Step Validator (`Part 22 & 23`)**: Engine facts (`move`, `classification`, `win_equity_drop`) are baked into the per-request GBNF grammar and overwritten by the 12-step provider-agnostic validator, which verifies move legality, piece-on-square existence, polarity consistency, and injection hygiene.
   - **Ports & Adapters (`lib/src/ports/`, `lib/src/adapters/`)**:
     - **SQLite Schema (`Part 21`)**: All 15 tables (`game`, `position`, `engine_eval`, `move_analysis`, `game_summary`, `critical_moment`, `tag`, `explanation`, `provider_profile`, `model_asset`, `saved_handle`, `import_job`, `opening`, `stats_snapshot`, `settings`) + `game_fts` FTS5 search, cascading deletes, and 3-tier deduplication & cross-source merge (`Part 26.4`).
     - **Single Network Gateway Chokepoint (`AD-8`, `H-3`)**: Enforces the global `Offline only` switch (ON by default at first run per `D-14`) and logs `(host, purpose, sizeBytes, timestamp)` locally without ever logging payload content or secrets.
     - **Game Sources (`Part 10 & 26`)**: Offline PGN file/paste/share-sheet, ZIP batch import (`Story B-7`), Lichess streaming importer (`HTTP 429` $\ge 60\text{s}$ countdown), and Chess.com sequential monthly archive importer with `ETag` conditional caching and compliant `User-Agent: MoveMentor/0.2.0 (contact: support@movementor.app)`.

---

## Automated GitHub Actions CI/CD Workflows

This repository includes two ready-to-use GitHub Actions workflows in `.github/workflows/`:

1. **`.github/workflows/build-apk.yml` — Build APK on Every Push & Pull Request**:
   - Triggers automatically whenever code is pushed to any branch or a pull request is opened.
   - Sets up Java 17 & Flutter stable, verifies the CC0 ECO opening database (`tool/build_openings_db.dart`), runs `flutter analyze` and `flutter test` (verifying all Part 30 Golden Vectors and Provider Contracts), builds split-ABI and universal release APKs, and uploads `MoveMentor-<sha>.apk` as a downloadable workflow artifact.

2. **`.github/workflows/release-apk.yml` — Automated GitHub Release on Tag Push**:
   - Triggers automatically whenever you push a version tag (e.g., `v0.2.0`, `v1.0.0`).
   - Builds universal (`MoveMentor-<tag>-universal.apk`) and architecture-specific (`arm64-v8a`, `armeabi-v7a`, `x86_64`) release APKs, generates `SHA256SUMS.txt`, and publishes a GitHub Release with release notes and all APK binaries attached.

### Optional Android Keystore Signing Secrets
Out of the box, both workflows succeed with zero configuration by falling back to a default signing key if no secrets are set. To sign release APKs with your own production keystore, add these 4 repository secrets under **Settings $ightarrow$ Secrets and variables $ightarrow$ Actions**:
- `ANDROID_KEYSTORE_BASE64`: Base64-encoded `.jks` or `.keystore` file (`base64 -w 0 upload-keystore.jks`)
- `ANDROID_KEY_ALIAS`: Your key alias
- `ANDROID_KEY_PASSWORD`: Your key password
- `ANDROID_STORE_PASSWORD`: Your keystore password

---

## Quick Start: Unzip, Push & Release

```bash
# 1. Unzip MoveMentor.zip into your repository folder
unzip MoveMentor.zip -d MoveMentor
cd MoveMentor

# 2. Initialize Git and push to your GitHub repository (triggers build-apk.yml)
git init
git add .
git commit -m "Initial commit: MoveMentor Offline AI Chess Mentor"
git branch -M main
git remote add origin https://github.com/<your-username>/MoveMentor.git
git push -u origin main

# 3. Create and push a version tag to publish a GitHub Release with APKs (triggers release-apk.yml)
git tag v0.2.0
git push origin v0.2.0
```

---

## Licences & Attribution
- **MoveMentor Application Code**: GNU General Public License v3.0 (`LICENSE`).
- **Stockfish Engine & NNUE**: GPLv3.
- **Lichess `chess-openings` & Puzzle Themes**: CC0 1.0 Public Domain.
- *Not affiliated with or endorsed by Lichess or Chess.com.*
