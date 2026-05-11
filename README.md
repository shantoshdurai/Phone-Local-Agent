# Local Agent 🤖📱

An autonomous, file-aware AI agent for Android built with Flutter.

## ✨ Features
*   **Minimalist UI**: Clean, black-themed design inspired by ChatGPT and Claude.
*   **Vision Integration**: Analyzes images and screenshots using Llama-3.2-Vision.
*   **Device Autonomy**: Can manage files, apps, and system settings.
*   **Modular Architecture**: Clean separation between services, models, and UI.

## 🏛 Architecture
- **`lib/services/`**: Core logic for device interaction (Files, Apps, Device Info).
- **`lib/screens/`**: UI screens (Chat, Setup, Onboarding).
- **`lib/widgets/`**: Reusable UI components.
- **`lib/models/`**: Data structures.

## 🚀 Future Roadmap: Local LLM
Planning to integrate a fine-tuned **Llama-3.2-1B** or **Function Gemma** for fully offline, on-device inference using MediaPipe or MLC-LLM.

## 🛠 Setup
1. Add your `GROQ_API_KEY` to a `.env` file.
2. Run `flutter pub get`.
3. Run `flutter run`.
