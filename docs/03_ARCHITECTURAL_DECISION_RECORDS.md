# 📜 Architectural Decision Records (ADRs)

An **Architectural Decision Record (ADR)** captures an important architectural decision made along with its context, rationale, and trade-offs. 

This document serves as the historical record of *why* MoveMentor is engineered the way it is, preventing future developers or reviewers from accidentally re-introducing discarded approaches.

---

## Index of Decisions

1. [ADR-01: Offline-First Philosophy & Global Network Chokepoint](#adr-01-offline-first-philosophy--global-network-chokepoint)
2. [ADR-02: Deterministic Tactical Tagging vs Pure LLM Generation](#adr-02-deterministic-tactical-tagging-vs-pure-llm-generation)
3. [ADR-03: Staged Execution — Engine & LLM Never Run Concurrently](#adr-03-staged-execution--engine--llm-never-run-concurrently)
4. [ADR-04: Lichess Win% Probability & Volatility Harmonic Mean Accuracy](#adr-04-lichess-win-probability--volatility-harmonic-mean-accuracy)
5. [ADR-05: 12-Step Response Validator & Dynamic GBNF Grammar](#adr-05-12-step-response-validator--dynamic-gbnf-grammar)
6. [ADR-06: 3-Tier PGN Game Deduplication & Cross-Source Merge](#adr-06-3-tier-pgn-game-deduplication--cross-source-merge)

---

### ADR-01: Offline-First Philosophy & Global Network Chokepoint

- **Status**: Accepted (Design Decision `D-14`, Part 8.2)
- **Context**: 
  Chess players frequently study during commutes (subways, flights) or have limited data connectivity. Furthermore, chess players value privacy and do not want their games, usernames, or training weaknesses uploaded to an unknown cloud server.
- **Decision**:
  MoveMentor is strictly **offline-first**. All analysis, database queries, and coaching features run entirely on-device without an internet connection. 
  "Offline-only Mode" is enabled by default on first launch. All network requests (Lichess/Chess.com fetchers, remote LLMs) must flow through a single gateway chokepoint (`NetworkGatewayAdapter`). When offline mode is active, the gateway immediately rejects network calls and logs an audit record locally.
- **Consequences**:
  - *Positive*: Uncompromising privacy; zero operational cloud server costs; the app works seamlessly in airplane mode.
  - *Negative*: Fetching games from Lichess or Chess.com requires the user to explicitly tap "Go Online".

---

### ADR-02: Deterministic Tactical Tagging vs Pure LLM Generation

- **Status**: Accepted (Requirement `FR-13`, Part 24)
- **Context**:
  Large Language Models (LLMs) are notorious for hallucinating board geometry in chess (e.g., calling a simple piece trade a "knight fork" or asserting a pin exists when a square is empty). In chess coaching, factual accuracy is non-negotiable—if an app tells a student they missed a fork when they didn't, trust is permanently destroyed.
- **Decision**:
  The LLM is **never allowed to identify tactics on its own**. 
  Instead, MoveMentor uses a deterministic tactical engine (`TagDetector`) running 15+ algorithmic motif detectors based on board raycasting, piece connectivity, mate vectors, and Static Exchange Evaluation (`SeeEvaluator`). The governing rule: *If a detector is not mathematically certain, it emits nothing.*
- **Consequences**:
  - *Positive*: 100% factual accuracy. When MoveMentor says "You walked into an absolute pin on the d-file", that pin is guaranteed to exist.
  - *Negative*: Requires writing and maintaining pure Dart geometry and tactical heuristic algorithms.

---

### ADR-03: Staged Execution — Engine & LLM Never Run Concurrently

- **Status**: Accepted (Decision `AD-2`, Non-Functional Requirement `NFR-03`)
- **Context**:
  Modern mobile devices have strict memory (RAM) and thermal management limits. Stockfish 16 NNUE uses multiple CPU threads and memory hash tables to calculate deep positions. Running a local quantized neural model (`llama.cpp`) at the exact same time as Stockfish leads to thermal CPU throttling, battery drain, and Android OS Out-Of-Memory (OOM) app kills.
- **Decision**:
  The analysis pipeline is split into distinct sequential stages:
  - **Stages 1–5**: Stockfish runs position evaluations, win equity curves are computed, move classifications are assigned, critical moments are filtered, and deterministic tags are emitted. Stockfish then releases its CPU lock.
  - **Stage 6**: The active coach (`ExplanationProvider`) generates natural-language explanations only for the curated critical moments.
- **Consequences**:
  - *Positive*: Maximum device stability, prevents thermal overheating, and allows MoveMentor to run smoothly even on modest budget phones (4 GB RAM).
  - *Negative*: Explanations for critical moments appear after the initial engine evaluation pass completes rather than in parallel.

---

### ADR-04: Lichess Win% Probability & Volatility Harmonic Mean Accuracy

- **Status**: Accepted (Part 11.3, 11.4, 19-8)
- **Context**:
  Early chess software calculated accuracy using Average Centipawn Loss (ACPL). However, ACPL is deeply flawed: blundering 200 centipawns in an equal position ($0.0 \rightarrow -2.0$) completely ruins a game, whereas blundering 200 centipawns when you are already winning by +12.0 ($+12.0 \rightarrow +10.0$) has zero impact on the outcome.
- **Decision**:
  MoveMentor calculates accuracy from **Win Probability Drops ($\Delta W$)**:
  $$W(\text{cp}) = 50 + 50 \cdot \left(\frac{2}{1 + e^{-0.00368208 \cdot \text{cp}}} - 1\right)$$
  $$\text{Accuracy} = \text{clamp}\left(103.1668 \cdot e^{-0.04354 \cdot \Delta W} - 3.1669, 0, 100\right)$$
  Overall game accuracy is computed as the composite average of a **volatility-weighted mean** (giving higher weight to complex, volatile positions) and a **harmonic mean** (which heavily penalizes blunders):
  $$\text{Game Accuracy} = \frac{A_V + A_H}{2}$$
- **Consequences**:
  - *Positive*: Accuracies closely match modern Lichess and Chess.com player expectations and reflect true human game performance.
  - *Negative*: Requires slightly more mathematical computation per ply than simple centipawn subtraction.

---

### ADR-05: 12-Step Response Validator & Dynamic GBNF Grammar

- **Status**: Accepted (Business Rule `BR-4`, Part 22 & 23)
- **Context**:
  When using local or remote LLMs, responses can include invalid JSON, code block markdown fences, toxic or shaming language, or hallucinated moves.
- **Decision**:
  All AI responses must pass through an automated **12-Step Validator** (`CoachResponseValidator`):
  1. Extract and repair JSON from code fences.
  2. Parse JSON syntax.
  3. **Fact Overwrite**: Automatically overwrite `move`, `classification`, and `win_equity_drop` with ground-truth engine values (impossible for LLM to hallucinate them).
  4. Validate required fields (`tactical_summary`, `coach_commentary`, `better_idea`, `lesson`) and length limits.
  5. Validate move legality on the actual board.
  6. Verify piece existence on the target square.
  7. Check polarity consistency (no praising blunders or scolding brilliant moves).
  8. Ban shaming vocabulary and non-chess advice.
  9. Enforce rating-band vocabulary (no advanced jargon like "zugzwang" for novices).
  10. Validate SAN words formatting.
  11. Allow a single retry with prompt correction if a minor failure occurs.
  12. **Deterministic Fallback**: If the LLM output fails twice, immediately fall back to the built-in Template Coach for that moment.
- **Consequences**:
  - *Positive*: Guaranteed safety and professional tone; no crashes from malformed JSON; zero legal move hallucinations.
  - *Negative*: Non-compliant model outputs are discarded and replaced with template commentary.

---

### ADR-06: 3-Tier PGN Game Deduplication & Cross-Source Merge

- **Status**: Accepted (Part 26.4)
- **Context**:
  Users often import games from multiple sources: pasting a PGN, importing from Lichess, importing from Chess.com, or uploading a ZIP file. This leads to duplicate games cluttering the library.
- **Decision**:
  MoveMentor implements a 3-tier deduplication algorithm:
  1. **Source ID Match**: Exact match on `(source, sourceGameId)` (e.g., Lichess game URL).
  2. **Move Hash Fingerprint**: SHA-256 hash of the normalized move list (`movesSan`).
  3. **Cross-Source Merge**: If the same game is imported from two places, the existing game row is preserved while missing metadata (tags, clock times, opening names) is merged without duplicating positions or engine evals.
- **Consequences**:
  - *Positive*: Database stays clean and compact; duplicate engine analysis passes are completely avoided.
  - *Negative*: Importing large ZIP archives requires calculating move hashes for all candidate games.
