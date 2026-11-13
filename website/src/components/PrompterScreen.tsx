// The prompter screen, drawn in HTML and CSS from the app's own numbers (PrompterSettings, the HUD and the
// reading line): 72 pt Heavy text on an 874 pt wide canvas, 6% side margins, reading line at one third,
// text above it dimmed to 35%, time left on the left and speed on the right, mirrored with the text.
// Decorative: hidden from screen readers; the caption next to it says what it shows.

const LINES = [
  'Talk straight down the lens without memorizing a single line.',
  'Lay the phone under glass and Prompter mirrors the text for you.',
  'Start it from your wrist, then step back into frame.',
];

type Props = {
  mirrored?: boolean;
  paused?: boolean;
  still?: boolean;
  motionOk?: boolean;
  showPausedWord?: boolean;
  time?: string;
  bar?: number;
  testId?: string;
};

export function PrompterScreen({
  mirrored = false,
  paused = false,
  still = false,
  motionOk = false,
  showPausedWord = false,
  time = '1:04',
  bar = 11.1,
  testId,
}: Props) {
  const className = ['pscreen', mirrored && 'mirrored', paused && 'paused', still && 'still', motionOk && 'motion-ok']
    .filter(Boolean)
    .join(' ');
  return (
    <div className={className} aria-hidden="true" data-testid={testId}>
      <div className="pflip">
        <div className="proll">
          {[...LINES, ...LINES].map((line, i) => (
            <p key={i}>{line}</p>
          ))}
        </div>
        <div className="pdim" />
        <svg className="pchev l" viewBox="0 0 16 20" aria-hidden="true">
          <path d="M0 0L16 10L0 20Z" />
        </svg>
        <svg className="pchev r" viewBox="0 0 16 20" aria-hidden="true">
          <path d="M16 0L0 10L16 20Z" />
        </svg>
        <div className="phud">
          <div className="phud-row">
            <span className="ptime">{time}</span>
            {showPausedWord ? <span className="pword">Paused</span> : null}
            <span>140 wpm</span>
          </div>
          <div className="pbar">
            <i style={{ width: `${bar.toFixed(1)}%` }} />
          </div>
        </div>
      </div>
    </div>
  );
}
