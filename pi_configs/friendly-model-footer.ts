import { relative, resolve, sep, isAbsolute } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

function fmt(n: number): string {
  if (n < 1000) return String(n);
  if (n < 10_000) return `${(n / 1000).toFixed(1)}k`;
  if (n < 1_000_000) return `${Math.round(n / 1000)}k`;
  return `${(n / 1_000_000).toFixed(1)}M`;
}

function shortCwd(cwd: string): string {
  const home = process.env.HOME || process.env.USERPROFILE;
  if (!home) return cwd;

  const rcwd = resolve(cwd);
  const rhome = resolve(home);
  const rel = relative(rhome, rcwd);

  const inside =
    rel === "" ||
    (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));

  if (!inside) return cwd;
  return rel === "" ? "~" : `~${sep}${rel}`;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.setFooter((tui, theme, footerData) => {
      const unsubscribe = footerData.onBranchChange(() =>
        tui.requestRender()
      );

      return {
        dispose: unsubscribe,
        invalidate() {},

        render(width: number): string[] {
          // ----- First line: cwd / git branch / session name -----

          let cwd = shortCwd(ctx.cwd);

          const branch = footerData.getGitBranch();
          if (branch) cwd += ` (${branch})`;

          const sessionName = ctx.sessionManager.getSessionName?.();
          if (sessionName) cwd += ` • ${sessionName}`;

          const cwdLine = truncateToWidth(
            theme.fg("dim", cwd),
            width,
            theme.fg("dim", "...")
          );

          // ----- Usage totals -----

          let input = 0;
          let output = 0;
          let cacheRead = 0;
          let cacheWrite = 0;
          let cost = 0;

          for (const entry of ctx.sessionManager.getEntries()) {
            const e = entry as any;

            const usage =
              e.type === "message"
                ? e.message?.usage
                : e.type === "branch_summary" || e.type === "compaction"
                  ? e.usage
                  : undefined;

            if (!usage) continue;

            input += usage.input ?? 0;
            output += usage.output ?? 0;
            cacheRead += usage.cacheRead ?? 0;
            cacheWrite += usage.cacheWrite ?? 0;
            cost += usage.cost?.total ?? 0;
          }

          const parts: string[] = [];

          if (input) parts.push(`↑${fmt(input)}`);
          if (output) parts.push(`↓${fmt(output)}`);
          if (cacheRead) parts.push(`R${fmt(cacheRead)}`);
          if (cacheWrite) parts.push(`W${fmt(cacheWrite)}`);
          if (cost) parts.push(`$${cost.toFixed(3)}`);

          // ----- Context usage -----

          const context = ctx.getContextUsage();

          if (context) {
            const pct =
              context.percent == null
                ? "?"
                : context.percent.toFixed(1);

            parts.push(`${pct}%/${fmt(context.contextWindow)}`);
          }

          let left = parts.join(" ");

          // ----- Friendly model name -----
          //
          // THIS is the relevant difference from Pi's stock footer:
          // stock: model.id
          // here:  model.name, with id as fallback

          const model =
            ctx.model?.name ||
            ctx.model?.id ||
            "no-model";

          let right = model;

          if (ctx.model?.reasoning) {
            const thinking = pi.getThinkingLevel();
            right =
              thinking === "off"
                ? `${model} • thinking off`
                : `${model} • ${thinking}`;
          }

          // Match stock behavior: show provider when there's room.
          if (
            ctx.model &&
            footerData.getAvailableProviderCount() > 1
          ) {
            const withProvider = `(${ctx.model.provider}) ${right}`;

            if (
              visibleWidth(left) +
                2 +
                visibleWidth(withProvider) <=
              width
            ) {
              right = withProvider;
            }
          }

          // ----- Align model to right -----

          if (visibleWidth(left) > width) {
            left = truncateToWidth(left, width, "...");
          }

          const leftWidth = visibleWidth(left);
          const rightWidth = visibleWidth(right);

          let statsLine: string;

          if (leftWidth + 2 + rightWidth <= width) {
            statsLine =
              left +
              " ".repeat(width - leftWidth - rightWidth) +
              right;
          } else {
            const room = width - leftWidth - 2;

            if (room > 0) {
              const truncatedRight = truncateToWidth(
                right,
                room,
                ""
              );

              statsLine =
                left +
                " ".repeat(
                  Math.max(
                    2,
                    width -
                      leftWidth -
                      visibleWidth(truncatedRight)
                  )
                ) +
                truncatedRight;
            } else {
              statsLine = left;
            }
          }

          const lines = [
            cwdLine,
            theme.fg("dim", statsLine),
          ];

          // Preserve statuses added by other extensions.
          const statuses = Array.from(
            footerData.getExtensionStatuses().entries()
          )
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([, text]) =>
              String(text)
                .replace(/[\r\n\t]/g, " ")
                .replace(/ +/g, " ")
                .trim()
            );

          if (statuses.length) {
            lines.push(
              truncateToWidth(
                statuses.join(" "),
                width,
                theme.fg("dim", "...")
              )
            );
          }

          return lines;
        },
      };
    });
  });
}
