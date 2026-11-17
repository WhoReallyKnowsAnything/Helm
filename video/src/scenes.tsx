import React from "react";
import { C, Cursor, MONO, Pill, Reveal, clamp01, lerp, ramp, sp } from "./ui";

/** Every scene gets `f` (frames since its screen group started) and `cue(name)` (the frame the named narration sentence starts at). */
export type SceneProps = { f: number; cue: (name: string) => number };

const text = (size = 14, color: string = C.g100): React.CSSProperties => ({ fontFamily: MONO, fontSize: size, lineHeight: "22px", color });

// ---------------------------------------------------------------- sidebar

const ROWS = [
  { title: "acme-weather-app", id: "orch-1", selected: true },
  { title: "acme-store-api", id: "orch-2", dot: true },
  { title: "acme-docs-site", id: "orch-3" },
];

export const Sidebar: React.FC<{ f: number; start: number }> = ({ f, start }) => (
  <div style={{ width: 240, height: "100%", background: C.g900, borderRight: `1px solid ${C.g800}`, position: "relative", flexShrink: 0 }}>
    <div style={{ display: "flex", gap: 8, padding: "10px 12px", borderBottom: `1px solid ${C.g800}` }}>
      <Pill>+New</Pill><Pill>Select</Pill><Pill>Root</Pill>
    </div>
    {ROWS.map((r, i) => {
      const t = sp(f, start + i * 14, 18, 130);
      return (
        <div key={r.id} style={{ position: "relative", margin: "8px 10px 0", padding: "8px 14px", borderRadius: 6, background: r.selected ? C.g825 : "transparent",
          opacity: clamp01(t * 1.5), transform: `translateX(${(1 - t) * -36}px)` }}>
          {r.selected && <div style={{ position: "absolute", left: 0, top: 6, bottom: 6, width: 3, borderRadius: 2, background: C.lime }} />}
          <div style={{ ...text(14), fontWeight: 700 }}>{r.title}</div>
          <div style={{ ...text(12, C.g500) }}>{r.id}</div>
          {r.dot && <div style={{ position: "absolute", right: 14, top: 22, width: 9, height: 9, borderRadius: 9, background: C.cyan }} />}
        </div>
      );
    })}
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, padding: "12px 12px 14px", borderTop: `1px solid ${C.g800}`, ...text(12, C.g300), lineHeight: "20px" }}>
      <div>5h&nbsp;&nbsp;22% used&nbsp;&nbsp;resets 10:52 pm</div>
      <div>7d&nbsp;&nbsp;41% used&nbsp;&nbsp;resets Thu</div>
    </div>
  </div>
);

// ---------------------------------------------------------------- worker tree

type NodeDef = { id: string; x: number; y: number; title: string; task: string; info: string[]; branch: string };
const W = 230, H = 140;
const NODES: NodeDef[] = [
  { id: "orch", x: 405, y: 24, title: "acme-weather-app", task: "Opus 4.7 · high", info: ["34% context"], branch: "main" },
  { id: "forecast-chart", x: 90, y: 230, title: "forecast-chart", task: "Draw the hourly chart", info: ["18% context", "Sonnet 5.5 · medium"], branch: "session/forecast-chart" },
  { id: "offline-cache", x: 405, y: 230, title: "offline-cache", task: "Cache the last forecast", info: [], branch: "session/offline-cache" },
  { id: "alerts-api", x: 720, y: 230, title: "alerts-api", task: "Add the alerts client", info: [], branch: "session/alerts-api" },
  { id: "ui-polish", x: 405, y: 494, title: "ui-polish", task: "Tidy the settings screen", info: [], branch: "session/ui-polish" },
];
type Status = "running" | "waiting" | "done" | "stalled" | "none";
const STATUS_TEXT: Record<Status, string> = { running: "running", waiting: "waiting on you", done: "finished", stalled: "stalled", none: "" };
const STATUS_COLOR: Record<Status, string> = { running: C.blue, waiting: C.cyan, done: C.g500, stalled: C.stalled, none: C.g500 };

