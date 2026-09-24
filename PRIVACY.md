# Privacy policy: Local Agent

_Last updated: 24 September 2026_

Local Agent is an AI assistant for Android. It can run AI models entirely on
your phone, or use a cloud model that you choose. This policy explains what
data leaves your phone in each case. The app has no accounts, no ads and no
analytics.

## On-device mode

When you chat with a model downloaded to your phone, your messages, photos and
the model's replies are processed **only on your phone** and never sent to the
developer or anyone else.

Some requests need the internet even in on-device mode:

| Feature | What is sent | To whom |
| --- | --- | --- |
| Web search | Your search query | DuckDuckGo, Microsoft Bing, Google News, Wikipedia |
| Weather | The city you ask about (or your approximate location from your IP address) | wttr.in, Open-Meteo |
| "Play … on YouTube" | The song or video name | YouTube |
| "What's my IP" | Nothing but the request itself | ipify.org |
| Downloading models | The model file name | Hugging Face |

## Cloud mode with your own API key

If you add an API key for Google Gemini, Anthropic Claude, OpenAI, Groq,
OpenRouter or your own server, your messages, attached photos and the results
of the phone actions you ask for (for example a list of matching contacts) are
sent **directly from your phone to that provider**, under the provider's
privacy policy. The developer never sees them.

Your API keys are stored on your phone only, encrypted with a key held in the
Android Keystore.

## Free cloud

Builds that offer "Free cloud" send your messages and photos through the
developer's server to Google Gemini, so you don't need a key. The server
passes the request on and does not store your messages. To enforce fair-use
limits it keeps a counter per install (a random ID created by the app, not
linked to your device or identity) for up to 36 hours. Google processes the
messages under the
[Gemini API terms](https://ai.google.dev/gemini-api/terms); on the free tier
Google may use them to improve its products.

## Reporting a response

If you report an AI response, the response text, the reason you chose and the
model name are sent to the developer (through the Free cloud server, or by
email) so the problem can be investigated. Reports kept on the server are
deleted after 90 days.

## Data stored on your phone

- Chats, saved memories ("remember that …") and settings are stored only on
  your phone. Delete chats in Settings → Delete all chats, memories in Settings
  → Memory; uninstalling the app deletes everything.
- Downloaded models are stored in the app's private storage.

## Permissions

Each permission is requested only when you use the feature that needs it:

| Permission | Used for |
| --- | --- |
| Microphone | Voice input and voice mode. Speech is converted to text by your phone's speech recognition service (usually Google's). |
| Contacts | Finding a contact's number when you ask to call or message someone |
| Calendar | Adding events you ask for |
| Photos and media | Showing your latest screenshot and listing media files when you ask |
| Notification access | Reading your notifications aloud when you ask |
| Alarms | Setting alarms and timers in your clock app |
| Delete apps | Opening Android's uninstall screen when you ask to remove an app |

Calls and messages are never placed or sent by the app itself: it opens your
dialer, WhatsApp or messaging app with the details filled in, and you press
the button.

## Children

Local Agent is not directed at children under 13.

## Changes and contact

Changes to this policy are published in this file in the app's source
repository: <https://github.com/shantoshdurai/Phone-Local-Agent>. For
questions, open an issue there.
