import React from 'react';
import {AbsoluteFill, Easing, Img, Sequence, interpolate, staticFile, useCurrentFrame} from 'remotion';

export const FPS = 50;
const sec = (s: number) => Math.round(s * FPS);

// The recorded tour (scripts/make-promo.sh) is one frame sequence at 50 fps,
// public/panel/NNNNN.png. Each scene plays a stretch of it.
type Scene = {from: number; to: number; title: string; subtitle: string; zoom: [number, number]};

const INTRO = sec(3.2);
const OUTRO = sec(3.4);
const FADE = 12;

const scenes: Scene[] = [
  {from: 0.2, to: 3.4, title: 'Всё нужное — в вырезе', subtitle: 'Наведи курсор — и он раскроется', zoom: [2.6, 2.1]},
  {from: 3.4, to: 7.2, title: 'Музыка под рукой', subtitle: 'Любой плеер: обложка, перемотка, эквалайзер', zoom: [1.7, 1.8]},
  {from: 7.6, to: 12.4, title: 'Все сессии Claude на виду', subtitle: 'Статус, контекст и прогресс плана', zoom: [1.7, 1.8]},
  {from: 12.4, to: 17.9, title: 'Запрос разрешения — без переключения', subtitle: 'Карточка выезжает сама и мягко подсвечивается', zoom: [2.1, 1.9]},
  {from: 18.8, to: 23.4, title: 'Вопросы агента — кнопками', subtitle: 'Выбери вариант, не открывая чат', zoom: [1.75, 1.85]},
  {from: 23.8, to: 29.6, title: 'Файлы и буфер обмена', subtitle: 'Скриншоты, полка для файлов, история копирований', zoom: [1.7, 1.8]},
  {from: 29.6, to: 36.4, title: 'Перевод RU ↔ EN', subtitle: 'Системный перевод, умеет разбирать идентификаторы кода', zoom: [1.7, 1.8]},
];

const lengths = scenes.map((scene) => sec(scene.to - scene.from));
const starts = lengths.map((_, index) => INTRO + lengths.slice(0, index).reduce((a, b) => a + b, 0));
export const TOTAL_FRAMES = INTRO + lengths.reduce((a, b) => a + b, 0) + OUTRO;

// Dark ink: the sky is light, so light text would wash out on it.
const INK = '#1b1a3d';
const INK_SOFT = '#3b3a6b';
const FONT = '"SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif';

const Sky: React.FC = () => {
  const frame = useCurrentFrame();
  const drift = (speed: number) => Math.sin(frame / (FPS * speed)) * 40;
  const cloud = (left: number, top: number, w: number, h: number, alpha: number, speed: number): React.CSSProperties => ({
    position: 'absolute', left: left + drift(speed), top, width: w, height: h, borderRadius: '50%',
    background: `radial-gradient(closest-side, rgba(255,255,255,${alpha}), rgba(255,255,255,0))`,
  });
  return (
    <AbsoluteFill style={{background: 'linear-gradient(180deg, #6f9bff 0%, #a998f6 30%, #f59cc0 62%, #ffc08a 100%)'}}>
      <div style={cloud(100, 380, 900, 360, 0.9, 9)} />
      <div style={cloud(900, 520, 1000, 380, 0.85, 12)} />
      <div style={cloud(-200, 700, 800, 300, 0.7, 7)} />
      <div style={cloud(1250, 250, 700, 280, 0.6, 10)} />
      <div style={cloud(500, 820, 1100, 320, 0.8, 11)} />
    </AbsoluteFill>
  );
};

const MenuBar: React.FC = () => {
  const bar = (x: number, w: number): React.CSSProperties => ({
    position: 'absolute', top: 24, left: x, width: w, height: 16, borderRadius: 6, background: 'rgba(25,25,40,0.5)',
  });
  return (
    <div style={{position: 'absolute', top: 0, left: 0, width: 1920, height: 60, background: 'rgba(255,255,255,0.28)'}}>
      {[[30, 24], [74, 70], [156, 52], [224, 60]].map(([x, w]) => <div key={x} style={bar(x, w)} />)}
      {[[1680, 24], [1724, 30], [1772, 24], [1812, 44]].map(([x, w]) => <div key={x} style={bar(x, w)} />)}
    </div>
  );
};