const TreeNode: React.FC<{ n: NodeDef; status: Status; appear: number; f: number; branchAt: number; glow?: number }> = ({ n, status, appear, f, branchAt, glow = 0 }) => {
  const t = sp(f, appear, 16, 150);
  const fill = status === "running" ? C.blueFill : status === "waiting" ? C.cyanFill : C.g850;
  const border = status === "running" ? C.blue : status === "waiting" ? C.cyan : C.g750;
  const bt = sp(f, branchAt, 20, 150);
  return (
    <div style={{ position: "absolute", left: n.x, top: n.y, width: W, height: H, borderRadius: 4, background: fill, border: `1px solid ${border}`,
      opacity: clamp01(t * 1.6), transform: `scale(${lerp(0.86, 1, t)})`, boxShadow: glow > 0 ? `0 0 ${24 * glow}px ${C.cyan}55` : "none",
      padding: "0 11px", display: "flex", flexDirection: "column", justifyContent: "center" }}>
      <div style={{ ...text(15), fontWeight: 700, textAlign: "center" }}>{n.title}</div>
      <div style={text(13, C.g500)}>{n.task}</div>
      {status !== "none" && <div style={text(13, STATUS_COLOR[status])}>{STATUS_TEXT[status]}</div>}
      {n.info.map((l) => <div key={l} style={text(13, C.g500)}>{l}</div>)}
      <div style={{ ...text(12, C.lime), opacity: clamp01(bt * 1.5), transform: `translateY(${(1 - bt) * 8}px)`, height: 20, overflow: "hidden", whiteSpace: "nowrap" }}>
        {branchAt < 99999 ? `⎇ ${n.branch}` : ""}
      </div>
    </div>
  );
};

const EDGES: [string, string][] = [["orch", "forecast-chart"], ["orch", "offline-cache"], ["orch", "alerts-api"], ["offline-cache", "ui-polish"]];

export const HoldCard: React.FC<{ x: number; y: number; command: string; f: number; at: number; pressed: number; resolved: number }> = ({ x, y, command, f, at, pressed, resolved }) => {
  const t = sp(f, at, 17, 140);
  const out = 1 - resolved;
  return (
    <div style={{ position: "absolute", left: x, top: y, width: W, borderRadius: 4, border: `1px solid ${resolved > 0.5 ? C.green : C.cyan}`, background: C.g900,
      padding: "10px 10px 10px", opacity: clamp01(t * 1.6) * (resolved > 0 ? lerp(1, 0.0, clamp01((resolved - 0.55) * 2.2)) : 1),
      transform: `translateY(${(1 - t) * -26}px) scale(${lerp(0.94, 1, t)})`, zIndex: 5 }}>
      <div style={{ ...text(13), lineHeight: "18px", height: 36, overflow: "hidden" }}>{command}</div>
      <div style={{ display: "flex", gap: 8, marginTop: 10, height: 26 }}>
        <Pill fill={pressed > 0 ? C.lime : C.g825} color={pressed > 0 ? "#0E0E0F" : C.g100} style={{ transform: `scale(${1 - pressed * 0.08})`, padding: "4px 12px" }}>
          {resolved > 0.4 ? "Approved" : "Approve"}
        </Pill>
        <Pill style={{ padding: "4px 12px", opacity: out }}>Deny</Pill>
      </div>
    </div>
  );
};

