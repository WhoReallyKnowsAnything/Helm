import React from "react";
import { Composition } from "remotion";
import { Launch, videoFrames } from "./Video";

const FPS = 30;

export const Root: React.FC = () => (
  <Composition id="Launch" component={Launch} durationInFrames={videoFrames(FPS)} fps={FPS} width={1920} height={1080} defaultProps={{ credit: "" }} />
);
