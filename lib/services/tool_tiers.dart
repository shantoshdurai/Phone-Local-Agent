/// Tiered exposure of the tool catalog to LLMs of different sizes.
///
/// Why this exists: flutter_gemma injects every tool we register into the
/// chat template as a JSON declaration. On a 1.5B-param model with a 1280
/// KV-cache cap, the full 26-tool catalog adds ~700-900 tokens of context,
/// blows prefill out to 100s+, and frequently causes the model to recite
/// tool descriptions verbatim instead of selecting one. Larger models
/// (4B+) tolerate the full catalog fine.
///
/// The fix is per-model budgets ([ModelSpec.toolBudget]) + this tier
/// system: tools are categorized by how essential they are, and
/// [selectForBudget] fills the budget core-first → common → niche so even
/// the tiniest model always gets the high-frequency essentials and only
/// loses tail features.
///
/// ToolRuntime still executes all 26 tools — this only narrows what the
/// LLM **sees** in its function-call template. So adding a 7B model to
/// the registry with toolBudget=26 unlocks the full agent without
/// touching runtime code; adding a 1B model with toolBudget=6 keeps it
/// focused without losing capability at the runtime layer.
library;

enum ToolTier {
  /// Foundational queries every agent must answer about the device. If a
  /// budget is too small to fit all of these we still include them — a
  /// model without get_device_info is broken from the user's POV.
  core,

  /// High-frequency UX wins. Device control + everyday personal queries.
  /// Added in order until budget hit.
  common,

  /// Specialized or context-heavy tools where occasional unavailability
  /// is acceptable. Only reach this tier on larger models.
  niche,
}

/// Tier for each tool name. Keep in sync with kToolCatalog in tool_runtime.dart
/// when adding/removing tools — a missing entry defaults to [ToolTier.niche]
/// (visible only on big-budget models), which is the safe default.
const Map<String, ToolTier> kToolTiers = {
  // ─── core (5) ──────────────────────────────────────────────────────
  'get_device_info': ToolTier.core,
  'get_date_time': ToolTier.core,
  'check_connectivity': ToolTier.core,
  'launch_app_by_name': ToolTier.core,
  'search_web': ToolTier.core,

  // ─── common (11) ───────────────────────────────────────────────────
  'toggle_flashlight': ToolTier.common,
  'set_volume': ToolTier.common,
  'vibrate': ToolTier.common,
  'copy_to_clipboard': ToolTier.common,
  'read_clipboard': ToolTier.common,
  'set_timer': ToolTier.common,
  'set_alarm': ToolTier.common,
  'search_contacts': ToolTier.common,
  'make_phone_call': ToolTier.common,
  'list_apps': ToolTier.common,
  'open_url': ToolTier.common,

  // ─── niche (10) ────────────────────────────────────────────────────
  'send_whatsapp': ToolTier.niche,
  'schedule_event': ToolTier.niche,
  'list_files': ToolTier.niche,
  'get_recent_screenshots': ToolTier.niche,
  'get_public_ip': ToolTier.niche,
  // launch_app (by package) is niche because launch_app_by_name (core)
  // is the friendlier UX path — package names need lookup the model
  // can't do reliably.
  'launch_app': ToolTier.niche,
  'uninstall_app': ToolTier.niche,
  'search_play_store': ToolTier.niche,
  'open_play_store': ToolTier.niche,
  'read_notifications': ToolTier.niche,
};

/// Tier order used by [selectForBudget]. Constant — exposed for tests
/// and so future budget tweaks read off one source of truth.
const List<ToolTier> kTierOrder = [
  ToolTier.core,
  ToolTier.common,
  ToolTier.niche,
];

/// Filter [allToolNames] down to the [budget]-sized subset the model
/// should see. Preserves declaration order within each tier so the
/// LLM's tool list stays stable across builds.
///
/// Core tools are always returned in full, even if that pushes past
/// [budget] — the alternative is a model that can't answer "what's my
/// battery" because budget=3 and the slot got taken by toggle_flashlight.
/// Common and niche tiers each contribute in declaration order until the
/// budget is hit or the tier is exhausted.
List<String> selectForBudget(List<String> allToolNames, int budget) {
  final byTier = <ToolTier, List<String>>{
    for (final t in kTierOrder) t: [],
  };
  for (final name in allToolNames) {
    final tier = kToolTiers[name] ?? ToolTier.niche;
    byTier[tier]!.add(name);
  }

  final out = <String>[];
  out.addAll(byTier[ToolTier.core]!);
  for (final tier in [ToolTier.common, ToolTier.niche]) {
    for (final name in byTier[tier]!) {
      if (out.length >= budget) return out;
      out.add(name);
    }
  }
  return out;
}