/** mode "sessions": nodes appear and change status. "holds": offline-cache waits, a card appears, the cursor approves it. */
export const TreeScreen: React.FC<SceneProps & { holds?: boolean }> = ({ f, cue, holds }) => {
  const t0 = holds ? 0 : cue("tree");
  const tn = f - t0;
  const appear = (i: number) => (holds ? -100 : t0 + i * 8);
  const branchAt = !holds && cue("worktrees") < 99999 ? cue("worktrees") : holds ? 0 : 99999;
  // statuses
  let off: Status = "running", alerts: Status = "running";
  if (holds) { off = "waiting"; alerts = "done"; }
  else { if (tn > 80) off = "waiting"; if (tn > 118) alerts = "done"; }
  const cardAt = holds ? cue("card") + 6 : 99999;
  const clickAt = holds ? cue("click") + 34 : 99999; // cursor lands, then presses
  const press = holds ? ramp(f, clickAt, clickAt + 7) * (1 - ramp(f, clickAt + 9, clickAt + 16)) : 0;
  const resolved = holds ? ramp(f, clickAt + 6, clickAt + 26) : 0;
  if (holds && resolved > 0.55) off = "running";
  const commit = 'Bash: git commit -m "add cache"';
  // cursor path: enters from the lower right, lands on Approve
  const cx = lerp(760, 452, sp(f, cue("click") + 4, 22, 70));
  const cy = lerp(600, 449, sp(f, cue("click") + 4, 22, 70));
  const cursorOpacity = holds ? clamp01(ramp(f, cue("click"), cue("click") + 6)) * (1 - ramp(f, clickAt + 26, clickAt + 36)) : 0;
  const nodeStatus: Record<string, Status> = { orch: "none", "forecast-chart": "running", "offline-cache": off, "alerts-api": alerts, "ui-polish": "stalled" };
  if (holds) nodeStatus["forecast-chart"] = "waiting";
  const dep = holds ? 0 : ramp(f, t0 + 60, t0 + 80);
  return (
    <div style={{ position: "absolute", inset: 0, backgroundImage: `radial-gradient(${C.g800} 1px, transparent 1.2px)`, backgroundSize: "22px 22px" }}>
      <svg width="1040" height="690" style={{ position: "absolute", inset: 0 }}>
        {EDGES.map(([a, b], i) => {
          const A = NODES.find((n) => n.id === a)!, B = NODES.find((n) => n.id === b)!;
          const x1 = A.x + W / 2, y1 = A.y + H, x2 = B.x + W / 2, y2 = B.y;
          const len = Math.hypot(x2 - x1, y2 - y1);
          const p = ramp(f, appear(i + 1) + 2, appear(i + 1) + 20);
          return <line key={i} x1={x1} y1={y1} x2={x2} y2={y2} stroke={C.g700} strokeWidth="1.4" strokeDasharray={len} strokeDashoffset={len * (1 - p)} />;
        })}
        <path d={`M ${90 + W / 2} ${230 + H} Q ${(90 + 405 + W) / 2} ${230 + H + 38} ${405 + W / 2} ${230 + H}`} fill="none" stroke={C.blue} strokeWidth="1.4"
          strokeDasharray="5 5" opacity={dep} />
      </svg>
      {NODES.map((n, i) => (
        <TreeNode key={n.id} n={n} status={nodeStatus[n.id]} appear={appear(i)} f={f} branchAt={n.id === "orch" ? 99999 : branchAt}
          glow={holds && n.id === "offline-cache" && f < clickAt + 6 ? 0.5 + 0.5 * Math.sin(f / 5) : 0} />
      ))}
      {holds && (
        <>
          <HoldCard x={405} y={H + 230 + 2} command={commit} f={f} at={cardAt} pressed={press} resolved={resolved} />
          <HoldCard x={90} y={H + 230 + 2} command="Edit: Sources/Forecast.swift" f={f} at={cardAt + 10} pressed={0} resolved={0} />
          <Cursor x={cx} y={cy} press={press} opacity={cursorOpacity} />
        </>
      )}
    </div>
  );
};

// ---------------------------------------------------------------- chat

const Typed: React.FC<{ s: string; f: number; start: number; cps: number; caret?: boolean }> = ({ s, f, start, cps, caret = true }) => {
  const n = Math.max(0, Math.min(s.length, Math.floor((f - start) * cps)));
  const typing = f >= start && n < s.length;
  return <>{s.slice(0, n)}{caret && typing && <span style={{ color: C.lime }}>▌</span>}</>;
};

const CODE = ["Chart(store.points) { point in", "    LineMark(x: .value(\"Hour\", point.hour),", "             y: .value(\"Temp\", point.temperature))", "}"];

