/**
 * Pi native compaction with a separate thinking level and optional model override.
 * Adapted from JMHSV/pi-compaction-model (MIT License, Copyright 2026 JMHSV).
 * See LICENSE.pi-compaction-thinking in this directory.
 *
 * In ~/.pi/agent/settings.json:
 *   "compactionModel": { "thinkingLevel": "medium" }
 *
 * Omitting or emptying `model` means: use the ACTIVE model at compaction time.
 * Optionally set `model` to "provider/model-id" to pin compaction to that model.
 * Does not modify the thinking level for regular agent turns.
 */
import {
  compact,
  getAgentDir,
  SettingsManager,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";

type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
type Reason = "manual" | "threshold" | "overflow";

const LEVELS: ReadonlySet<string> = new Set(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);
const REASONS: ReadonlySet<string> = new Set(["manual", "threshold", "overflow"]);

type Config = {
  model?: string;
  thinkingLevel?: ThinkingLevel;
  reasons: Reason[];
};

type Settings = Record<string, unknown>;
const isObject = (value: unknown): value is Settings =>
  typeof value === "object" && value !== null && !Array.isArray(value);

function warn(message: string, error?: unknown): void {
  if (error === undefined) console.warn(`[pi-compaction-thinking] ${message}`);
  else console.warn(`[pi-compaction-thinking] ${message}`, error);
}

function configFor(ctx: ExtensionContext): Config | null {
  const settings = SettingsManager.create(ctx.cwd, getAgentDir(), {
    projectTrusted: ctx.isProjectTrusted(),
  });
  const globalSettings = settings.getGlobalSettings();
  const projectSettings = ctx.isProjectTrusted() ? settings.getProjectSettings() : undefined;
  const globalSection = isObject(globalSettings) ? globalSettings.compactionModel : undefined;
  const projectSection = isObject(projectSettings) ? projectSettings.compactionModel : undefined;

  if (projectSection === false || (globalSection === false && projectSection === undefined)) return null;
  if (globalSection === undefined && projectSection === undefined) return null;

  // Keep the upstream behavior: trusted project fields override global fields.
  const merged: Settings = {
    ...(isObject(globalSection) ? globalSection : {}),
    ...(isObject(projectSection) ? projectSection : {}),
  };
  if (merged.enabled === false) return null;

  if (merged.model != null && typeof merged.model !== "string") {
    warn("compactionModel.model must be a string when provided; falling back to native compaction.");
    return null;
  }
  const model = typeof merged.model === "string" ? merged.model.trim() : "";

  let thinkingLevel: ThinkingLevel | undefined;
  if (merged.thinkingLevel != null) {
    if (typeof merged.thinkingLevel !== "string" || !LEVELS.has(merged.thinkingLevel)) {
      warn("Invalid compactionModel.thinkingLevel; falling back to native compaction.");
      return null;
    }
    thinkingLevel = merged.thinkingLevel as ThinkingLevel;
  }

  let reasons: Reason[] = ["manual", "threshold", "overflow"];
  if (merged.reasons !== undefined) {
    if (!Array.isArray(merged.reasons) || !merged.reasons.every(
      (reason) => typeof reason === "string" && REASONS.has(reason),
    )) {
      warn("Invalid compactionModel.reasons; falling back to native compaction.");
      return null;
    }
    reasons = [...new Set(merged.reasons)] as Reason[];
  }
  return { model: model || undefined, thinkingLevel, reasons };
}

/**
 * Pi labels extension compactions as extension-generated, so subsequent native
 * preparation doesn't restore their file-operation lists. Restore the lists
 * from Pi's own compaction detail format before calling the native compact().
 */
function restorePreviousFileOperations(
  preparation: { fileOps: { read: Set<string>; edited: Set<string> } },
  branchEntries: Array<{ type: string; details?: unknown }>,
): void {
  const previous = [...branchEntries].reverse().find((entry) => entry.type === "compaction");
  if (!previous || !isObject(previous.details)) return;
  if (Array.isArray(previous.details.readFiles)) {
    for (const path of previous.details.readFiles) {
      if (typeof path === "string") preparation.fileOps.read.add(path);
    }
  }
  if (Array.isArray(previous.details.modifiedFiles)) {
    for (const path of previous.details.modifiedFiles) {
      if (typeof path === "string") preparation.fileOps.edited.add(path);
    }
  }
}

export default function compactionThinking(pi: ExtensionAPI): void {
  pi.on("session_before_compact", async (event, ctx) => {
    const config = configFor(ctx);
    if (!config || !config.reasons.includes(event.reason)) return;

    // Critical change from the npm extension: no pinned model needed.
    // This resolves on EVERY compaction so switching models takes effect immediately.
    let model = ctx.model;
    if (config.model) {
      const separator = config.model.indexOf("/");
      if (separator <= 0 || separator === config.model.length - 1) {
        warn(`Invalid model '${config.model}'; expected provider/model. Falling back to native compaction.`);
        return;
      }
      model = ctx.modelRegistry.find(
        config.model.slice(0, separator).trim(),
        config.model.slice(separator + 1).trim(),
      );
    }
    if (!model) {
      warn("No compaction model is available; falling back to native compaction.");
      return;
    }

    try {
      const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
      if (!auth.ok) {
        warn(`Cannot resolve credentials for ${model.provider}/${model.id}: ${auth.error}; using native compaction.`);
        return;
      }
      restorePreviousFileOperations(event.preparation, event.branchEntries);
      const result = await compact(
        event.preparation,
        model,
        auth.apiKey,
        auth.headers,
        event.customInstructions,
        event.signal,
        config.thinkingLevel,
        undefined,
        auth.env,
      );
      return { compaction: result };
    } catch (error) {
      if (!event.signal.aborted) {
        warn(`Compaction failed for ${model.provider}/${model.id}; falling back to native compaction.`, error);
      }
      return;
    }
  });
}
