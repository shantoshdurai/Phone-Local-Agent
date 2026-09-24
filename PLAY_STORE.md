# Publishing to Google Play

Checklist for the first release. Everything in the code is done; these are the
steps only you can do (accounts, keys, store listing).

## 1. Before the first upload

- [ ] **Application ID.** Change `applicationId` in `android/app/build.gradle`
      from `com.localagent.local_agent` to your own, e.g.
      `com.yourname.localagent`. It can never change after the first upload.
      (`namespace` and the Kotlin package can stay as they are.)
- [ ] **Upload key.**
      ```bash
      keytool -genkey -v -keystore ~/upload-keystore.jks -keyalg RSA \
        -keysize 2048 -validity 10000 -alias upload
      ```
      Create `android/key.properties` (already git-ignored):
      ```properties
      storePassword=…
      keyPassword=…
      keyAlias=upload
      storeFile=/home/you/upload-keystore.jks
      ```
      Keep a backup of the keystore and passwords. Use Play App Signing.
- [ ] **Version.** Bump `version:` in `pubspec.yaml` for every upload.
- [ ] **Free cloud (optional).** Deploy `proxy/` (see `proxy/README.md`).
- [ ] **Reporting.** Play requires AI apps to let users report offensive
      output from inside the app. Long-pressing a reply offers "Report this
      response"; it needs either the proxy (reports go to its `/report`
      endpoint) or `--dart-define=SUPPORT_EMAIL=…`.

## 2. Build

```bash
flutter build appbundle --release \
  --dart-define=HOSTED_API_URL=https://local-agent-proxy.<you>.workers.dev \
  --dart-define=HOSTED_APP_TOKEN=local-agent-app \
  --dart-define=SUPPORT_EMAIL=you@example.com
```

Upload `build/app/outputs/bundle/release/app-release.aab`. Play delivers only
the phone's own CPU architecture: about 41 MB on 64-bit ARM phones (checked
with `flutter build apk --split-per-abi`). On-device models are downloaded
inside the app. 32-bit-only phones get the app without on-device models; cloud
mode works there.

## 3. Play Console forms

**Data safety** (matches PRIVACY.md):

- Data collected: none by the developer in on-device mode.
- With Free cloud: "App activity → Other user-generated content" (messages)
  is *shared* with Google for processing, not stored by the developer;
  encrypted in transit; not used for tracking.
- With the user's own API key: data goes from the phone directly to the
  provider the user chose (declare as shared, for app functionality).
- Reports: user-generated content sent to the developer on request.
- Users can delete data: chats and memories in Settings; uninstall removes all.

**Permissions** that need a declaration or justification:

| Permission | Why the app needs it | Note |
| --- | --- | --- |
| `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` | "Show my latest screenshot", "list my photos" | Play asks apps with only occasional photo access to use the photo picker instead. If review rejects it, remove the `get_recent_screenshots` and `list_files` tools and these permissions; attaching photos already uses the picker, which needs no permission. |
| `REQUEST_DELETE_PACKAGES` | "Uninstall X" opens Android's uninstall dialog | Standard permission; describe the feature. |
| Notification listener | "Read my notifications" | Not requested at install; the user enables it in Android settings. Mention it in the description. |
| `READ_CONTACTS`, calendar, microphone | Calls/messages by name, events, voice | Runtime permissions, asked on first use. |

Removed on purpose, don't add back: `QUERY_ALL_PACKAGES`,
`MANAGE_EXTERNAL_STORAGE`, `CALL_PHONE`, `SEND_SMS`, background location.

**Content rating:** the app generates text with AI. Answer the questionnaire
accordingly (user-generated/AI content, no restricted content by design).
Uncensored models are filtered out of the in-app hub.

**AI-generated content policy:** in-app reporting (done), no generation of
restricted content by design, clear disclosure that answers come from AI.

## 4. Store listing ideas

- Short description: "AI assistant that runs on your phone, offline and
  private. Or use Gemini, Claude and more."
- Screenshots: chat with a tool pill, Models hub with the device card, voice
  mode, a theme or two.
- Mention: works offline, no account, bring your own key, open source.

## 5. Test on real phones first

Things the development environment could not check:

- [ ] Model download, load and chat on a mid-range phone (the target:
      8 GB, Dimensity 700 / Mali) and a Snapdragon phone.
- [ ] GPU toggle on an Adreno phone (Settings → Model settings).
- [ ] Photos with Gemma 4 E2B (vision add-on downloaded).
- [ ] Each instant command and permission prompt; WhatsApp/SMS open prefilled.
- [ ] Voice mode start/stop and barge-in.
- [ ] Themes, especially the light ones, on every screen.