export const ChatScreen: React.FC<SceneProps> = ({ f, cue }) => {
  const u1 = "Add a 24 hour temperature chart to the forecast screen. Keep it working offline.";
  const a1 = "I will split this into two parts.\n• Data: fetch the hourly points and cache the last result.\n• Chart: draw the line chart from the cached points.";
  const u2 = "Good. Show the temperature when I tap a point.";
  const a2 = "Done. Tapping a point now shows its temperature above the line.";
  const t1 = 10, t2 = 44, t3 = cue("code") + 2, t4 = t3 + 20;
  const row = (label: string, color: string, body: React.ReactNode, user: boolean, shown: boolean) => (
    <div style={{ display: "flex", gap: 22, padding: "11px 16px", borderRadius: 4, background: user ? C.g825 : C.g900, border: user ? `1px solid ${C.g750}` : "1px solid transparent",
      marginBottom: 12, opacity: shown ? 1 : 0, ...text(15) , lineHeight: "24px" }}>
      <div style={{ width: 60, color, fontWeight: 700, flexShrink: 0 }}>{label}</div>
      <div style={{ whiteSpace: "pre-wrap", flex: 1 }}>{body}</div>
    </div>
  );
  return (
    <div style={{ position: "absolute", inset: 0, padding: "44px 56px" }}>
      {row("you", C.lime, <Typed s={u1} f={f} start={t1} cps={2.6} caret={f < t2} />, true, f >= t1)}
      {row("claude", C.g300, <Typed s={a1} f={f} start={t2} cps={3.3} caret={f < t3} />, false, f >= t2)}
      {row("you", C.lime, <Typed s={u2} f={f} start={t3} cps={2.6} caret={f < t4} />, true, f >= t3)}
      {row("claude", C.g300, (
        <div>
          <Typed s={a2} f={f} start={t4} cps={3.4} caret={f < t4 + 22} />
          <div style={{ marginTop: 10, padding: "10px 12px", background: C.g850, borderRadius: 4, ...text(14, C.g300), lineHeight: "21px" }}>
            {CODE.map((l, i) => (
              <Reveal key={i} f={f} delay={t4 + 24 + i * 6} dy={6} style={{ whiteSpace: "pre" }}>{l}</Reveal>
            ))}
          </div>
        </div>
      ), false, f >= t4)}
    </div>
  );
};

// ---------------------------------------------------------------- workflow shell

export type TabName = "board" | "context" | "plan" | "execute" | "verify" | "run" | "milestone";
const TABS: { id: TabName; label: string; left: number; w: number }[] = [
  { id: "board", label: "Board", left: 14, w: 68 }, { id: "context", label: "Context", left: 92, w: 84 }, { id: "plan", label: "Plan", left: 186, w: 60 },
  { id: "execute", label: "Execute", left: 256, w: 84 }, { id: "verify", label: "Verify", left: 350, w: 72 },
  { id: "run", label: "Run Record", left: 1040 - 14 - 96 - 12 - 120, w: 120 }, { id: "milestone", label: "Milestone", left: 1040 - 14 - 96, w: 96 },
];
const TAB_ORDER: TabName[] = ["board", "context", "plan", "execute", "verify", "run", "milestone"];

const Line: React.FC<{ f: number; at: number; children: React.ReactNode; bold?: boolean; color?: string; style?: React.CSSProperties }> = ({ f, at, children, bold, color, style }) => (
  <Reveal f={f} delay={at} dy={8} style={{ ...text(14, color ?? C.g100), fontWeight: bold ? 700 : 400, ...style }}>{children}</Reveal>
);

const PLAN_LINES: { kind: "wave" | "title" | "text" | "link" | "dim"; text: string; wave?: number }[] = [
  { kind: "wave", text: "Wave 1" },
  { kind: "title", text: "Phase 3 - Plan 1: Fetch the hourly data" }, { kind: "link", text: "Sources/Forecast.swift" }, { kind: "dim", text: "Verify: `swift test`" },
  { kind: "title", text: "Phase 3 - Plan 2: Cache the last forecast" }, { kind: "link", text: "Sources/Cache.swift" }, { kind: "dim", text: "Verify: `swift test`" },
  { kind: "wave", text: "Wave 2" },
  { kind: "title", text: "Phase 3 - Plan 3: Draw the chart" }, { kind: "link", text: "Sources/ChartView.swift" }, { kind: "dim", text: "Verify: `swift test`" },
  { kind: "wave", text: "Wave 3" },
  { kind: "title", text: "Phase 3 - Plan 4: Add the tap label" }, { kind: "link", text: "Sources/TapLabel.swift" }, { kind: "dim", text: "Verify: `swift test`" },
];
/** y of each plan line, so the cursor can aim at the first file link. */
export const planLayout = () => {
  let y = 16;
  return PLAN_LINES.map((l) => { const top = y + (l.kind === "wave" ? 10 : 0); y = top + (l.kind === "wave" ? 28 : 23); return { ...l, top }; });
};
export const PLAN_LINK_Y = planLayout().find((l) => l.kind === "link")!.top + 11;

