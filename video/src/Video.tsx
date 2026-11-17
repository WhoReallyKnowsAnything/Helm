import React from "react";
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import brand from "../brand.json";
import timing from "../gen/timing.json";
import { ChatScreen, ShellScreen, Sidebar, TabName, TreeScreen } from "./scenes";
import { C, MONO, SANS, clamp01, lerp, ramp, sp } from "./ui";

type Sentence = { text: string; cue: string; start: number; dur: number };
type Beat = { id: string; headline: string; start: number; dur: number; sentences: Sentence[] };
const BEATS = timing.beats as Beat[];

export const videoFrames = (fps: number) => Math.ceil(timing.total * fps) + Math.round(0.8 * fps);

// ------------------------------------------------------------ screens: which app screen shows during which beats
type Screen = "tree" | "chat" | "holds" | "shell" | "none";
const SCREEN_OF: Record<string, Screen> = {
  intro: "none", sessions: "tree", worktrees: "tree", chat: "chat", holds: "holds", flow1: "shell", flow2: "shell", flow3: "shell", editor: "shell", outro: "none",
};

type Group = { screen: Screen; start: number; end: number; beats: Beat[] };
const groupsOf = (fps: number): Group[] => {
  const out: Group[] = [];
  for (const b of BEATS) {
    const s = SCREEN_OF[b.id];
    const start = Math.round(b.start * fps), end = Math.round((b.start + b.dur) * fps);
    const last = out[out.length - 1];
    if (last && last.screen === s) { last.end = end; last.beats.push(b); } else out.push({ screen: s, start, end, beats: [b] });
  }
  return out;
};

/** Camera: where the floating window sits for each beat (rotation in degrees, scale, shift in px). */
const CAMERA: Record<string, { rx: number; ry: number; s: number; x: number; y: number }> = {
  intro: { rx: 8, ry: -14, s: 0.9, x: 0, y: 60 },
  sessions: { rx: 4, ry: -7, s: 1.0, x: 0, y: 0 },
  worktrees: { rx: 3, ry: 5, s: 1.07, x: -30, y: 6 },
  chat: { rx: 2, ry: -4, s: 1.05, x: -50, y: 0 },
  holds: { rx: 3, ry: 4, s: 1.09, x: -60, y: 8 },
  flow1: { rx: 3, ry: -4, s: 1.05, x: -50, y: 2 },
  flow2: { rx: 2, ry: 3, s: 1.06, x: -50, y: 2 },
  flow3: { rx: 3, ry: -3, s: 1.05, x: -50, y: 2 },
  editor: { rx: 2, ry: 3, s: 1.07, x: -50, y: 4 },
  outro: { rx: 10, ry: 16, s: 0.82, x: 0, y: 40 },
};

const Background: React.FC<{ drift: number }> = ({ drift }) => (
  <AbsoluteFill style={{ background: "#08090A" }}>
    <div style={{ position: "absolute", left: -300 + drift * 40, top: -380, width: 1300, height: 1300, borderRadius: 1300,
      background: `radial-gradient(circle, ${C.lime}26 0%, transparent 62%)` }} />
    <div style={{ position: "absolute", right: -420 - drift * 50, bottom: -520, width: 1500, height: 1500, borderRadius: 1500,
      background: `radial-gradient(circle, ${C.blue}22 0%, transparent 62%)` }} />
    <div style={{ position: "absolute", left: 700 - drift * 30, top: 500, width: 900, height: 900, borderRadius: 900,
      background: `radial-gradient(circle, ${C.cyan}14 0%, transparent 60%)` }} />
    <AbsoluteFill style={{ backgroundImage: `radial-gradient(#ffffff14 1px, transparent 1.3px)`, backgroundSize: "44px 44px", opacity: 0.5 }} />
    <AbsoluteFill style={{ background: "radial-gradient(ellipse at center, transparent 55%, #000000aa 100%)" }} />
  </AbsoluteFill>
);

