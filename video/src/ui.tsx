import React from "react";
import { interpolate, spring } from "remotion";

export const FPS = 30;

/** The design kit's dark tokens (Sources/OrchestratorGUI/DesignKit/Tokens.swift), as hex. */
export const C = {
  bg: "#0E0E0F", g900: "#121213", g850: "#161617", g825: "#1C1C1E", g800: "#212123", g750: "#2A2A2C",
  g700: "#48484C", g500: "#9A9A9E", g300: "#C9C9CC", g100: "#E6E6E8",
  cyan: "#3CC8D8", blue: "#5AA2FF", lime: "#C5E478", green: "#8FD6A4", red: "#EE9F98", yellow: "#F3D966",
  purple: "#C5A1EA", stalled: "#6B727B", blueFill: "#111825", cyanFill: "#101C21",
};
export const MONO = 'ui-monospace, "SF Mono", Menlo, monospace';
export const SANS = '-apple-system, "SF Pro Display", "Helvetica Neue", Arial, sans-serif';

/** Spring that starts at `delay` frames and settles near 1. */
export const sp = (frame: number, delay = 0, damping = 18, stiffness = 120) =>
  spring({ frame: frame - delay, fps: FPS, config: { damping, stiffness, mass: 0.9 } });

export const clamp01 = (v: number) => Math.max(0, Math.min(1, v));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
export const ramp = (frame: number, from: number, to: number) =>
  interpolate(frame, [from, to], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });

/** Fades and lifts its children in at `delay`. */
export const Reveal: React.FC<{ f: number; delay: number; children: React.ReactNode; style?: React.CSSProperties; dy?: number }> = ({
  f, delay, children, style, dy = 14,
}) => {
  const t = sp(f, delay, 20, 140);
  return <div style={{ opacity: clamp01(t * 1.4), transform: `translateY(${(1 - t) * dy}px)`, ...style }}>{children}</div>;
};

export const Pill: React.FC<{ children: React.ReactNode; fill?: string; color?: string; border?: string; dim?: boolean; style?: React.CSSProperties }> = ({
  children, fill = C.g825, color = C.g100, border = C.g750, dim, style,
}) => (
  <span style={{
    display: "inline-block", padding: "5px 12px", borderRadius: 5, background: fill, color, border: `1px solid ${border}`,
    fontFamily: MONO, fontSize: 13, opacity: dim ? 0.45 : 1, ...style,
  }}>{children}</span>
);

export const Cursor: React.FC<{ x: number; y: number; press: number; opacity?: number }> = ({ x, y, press, opacity = 1 }) => (
  <div style={{ position: "absolute", left: x, top: y, opacity, zIndex: 50, pointerEvents: "none", transform: `scale(${1 - press * 0.12})`, transformOrigin: "0 0" }}>
    {press > 0 && (
      <div style={{ position: "absolute", left: -18, top: -18, width: 36, height: 36, borderRadius: 36, border: `2px solid ${C.lime}`,
        opacity: 1 - press, transform: `scale(${0.5 + press * 1.6})` }} />
    )}
    <svg width="26" height="30" viewBox="0 0 26 30" style={{ filter: "drop-shadow(0 3px 5px rgba(0,0,0,.6))" }}>
      <path d="M2 2 L2 24 L8 18.5 L12.5 28 L16.5 26.2 L12.2 17 L20.5 17 Z" fill="#fff" stroke="#111" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  </div>
);