const Body: React.FC<{ tab: TabName; f: number; fastPlan?: boolean }> = ({ tab, f, fastPlan }) => {
  const pad: React.CSSProperties = { position: "absolute", inset: 0, padding: "16px 18px" };
  if (tab === "board") {
    const rows = [["1", "Project setup", "done"], ["2", "Current conditions screen", "done"], ["3", "Hourly forecast chart", "executing"], ["4", "Severe weather alerts", "context"]];
    return (
      <div style={pad}>
        <Reveal f={f} delay={0} style={{ display: "flex", gap: 8, alignItems: "center", marginBottom: 16 }}>
          <Pill fill={C.lime} color="#0E0E0F" border={C.lime} dim>Next: Verify</Pill><Pill>Hide</Pill><Pill>Run Record</Pill>
          <span style={{ flex: 1 }} /><Pill>Suggested ▾</Pill>
        </Reveal>
        <Line f={f} at={6}>v2 Forecast and alerts</Line>
        {rows.map((r, i) => (
          <Line key={r[0]} f={f} at={12 + i * 7} style={{ paddingLeft: 18 }}>
            <span style={{ color: r[0] === "3" ? C.lime : C.g500, marginLeft: -18, display: "inline-block", width: 18 }}>{r[0] === "3" ? ">" : ""}</span>
            {r[0]}&nbsp;&nbsp;{r[1]}&nbsp;&nbsp;<span style={{ color: r[2] === "done" ? C.green : r[2] === "executing" ? C.blue : C.g500 }}>{r[2]}</span>
          </Line>
        ))}
      </div>
    );
  }
  if (tab === "context") {
    return (
      <div style={pad}>
        <Line f={f} at={0} bold>Phase 3 (this phase)</Line>
        {[["D-01 (chart)", "Draw the next 24 hours as a line chart."], ["D-02 (data)", "Cache the last forecast so the chart works offline."], ["D-03 (style)", "Use the system font and the app accent colour."]].map((d, i) => (
          <div key={d[0]} style={{ marginTop: 8 }}>
            <Line f={f} at={6 + i * 9} color={C.g500}>Phase 3 {d[0]}</Line>
            <Line f={f} at={9 + i * 9} bold>{d[1]}</Line>
          </div>
        ))}
        <Line f={f} at={38} bold style={{ marginTop: 22 }}>Acceptance criteria</Line>
        {["AC1: The chart shows 24 hourly points.", "AC2: A tap on a point shows its temperature.", "AC3: Airplane mode still shows the cached chart."].map((a, i) => (
          <Line key={a} f={f} at={44 + i * 8}><span style={{ color: C.g500 }}>- [ ] </span>{a}</Line>
        ))}
      </div>
    );
  }
  if (tab === "plan") {
    const lay = planLayout();
    return (
      <div style={pad}>
        {lay.map((l, i) => (
          <Reveal key={i} f={f} delay={fastPlan ? i : 4 + i * 3} dy={6} style={{ position: "absolute", left: 18, top: l.top, ...text(14, l.kind === "link" ? C.blue : l.kind === "dim" ? C.g500 : C.g100),
            fontWeight: l.kind === "wave" || l.kind === "title" ? 700 : 400 }}>{l.text}</Reveal>
        ))}
      </div>
    );
  }
  if (tab === "execute") {
    const plans = [
      { w: 1, k: 1, t: "Fetch the hourly data", run: 6, done: 30, hash: "d5d51e2" }, { w: 1, k: 2, t: "Cache the last forecast", run: 8, done: 38, hash: "e4935fc" },
      { w: 2, k: 3, t: "Draw the chart", run: 44, done: 78, hash: "3fa91b0" }, { w: 3, k: 4, t: "Add the tap label", run: 82, done: 112, hash: "9c1d7e4" },
    ];
    const allDone = f >= 112;
    let y = 0;
    return (
      <div style={pad}>
        <Reveal f={f} delay={0} style={{ display: "flex", gap: 10, alignItems: "center", marginBottom: 18 }}>
          <Pill fill={allDone ? C.lime : C.g825} color={allDone ? "#0E0E0F" : C.g100} border={allDone ? C.lime : C.g750} dim={!allDone}>Next: Verify</Pill>
          <span style={text(14, C.g500)}>{allDone ? "all plans complete" : "a plan is still running"}</span>
        </Reveal>
        {[1, 2, 3].map((w) => (
          <div key={w} style={{ marginBottom: 14 }}>
            <Line f={f} at={2 + w * 2} bold>Wave {w}</Line>
            {plans.filter((p) => p.w === w).map((p) => {
              const state = f >= p.done ? "done" : f >= p.run ? "running" : "waiting";
              const prog = state === "done" ? 1 : state === "running" ? ramp(f, p.run, p.done) : 0;
              y += 1;
              return (
                <Line key={p.k} f={f} at={4 + p.k * 3}>
                  <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "4px 0" }}>
                    <span style={{ width: 300, fontWeight: 700 }}>{p.k}. {p.t}</span>
                    <span style={{ width: 86, color: state === "done" ? C.green : state === "running" ? C.blue : C.g500 }}>[{state}]</span>
                    <span style={{ width: 280, height: 8, borderRadius: 4, background: C.g800, overflow: "hidden", display: "inline-block" }}>
                      <span style={{ display: "block", height: "100%", width: `${prog * 100}%`, background: state === "done" ? C.green : C.blue }} />
                    </span>
                    <span style={{ color: C.g500, opacity: state === "done" ? 1 : 0 }}>{p.hash}</span>
                  </div>
                </Line>
              );
            })}
          </div>
        ))}
      </div>
    );
  }
  if (tab === "verify") {
    const items = [["The chart shows the next 24 hours", "Open the forecast screen and see 24 hourly points"], ["Tapping a point shows its temperature", "Tap the 3 pm point and see the temperature label"],
      ["The chart works without a network", "Turn on airplane mode and open the forecast screen"], ["Dark mode keeps the labels readable", "Switch to dark mode and check the axis labels"]];
    const ticks = [14, 34, 54, 74];
    const passed = ticks.filter((t) => f >= t).length;
    return (
      <div style={pad}>
        <Reveal f={f} delay={0} style={{ display: "flex", gap: 8, marginBottom: 16 }}>
          <Pill fill={C.lime} color="#0E0E0F" border={C.lime}>Pass</Pill><Pill>Fail</Pill><Pill>Skip</Pill><Pill>Blocked</Pill>
        </Reveal>
        <Line f={f} at={3} color={C.g300}>pass {passed}, fail 0, pending {4 - passed}, skipped 0, blocked 0 {passed === 4 ? "- complete" : "- partial"}</Line>
        {items.map((it, i) => {
          const ok = f >= ticks[i];
          return (
            <Line key={i} f={f} at={6 + i * 4} style={{ marginTop: 12 }}>
              <span style={{ fontWeight: 700 }}>{i + 1}. {it[0]}</span>{" "}
              <span style={{ color: ok ? C.green : C.g500 }}>[{ok ? "pass ✓" : "pending"}]</span>
              <div style={{ color: C.g300 }}>{it[1]}</div>
            </Line>
          );
        })}
      </div>
    );
  }
  if (tab === "run") {
    const ev = [["09:12:04", "dispatch", "cad-context-p3", "sonnet · xhigh"], ["09:18:41", "done", "cad-context-p3", "3 decisions, 3 criteria"], ["09:19:10", "dispatch", "cad-plan-p3", "sonnet · xhigh"],
      ["09:27:33", "done", "cad-plan-p3", "4 plans in 3 waves"], ["09:28:02", "dispatch", "cad-execute-p3", "wave 1 · 2 plans"], ["09:41:50", "done", "cad-execute-p3", "PLAN COMPLETE × 4"],
      ["09:43:15", "dispatch", "cad-verify-p3", "UAT · 4 items"], ["09:52:08", "done", "cad-verify-p3", "4 pass · 0 fail"]];
    return (
      <div style={pad}>
        <Line f={f} at={0} bold>Run record</Line>
        <Reveal f={f} delay={3} style={{ display: "flex", gap: 10, margin: "12px 0" }}><Pill fill={C.lime} color="#0E0E0F" border={C.lime}>Refresh</Pill><Pill>Whole record ⌃</Pill></Reveal>
        <Line f={f} at={6} color={C.g500}>file: .planning/records/trace.jsonl  |  scope: all  |  capped: false</Line>
        <Line f={f} at={8} bold style={{ margin: "14px 0 6px" }}>Events</Line>
        {ev.map((e, i) => (
          <Line key={i} f={f} at={10 + i * 6}>
            <span style={{ color: C.g500 }}>{e[0]}</span>&nbsp;&nbsp;<span style={{ display: "inline-block", width: 86, color: e[1] === "done" ? C.green : C.blue }}>{e[1]}</span>
            <span style={{ display: "inline-block", width: 170 }}>{e[2]}</span><span style={{ color: C.g300 }}>{e[3]}</span>
          </Line>
        ))}
      </div>
    );
  }
  // milestone
  const land = ["Worker copy: session/cad-milestone-p4", "Cycle: closed in the worker copy", "Local tag: v2 created", "Origin tag: v2 pushed", "Pull request: #14 merged"];
  const closeGlow = ramp(f, 80, 92);
  return (
    <div style={pad}>
      <Line f={f} at={0}>v2&nbsp;&nbsp;cad-milestone-p4</Line>
      <Reveal f={f} delay={4} style={{ display: "flex", gap: 10, margin: "14px 0 18px" }}>
        <Pill fill={C.lime} color="#0E0E0F" border={C.lime} style={{ boxShadow: `0 0 ${22 * closeGlow}px ${C.lime}88` }}>Close</Pill><Pill>Refresh</Pill>
      </Reveal>
      <Line f={f} at={10} bold color={C.green} style={{ fontSize: 22, lineHeight: "30px" }}>PASS</Line>
      <Line f={f} at={16} bold style={{ margin: "16px 0 6px" }}>Land</Line>
      {land.map((l, i) => (
        <Line key={i} f={f} at={22 + i * 11}><span style={{ color: C.green }}>✓</span>&nbsp;&nbsp;{l}</Line>
      ))}
    </div>
  );
};