const Headline: React.FC<{ text: string; f: number; dur: number }> = ({ text, f, dur }) => {
  const words = text.split(" ");
  const exit = ramp(f, dur - 9, dur - 1);
  // the last sentence of the line gets the accent colour
  const sentences = text.split(/(?<=\.)\s+/);
  const lastStart = text.length - sentences[sentences.length - 1].length;
  let pos = 0;
  return (
    <div style={{ position: "absolute", left: 140, right: 140, top: 62, height: 110, display: "flex", alignItems: "center", flexWrap: "wrap", gap: "0 22px",
      opacity: 1 - exit, transform: `translateY(${-exit * 24}px)` }}>
      {words.map((w, i) => {
        const at = pos; pos += w.length + 1;
        const t = sp(f, 2 + i * 3, 15, 150);
        return (
          <span key={i} style={{ fontFamily: SANS, fontWeight: 800, fontSize: 78, letterSpacing: -2, lineHeight: "92px", color: at >= lastStart && sentences.length > 1 ? C.lime : "#F4F4F5",
            opacity: clamp01(t * 1.5), transform: `translateY(${(1 - t) * 46}px)`, filter: `blur(${(1 - clamp01(t)) * 12}px)`, display: "inline-block" }}>{w}</span>
        );
      })}
    </div>
  );
};

/**
 * One caption bar for a whole narrated span. The bar is solid (no blur or see-through fill, so moving layers behind it cannot flicker),
 * fades in once at the start of the span and out once at its end. Only the text changes, with a short cross-fade;
 * between two sentences the previous text stays until the next one arrives, so the bar never shows a gap.
 * Sentences are Caption-shaped pages (text, startMs, endMs) as in the remotion-captions skill.
 */
type Page = { text: string; startMs: number; endMs: number };
const SPAN_GAP_MS = 1700; // pauses shorter than this (between beats) stay inside one span
const CaptionBar: React.FC<{ pages: Page[]; fps: number; f: number }> = ({ pages, fps, f }) => {
  if (pages.length === 0) return null;
  const fr = (ms: number) => Math.round((ms / 1000) * fps);
  // the span that holds this frame (or is about to start / has just ended)
  const spans: Page[][] = [];
  for (const p of pages) {
    const last = spans[spans.length - 1];
    if (last && p.startMs - last[last.length - 1].endMs < SPAN_GAP_MS) last.push(p); else spans.push([p]);
  }
  const span = spans.find((s) => f >= fr(s[0].startMs) - 14 && f <= fr(s[s.length - 1].endMs) + 20);
  if (!span) return null;
  const start = fr(span[0].startMs) - 3, end = fr(span[span.length - 1].endMs) + 8;
  const bar = ramp(f, start - 10, start) * (1 - ramp(f, end, end + 10));
  const X = 6; // text cross-fade frames
  return (
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 36, display: "flex", justifyContent: "center", opacity: bar }}>
      <div style={{ position: "relative", width: 1560, height: 80, borderRadius: 16, background: "rgb(14,15,17)", border: "1px solid rgb(52,54,58)", boxShadow: "0 12px 40px rgba(0,0,0,0.5)" }}>
        {span.map((p, i) => {
          const a = fr(p.startMs) - 3;
          const next = span[i + 1] ? fr(span[i + 1].startMs) - 3 : 1e9;
          const o = ramp(f, a, a + X) * (1 - ramp(f, next, next + X));
          return (
            <div key={i} style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center", opacity: o, fontFamily: SANS,
              fontWeight: 600, fontSize: 34, color: "#fff", textAlign: "center" }}>{p.text}</div>
          );
        })}
      </div>
    </div>
  );
};

