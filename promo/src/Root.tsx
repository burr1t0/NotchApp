import {Composition} from 'remotion';
import {Promo, TOTAL_FRAMES, FPS} from './Promo';

export const Root = () => (
  <Composition id="Promo" component={Promo} durationInFrames={TOTAL_FRAMES} fps={FPS} width={1920} height={1080} />
);