const KEYWORDS = new Set(["import", "struct", "let", "var", "private", "mutating", "func"]);
const CODE_LINES = ["import Foundation", "", "/// One hour of the forecast.", "struct HourlyPoint: Identifiable {", "    let id: Int", "    let hour: Date", "    let temperature: Double",
  "}", "", "struct ForecastStore {", "    private(set) var points: [HourlyPoint] = []", "", "    /// Keeps the next 24 hours, so the chart stays small.",
  "    mutating func update(_ new: [HourlyPoint]) {", "        points = Array(new.prefix(24))", "    }", "}"];

const CodeLine: React.FC<{ s: string }> = ({ s }) => {
  if (s.trim().startsWith("///")) return <span style={{ color: C.g500 }}>{s}</span>;
  return <>{s.split(/(\s+|[(){}\[\]:,.])/).map((w, i) => <span key={i} style={{ color: KEYWORDS.has(w) ? C.purple : /^\d+$/.test(w) ? C.yellow : C.g100 }}>{w}</span>)}</>;
};

const Editor: React.FC<{ f: number; at: number }> = ({ f, at }) => {
  const t = sp(f, at, 20, 110);
  const hl = ramp(f, at + 18, at + 30);
  return (
    <div style={{ position: "absolute", inset: 0, background: C.bg, transform: `translateY(${(1 - t) * 60}px)`, opacity: clamp01(t * 1.8), borderTop: `1px solid ${C.g800}` }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "10px 18px", borderBottom: `1px solid ${C.g800}` }}>
        <span style={{ ...text(14), flex: 1 }}>Sources/Forecast.swift</span>
        <span style={text(13, C.g500)}>go to line</span><Pill>Show diff</Pill><Pill dim>Save</Pill><Pill>Open in VS Code</Pill>
      </div>
      <div style={{ padding: "12px 0", position: "relative" }}>
        {CODE_LINES.map((l, i) => (
          <div key={i} style={{ display: "flex", height: 25, alignItems: "center", background: i === 12 ? `rgba(197,228,120,${0.16 * hl})` : "transparent",
            opacity: clamp01(sp(f, at + 6 + i * 1.4, 22, 150) * 1.6), whiteSpace: "pre", ...text(15) }}>
            <span style={{ width: 52, textAlign: "right", paddingRight: 16, color: C.g700 }}>{i + 1}</span><CodeLine s={l} />
          </div>
        ))}
      </div>
    </div>
  );
};