const Logo: React.FC<{ f: number; size: number; word?: boolean; sub?: string; subAt?: number; credit?: string }> = ({ f, size, word = true, sub, subAt = 30, credit }) => {
  const t = sp(f, 0, 12, 90);
  const name = brand.name;
  const n = Math.floor(Math.max(0, f - 14) * (name.length / 14));
  const st = sp(f, subAt, 22, 120);
  return (
    <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 26 }}>
      <div style={{ position: "relative", width: size, height: size, opacity: clamp01(t * 1.5), transform: `scale(${lerp(0.5, 1, t)}) rotate(${(1 - t) * -12}deg)` }}>
        <div style={{ position: "absolute", inset: -size * 0.3, background: `radial-gradient(circle, ${C.lime}40 0%, transparent 65%)` }} />
        <Img src={staticFile("icon.svg")} style={{ position: "relative", width: size, height: size, filter: "drop-shadow(0 30px 50px rgba(0,0,0,.6))" }} />
      </div>
      {word && <div style={{ fontFamily: MONO, fontWeight: 800, fontSize: Math.min(150, Math.floor(1600 / (brand.name.length * 0.62))), color: C.lime, letterSpacing: -2, height: 170 }}>{name.slice(0, n)}{n < name.length && <span style={{ opacity: 0.8 }}>▌</span>}</div>}
      {sub && <div style={{ fontFamily: SANS, fontWeight: 500, fontSize: 40, color: "#E6E6E8", opacity: clamp01(st * 1.5), transform: `translateY(${(1 - st) * 20}px)` }}>{sub}</div>}
      {credit && <div style={{ position: "absolute", bottom: 44, fontFamily: SANS, fontSize: 22, color: "#9A9A9E", opacity: clamp01(st) }}>{credit}</div>}
    </div>
  );
};