// The panel at the camera's current zoom, hung from the top centre.
const Panel: React.FC<{tourFrame: number; zoom: number}> = ({tourFrame, zoom}) => {
  const name = String(Math.max(0, tourFrame)).padStart(5, '0');
  return (
    <div style={{position: 'absolute', left: 0, top: 0, width: 1920, height: 1080, transformOrigin: '960px 0px', transform: `scale(${zoom})`}}>
      <MenuBar />
      <Img src={staticFile(`panel/${name}.png`)} style={{position: 'absolute', left: 488, top: 0, width: 944, height: 428}} />
    </div>
  );
};

const SceneView: React.FC<{scene: Scene; length: number}> = ({scene, length}) => {
  const frame = useCurrentFrame();
  const fade = interpolate(frame, [0, FADE, length - FADE, length], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const zoom = interpolate(frame, [0, length], scene.zoom, {easing: Easing.inOut(Easing.quad)});
  const captionIn = interpolate(frame, [FADE, FADE + 18], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic)});
  return (
    <AbsoluteFill style={{opacity: fade}}>
      <Panel tourFrame={Math.round(scene.from * FPS) + frame} zoom={zoom} />
      <div style={{position: 'absolute', left: 0, right: 0, bottom: 132, textAlign: 'center', fontFamily: FONT, color: INK, opacity: captionIn, transform: `translateY(${(1 - captionIn) * 16}px)`, textShadow: '0 2px 20px rgba(255,255,255,0.6)'}}>
        <div style={{fontSize: 64, fontWeight: 700, letterSpacing: -1}}>{scene.title}</div>
        <div style={{fontSize: 38, fontWeight: 500, marginTop: 10, color: INK_SOFT}}>{scene.subtitle}</div>
      </div>
    </AbsoluteFill>
  );
};

const Title: React.FC<{lines: [string, string]; extra?: string}> = ({lines, extra}) => {
  const frame = useCurrentFrame();
  const appear = interpolate(frame, [0, 30], [0, 1], {extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic)});
  const sub = interpolate(frame, [20, 50], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', fontFamily: FONT, color: INK, textShadow: '0 4px 40px rgba(255,255,255,0.55)'}}>
      <div style={{fontSize: 150, fontWeight: 800, letterSpacing: -4, opacity: appear, transform: `translateY(${(1 - appear) * 30}px) scale(${0.96 + 0.04 * appear})`}}>{lines[0]}</div>
      <div style={{fontSize: 50, fontWeight: 500, marginTop: 6, opacity: sub, color: INK_SOFT}}>{lines[1]}</div>
      {extra ? <div style={{fontSize: 36, fontWeight: 600, marginTop: 48, opacity: sub, background: INK, color: 'white', textShadow: 'none', padding: '14px 32px', borderRadius: 40}}>{extra}</div> : null}
    </AbsoluteFill>
  );
};

export const Promo: React.FC = () => {
  const frame = useCurrentFrame();
  const outroStart = TOTAL_FRAMES - OUTRO;
  const introFade = interpolate(frame, [INTRO - 14, INTRO], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const outroFade = interpolate(frame, [outroStart, outroStart + 14], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <AbsoluteFill>
      <Sky />
      <Sequence from={0} durationInFrames={INTRO}>
        <AbsoluteFill style={{opacity: introFade}}>
          <Title lines={['NotchApp', 'Всё нужное — в вырезе MacBook']} />
        </AbsoluteFill>
      </Sequence>
      {scenes.map((scene, index) => (
        <Sequence key={index} from={starts[index]} durationInFrames={lengths[index]}>
          <SceneView scene={scene} length={lengths[index]} />
        </Sequence>
      ))}
      <Sequence from={outroStart} durationInFrames={OUTRO}>
        <AbsoluteFill style={{opacity: outroFade}}>
          <Title lines={['NotchApp', 'Музыка · Claude · Файлы · Перевод']} extra="github.com/burr1t0/NotchApp" />
        </AbsoluteFill>
      </Sequence>
    </AbsoluteFill>
  );
};
