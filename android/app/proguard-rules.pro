# ── Inference engine ────────────────────────────────────────────────────────
# flutter_gemma ships consumer rules for MediaPipe/protobuf/Guava, but keep them
# here too so an SDK upgrade that drops its AAR rules cannot silently strip
# classes that native code calls back into via JNI/reflection.
-keep class com.google.mediapipe.** { *; }
-dontwarn com.google.mediapipe.**
-keep class com.google.mediapipe.proto.** { *; }
-keepclassmembers class com.google.mediapipe.tasks.genai.llminference.LlmInference { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**
-keep class com.google.ai.edge.localagents.** { *; }
-dontwarn com.google.ai.edge.localagents.**

# ONNX Runtime (used for the MiniLM tool/memory embeddings).
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# ── Manifest-declared components ────────────────────────────────────────────
# AGP's default rules keep Activity/Service/Receiver subclasses, but these are
# instantiated by the system from the manifest by name, so be explicit.
-keep class de.julianassmann.flutter_background.** { *; }
-keep class notification.listener.service.** { *; }
-keep class com.localagent.local_agent.** { *; }

# ── Plugins reached through the platform-channel registrant ─────────────────
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }

# Optional dependencies referenced by transitive SDK code but not shipped.
-dontwarn org.slf4j.**
-dontwarn javax.annotation.**
-dontwarn kotlinx.coroutines.**