export const ShellScreen: React.FC<SceneProps & { tabStarts: { tab: TabName; at: number }[]; editorAt: number }> = ({ f, tabStarts, editorAt }) => {
  // the active tab is the last whose start has passed; `prev` fades out while the new one fades in
  let idx = 0;
  tabStarts.forEach((s, i) => { if (f >= s.at) idx = i; });
  const cur = tabStarts[idx], prev = idx > 0 ? tabStarts[idx - 1] : null;
  const p = prev ? sp(f, cur.at, 20, 130) : 1;
  const fastPlan = cur.tab === "plan" && cur.at >= editorAt - 1;
  const ti = (name: TabName) => TABS.find((t) => t.id === name)!;
  const left = lerp((prev ? ti(prev.tab) : ti(cur.tab)).left, ti(cur.tab).left, p);
  const width = lerp((prev ? ti(prev.tab) : ti(cur.tab)).w, ti(cur.tab).w, p);
  const phaseLabel = ["Board", "Context", "Plan", "Execute", "Verify", "Run Record", "Milestone"][TAB_ORDER.indexOf(cur.tab)];
  // cursor clicks the first file link of the plan, which opens the editor
  const clickF = editorAt + 22;
  const press = ramp(f, clickF, clickF + 6) * (1 - ramp(f, clickF + 8, clickF + 15));
  const cp = sp(f, editorAt + 2, 22, 70);
  const cx = lerp(820, 18 + 70, cp), cy = lerp(560, 78 + PLAN_LINK_Y, cp);
  const showCursor = f >= editorAt && editorAt < 99999;
  return (
    <div style={{ position: "absolute", inset: 0 }}>
      <div style={{ display: "flex", alignItems: "center", height: 40, padding: "0 14px", borderBottom: `1px solid ${C.g800}`, ...text(13, C.g500) }}>
        <Pill style={{ color: C.g500 }}>Phase 3&nbsp;&nbsp;Hourly forecast chart ▾</Pill><span style={{ flex: 1 }} /><span>Phase 3&nbsp;&nbsp;Hourly forecast chart&nbsp;&nbsp;/&nbsp;&nbsp;{phaseLabel}</span>
      </div>
      <div style={{ position: "relative", height: 38, borderBottom: `1px solid ${C.g800}` }}>
        {TABS.map((t) => (
          <div key={t.id} style={{ position: "absolute", left: t.left, width: t.w, top: 0, height: 36, display: "flex", alignItems: "center", justifyContent: "center",
            ...text(14, t.id === cur.tab ? C.g100 : C.g300), fontWeight: t.id === cur.tab ? 700 : 400 }}>{t.label}</div>
        ))}
        <div style={{ position: "absolute", left, width, bottom: 0, height: 2, background: C.lime, borderRadius: 1 }} />
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, top: 78, bottom: 0, overflow: "hidden" }}>
        {prev && p < 1 && <div style={{ position: "absolute", inset: 0, opacity: 1 - p }}><Body tab={prev.tab} f={9999} /></div>}
        <div style={{ position: "absolute", inset: 0, opacity: prev ? clamp01(p * 1.4) : 1, transform: prev ? `translateY(${(1 - p) * 10}px)` : "none" }}>
          <Body tab={cur.tab} f={f - cur.at} fastPlan={fastPlan} />
        </div>
        {editorAt < 99999 && f >= clickF + 6 && <Editor f={f} at={clickF + 6} />}
        {showCursor && <Cursor x={cx} y={cy - 78} press={press} opacity={clamp01(ramp(f, editorAt, editorAt + 5)) * (1 - ramp(f, clickF + 20, clickF + 30))} />}
      </div>
    </div>
  );
};