export const Launch: React.FC<{ credit?: string }> = ({ credit }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const groups = groupsOf(fps);
  const beat = BEATS.find((b) => f >= Math.round(b.start * fps) && f < Math.round((b.start + b.dur) * fps)) ?? BEATS[BEATS.length - 1];
  const bi = BEATS.indexOf(beat);
  const bStart = Math.round(beat.start * fps), bDur = Math.round(beat.dur * fps);
  const cuesOf = (beats: Beat[], gStart: number) => (name: string) => {
    for (const b of beats) for (const s of b.sentences) if (s.cue === name) return Math.round(s.start * fps) - gStart;
    return 99999;
  };

  // camera: ease from the previous beat's pose to this one
  const from = CAMERA[BEATS[Math.max(0, bi - 1)].id], to = CAMERA[beat.id];
  const ct = sp(f - bStart, 0, 22, 55);
  const drift = Math.sin(f / 110);
  const cam = { rx: lerp(from.rx, to.rx, ct) + Math.sin(f / 70) * 0.5, ry: lerp(from.ry, to.ry, ct) + drift * 1.3, s: lerp(from.s, to.s, ct), x: lerp(from.x, to.x, ct), y: lerp(from.y, to.y, ct) };

  // window enters at the first beat that has a screen, leaves in the outro
  const first = BEATS.findIndex((b) => SCREEN_OF[b.id] !== "none");
  const enterAt = Math.round(BEATS[first].start * fps) - 4;
  const outroAt = Math.round(BEATS[BEATS.length - 1].start * fps);
  const enter = sp(f, enterAt, 20, 80), leave = ramp(f, outroAt, outroAt + 14);
  const winOpacity = clamp01(enter * 1.5) * (1 - leave);

  // headline groups: consecutive beats with the same headline share one animation
  let hl: { text: string; start: number; end: number } | null = null;
  for (const b of BEATS) {
    if (!b.headline) continue;
    const s = Math.round(b.start * fps), e = Math.round((b.start + b.dur) * fps);
    if (hl && hl.text === b.headline && s <= hl.end + 1) hl.end = e;
    if (f >= s && f < e) {
      let gs = s, ge = e;
      for (const o of BEATS) if (o.headline === b.headline) { gs = Math.min(gs, Math.round(o.start * fps)); ge = Math.max(ge, Math.round((o.start + o.dur) * fps)); }
      hl = { text: b.headline, start: gs, end: ge };
    }
  }
  const headline = hl && f >= hl.start && f < hl.end ? hl : null;

  // which screen group is on, with a short cross-fade
  const group = groups.find((g) => f >= g.start - 6 && f < g.end + 6 && g.screen !== "none");
  const gf = group ? f - group.start : 0;
  const gOpacity = group ? ramp(f, group.start - 6, group.start + 6) * (1 - ramp(f, group.end - 6, group.end + 6)) : 0;
  const cue = group ? cuesOf(group.beats, group.start) : () => 99999;

  let main: React.ReactNode = null;
  if (group) {
    if (group.screen === "tree") main = <TreeScreen f={gf} cue={cue} />;
    else if (group.screen === "holds") main = <TreeScreen f={gf} cue={cue} holds />;
    else if (group.screen === "chat") main = <ChatScreen f={gf} cue={cue} />;
    else {
      const all: { tab: TabName; at: number }[] = [
        { tab: "board", at: 0 }, { tab: "context", at: cue("context") }, { tab: "plan", at: cue("plan") }, { tab: "execute", at: cue("execute") },
        { tab: "verify", at: cue("verify") }, { tab: "run", at: cue("run") }, { tab: "milestone", at: cue("milestone") }, { tab: "plan", at: cue("editor") },
      ];
      const tabStarts = all.filter((s) => s.at < 99999);
      main = <ShellScreen f={gf} cue={cue} tabStarts={tabStarts} editorAt={cue("editor")} />;
    }
  }
  const sidebarStart = group && group.screen === "tree" && group.beats[0].id === "sessions" ? cue("sidebar") : -200;

  const introF = f - Math.round(BEATS[0].start * fps), introOut = ramp(f, enterAt - 4, enterAt + 8);
  const outroF = f - outroAt;
  const pages: Page[] = BEATS.filter((b) => b.id !== "intro" && b.id !== "outro").flatMap((b) => b.sentences)
    .map((s) => ({ text: s.text, startMs: s.start * 1000, endMs: (s.start + s.dur) * 1000 }));
  const WIN_W = 1280, WIN_H = 750, BASE = 1.02;

  return (
    <AbsoluteFill style={{ background: "#08090A", overflow: "hidden" }}>
      <Background drift={cam.ry / 10} />
      {bi === 0 && f < enterAt + 8 && <div style={{ position: "absolute", inset: 0, opacity: 1 - introOut }}><Logo f={introF} size={300} sub="A native macOS home for many Claude Code sessions" subAt={30} /></div>}
      <div style={{ position: "absolute", left: 960 - WIN_W / 2, top: 584 - WIN_H / 2, width: WIN_W, height: WIN_H, perspective: 2400, opacity: winOpacity }}>
        <div style={{ width: WIN_W, height: WIN_H, transform: `translate(${cam.x}px, ${cam.y + (1 - enter) * 120}px) scale(${BASE * cam.s * lerp(0.92, 1, enter)}) rotateX(${cam.rx}deg) rotateY(${cam.ry}deg)`,
          transformStyle: "preserve-3d", borderRadius: 16, overflow: "hidden", background: C.bg, border: `1px solid ${C.g750}`,
          boxShadow: `0 70px 140px rgba(0,0,0,0.7), 0 0 120px ${C.lime}1a, 0 0 0 1px #000` }}>
          <div style={{ height: 30, background: C.g900, borderBottom: `1px solid ${C.g800}`, display: "flex", alignItems: "center", padding: "0 14px", gap: 8, position: "relative" }}>
            {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => <div key={c} style={{ width: 12, height: 12, borderRadius: 12, background: c, opacity: 0.85 }} />)}
            <div style={{ position: "absolute", left: 0, right: 0, textAlign: "center", fontFamily: SANS, fontSize: 13, color: C.g500 }}>{brand.name}</div>
          </div>
          <div style={{ display: "flex", height: WIN_H - 30, background: C.bg }}>
            <Sidebar f={gf} start={sidebarStart} />
            <div style={{ position: "relative", width: 1040, height: WIN_H - 30, overflow: "hidden", opacity: gOpacity }}>{main}</div>
          </div>
        </div>
      </div>
      {headline && <Headline text={headline.text} f={f - headline.start} dur={headline.end - headline.start} />}
      <CaptionBar pages={pages} fps={fps} f={f} />
      {bi === BEATS.length - 1 && outroF > -1 && (
        <div style={{ position: "absolute", inset: 0, opacity: ramp(outroF, 6, 18) }}>
          <Logo f={Math.max(0, outroF - 6)} size={260} sub="Built on Claude Code and Cadence"
            subAt={Math.round((BEATS[BEATS.length - 1].sentences[1].start - BEATS[BEATS.length - 1].start) * fps) - 6} credit={credit} />
        </div>
      )}
    </AbsoluteFill>
  );
};
