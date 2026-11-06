# 🎓 Beginner's Guide & Walkthrough — How to Learn & Present MoveMentor

If you are a beginner software developer, congratulations on exploring **MoveMentor**! This guide is designed specifically for you: it breaks down the project into simple mental models, provides an "Elevator Pitch" you can memorize, maps out every folder in the codebase, and prepares you for technical interview questions.

---

## 1. MoveMentor "Explained Like I'm 5" (ELI5)

Imagine you play a chess game on your phone while traveling on a flight without internet:
- **Chess.com or Lichess** usually requires an internet connection to send your game to their cloud servers for analysis.
- **MoveMentor** has its own chess grandmaster brain (Stockfish) and coach built right inside your phone!
- When you finish playing, MoveMentor calculates your accuracy, identifies your biggest mistakes, explains them in friendly, encouraging English, and saves your progress—all while your phone stays in Airplane Mode, costing you \$0 in subscription fees.

---

## 2. The 60-Second Elevator Pitch

> *"MoveMentor is an offline-first AI chess mentor built in Flutter and Dart. Unlike existing chess apps that rely on cloud servers and expensive subscriptions, MoveMentor runs Stockfish 16 NNUE and deterministic tactic detection entirely on-device.*
> 
> *It features a modular coaching architecture: a 0 MB built-in Template Coach that runs 100% offline out-of-the-box, optional local GGUF neural models via llama.cpp, and BYO remote APIs. It prevents AI hallucinations using a 12-step validation pipeline and dynamic GBNF grammars, ensuring that every move and tactic explanation is mathematically verified against the engine."*

---

## 3. Mental Map of the Project Folders

When opening a large codebase, it's easy to feel lost. Here is how the folders map to real-world concepts:

```
d:\MoveMentor\
├── assets/                  📁 Static files packaged with the app
│   ├── copy/en.json         → Externalized UI strings and translations
│   ├── models/              → On-device GGUF model catalogue metadata
│   └── openings/            → Opening book (ECO codes & names)
│
├── lib/                     📁 The Application Source Code
│   ├── main.dart            → The front door: initializes storage & launches UI
│   └── src/
│       ├── domain/          🧠 The timeless chess rules, math & tactic algorithms
│       ├── ports/           🔌 The sockets: abstract interfaces & contracts
│       ├── adapters/        🛠️ The plugs: Stockfish UCI, SQLite, network, AI engines
│       ├── application/     🎼 The conductors: analysis pipeline & state management
│       └── presentation/    📱 The UI: 16 Flutter screens, board widgets & graphs
│
├── test/                    🧪 Automated unit & regression test suites
│   ├── airplane_mode_suite_test.dart  → Verifies 100% offline workflow (NFR-07)
│   ├── golden_vectors_test.dart       → Verifies mathematical accuracy curves
│   └── provider_contract_and_validator_test.dart → Verifies AI validator
│
├── .github/workflows/       🚀 CI/CD automation
│   └── build-apk.yml        → Compiles release APKs & notifies Telegram on push
│
└── pubspec.yaml             📦 Project manifest & dependencies list
```

---

## 4. Code Walkthrough: Tracing a User Action

Let's trace what happens in the code when a user taps **"Analyze Game"**:

1. **User Interaction ([`movementor_screens.dart`](file:///d:/MoveMentor/lib/src/presentation/screens/movementor_screens.dart))**:
   - The user taps the *"Analyze"* button on the Game Review screen.
   - The UI calls `ref.read(appServicesProvider).pipeline.analyseGame(game.id)`.
2. **Analysis Pipeline ([`analysis_pipeline_service.dart`](file:///d:/MoveMentor/lib/src/application/analysis_pipeline_service.dart))**:
   - The pipeline fetches the positions of the game from the SQLite database.
   - It streams progress updates back to the UI (`stage: 'evaluating'`).
3. **Engine Evaluation ([`stockfish_engine_adapter.dart`](file:///d:/MoveMentor/lib/src/adapters/engine/stockfish_engine_adapter.dart))**:
   - Sends the FEN of each position to Stockfish via UCI stdin.
   - Receives centipawns, depth, and best line (`pv`) via UCI stdout.
4. **Accuracy Calculation ([`win_accuracy_calculator.dart`](file:///d:/MoveMentor/lib/src/domain/analysis/win_accuracy_calculator.dart))**:
   - Computes win equity drop $\Delta W$ and per-move accuracy.
5. **Selecting Critical Moments ([`critical_moment_selector.dart`](file:///d:/MoveMentor/lib/src/domain/analysis/critical_moment_selector.dart))**:
   - Filters down to the 5–8 most instructive mistakes and brilliancies.
6. **Tactical Tagging ([`tag_detector.dart`](file:///d:/MoveMentor/lib/src/domain/tags/tag_detector.dart))**:
   - Determines deterministic tactical tags (e.g., `HANGING_PIECE`, `FORK_KNIGHT`).
7. **Coaching Explanation ([`template_coach_provider.dart`](file:///d:/MoveMentor/lib/src/adapters/providers/template_coach_provider.dart))**:
   - Formulates the 4-part explanation tailored to the player's rating band.
8. **UI Update**:
   - The UI receives the completed game entity, re-renders the interactive board with best-move arrows, and populates the coach commentary cards.

---

## 5. Technical Interview Questions & Answers

If you discuss MoveMentor in an interview or portfolio review, here are the most common questions you will be asked and how to answer them like a senior engineer:

### Q1: *"Why didn't you just send the chess game directly to ChatGPT or Claude?"*
**Answer**:
> *"Sending raw PGNs to general LLMs has three major problems:*
> 1. *Cost and Privacy: Cloud LLMs cost money per API call and leak user games to third-party servers.*
> 2. *Offline Failure: General LLMs cannot run on an airplane without an active internet connection.*
> 3. *Hallucinations: LLMs are notoriously bad at computing chess geometry—they frequently hallucinate illegal moves or invent tactical motifs that don't exist.*
> *MoveMentor solves this by decoupling calculation from coaching: Stockfish computes ground truth, deterministic algorithms verify tactical motifs, and the AI is strictly confined to generating natural language commentary based on verified facts."*

---

### Q2: *"How can MoveMentor offer AI coaching with a 0 MB download?"*
**Answer**:
> *"MoveMentor ships with a built-in **Template Coach** (`template`). It uses a compositional rule engine that combines Stockfish evaluations with 15+ deterministic tactical tags, 4 rating bands, and varied human-authored prose templates.*
> *Because it relies on algebraic logic and string interpolation rather than neural network weights, it requires 0 MB of extra downloads and executes in under 2 milliseconds!"*

---

### Q3: *"How do you guarantee the AI will never output an illegal move?"*
**Answer**:
> *"We use a two-layer defense:*
> 1. *Grammar Constrained Decoding (GBNF): For local LLMs, we construct a dynamic grammar that restricts the model's vocabulary to syntactically valid JSON containing only legal chess moves.*
> 2. *The 12-Step Response Validator: Every generated response is intercepted by `CoachResponseValidator`. Step 3 overwrites the move and classification with engine facts, Step 5 simulates the suggested alternative on a headless chess board to verify legality, and Step 12 automatically falls back to the deterministic Template Coach if validation fails."*

---

### Q4: *"Why did you use Hexagonal Architecture instead of standard MVC?"*
**Answer**:
> *"Hexagonal Architecture cleanly separates core business logic from infrastructure dependencies. The domain layer has zero imports from Flutter or SQLite, which means our chess calculations and tactical detectors can be unit-tested in milliseconds without launching emulators. It also allows us to swap the chess engine or database without touching our core chess rules."*

---

### Q5: *"How do you prevent phone overheating and out-of-memory crashes?"*
**Answer**:
> *"We enforce two rules:*
> 1. *Staged Non-Concurrent Execution: Stockfish and the LLM never run at the same time. Stockfish finishes evaluating positions and releases CPU threads before coaching explanations begin.*
> 2. *Model RAM Guard: Before loading any on-device neural model, MoveMentor evaluates device RAM using the formula `Footprint = FileSize * 1.2 + KV Cache`. If the footprint exceeds 70% of available RAM, loading is blocked with a clear warning, preventing OS crashes."*
