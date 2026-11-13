'use client';

import { useEffect, useRef, useState } from 'react';
import { PrompterScreen } from './PrompterScreen';

// The clock counts down like the app's status line on a 1:12 script, then starts over.
const TOTAL = 72;
const START = 64;
const LOOP_AT = 4;

function clock(t: number): string {
  const s = t % 60;
  return `${Math.floor(t / 60)}:${s < 10 ? '0' : ''}${s}`;
}

/**
 * The live hero: the prompter rolls at 140 wpm. "Mirror it" flips the screen only (never the caption or the
 * page). "Pause" stops the text and the clock. With Reduce Motion on, it starts paused and rolls only after
 * Play. It also holds still while it is off screen or the tab is hidden, without changing the button.
 */
export function Hero() {
  const [mirrored, setMirrored] = useState(false);
  const [userPaused, setUserPaused] = useState(false);
  const [motionOk, setMotionOk] = useState(false);
  const [offscreen, setOffscreen] = useState(false);
  const [tabHidden, setTabHidden] = useState(false);
  const [t, setT] = useState(START);
  const figure = useRef<HTMLElement>(null);
  const motionOkRef = useRef(false);

  const paused = userPaused || offscreen || tabHidden;

  useEffect(() => {
    const query = window.matchMedia('(prefers-reduced-motion: reduce)');
    if (query.matches) setUserPaused(true);
    const onChange = (e: MediaQueryListEvent) => {
      if (e.matches && !motionOkRef.current) setUserPaused(true);
    };
    query.addEventListener('change', onChange);
    return () => query.removeEventListener('change', onChange);
  }, []);

  useEffect(() => {
    const el = figure.current;
    if (!el || typeof IntersectionObserver === 'undefined') return;
    const io = new IntersectionObserver(([entry]) => setOffscreen(!entry.isIntersecting));
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => {
    const onVisibility = () => setTabHidden(document.visibilityState === 'hidden');
    onVisibility();
    document.addEventListener('visibilitychange', onVisibility);
    return () => document.removeEventListener('visibilitychange', onVisibility);
  }, []);

  useEffect(() => {
    if (paused) return;
    const id = window.setInterval(() => setT((x) => (x - 1 < LOOP_AT ? START : x - 1)), 1000);
    return () => window.clearInterval(id);
  }, [paused]);

  const togglePause = () => {
    if (userPaused) {
      motionOkRef.current = true;
      setMotionOk(true);
      setUserPaused(false);
    } else {
      setUserPaused(true);
    }
  };

  return (
    <figure className="s-fig" ref={figure} data-testid="hero">
      <div className="s-plainwrap">
        <PrompterScreen
          testId="hero-screen"
          mirrored={mirrored}
          paused={paused}
          motionOk={motionOk}
          showPausedWord={userPaused}
          time={clock(t)}
          bar={((TOTAL - t) / TOTAL) * 100}
        />
      </div>
      <figcaption className="s-cap">
        <span className="s-cap-text">Under glass, the text is mirrored so the reflection reads right.</span>
        <button type="button" className="s-btn" aria-pressed={mirrored} onClick={() => setMirrored((m) => !m)}>
          Mirror it
        </button>
        <button type="button" className="s-btn" onClick={togglePause}>
          {userPaused ? (
            <svg viewBox="0 0 12 12" aria-hidden="true">
              <path d="M2.5 1.2L10.5 6L2.5 10.8Z" fill="currentColor" />
            </svg>
          ) : (
            <svg viewBox="0 0 12 12" aria-hidden="true">
              <rect x="1.5" y="1" width="3" height="10" rx="1" fill="currentColor" />
              <rect x="7.5" y="1" width="3" height="10" rx="1" fill="currentColor" />
            </svg>
          )}
          <span>{userPaused ? 'Play' : 'Pause'}</span>
        </button>
      </figcaption>
    </figure>
  );
}
