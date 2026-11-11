# MoveMentor Workspace Rules

## 1. Monorepo Package Resolution & CI Parity
- Whenever creating, editing, or modifying CI steps for nested Dart packages under `packages/*`, ensure `dart pub get` (or `flutter pub get`) runs inside every nested package **before** running root `flutter analyze` or root tests.
- Never rely on pre-existing gitignored `.dart_tool/package_config.json` files on the local machine as evidence that clean CI checkouts will resolve sub-package `dev_dependencies` (such as `package:test`). When verifying CI/workflow changes that resolve or analyze multiple packages, confirm dependency installation covers every nested `pubspec.yaml` in execution order.

## 2. Chess Review & Engine Evaluation Invariants
- For every consecutive ply pair `(t, t+1)`, enforce `W_after(t) + W_before(t+1) == 100.0%` (Win% always in `0–100`).
- Derive `isForced` strictly from `legalMoves.length == 1`.
- Never label a move `Blunder` when the mover is already facing a forced checkmate and plays the engine's top resisting move.
- When `W_before <= 5.0%`, centipawn loss `< 300` cp follows normal `deltaW` bands (`deltaW < 1.0` non-top is `Excellent`), not saturation-guard downgrade.
