// Side view of the glass rig. A drawing, not a picture of an iPhone.
export function RigDiagram() {
  return (
    <div
      className="s-diagram"
      role="img"
      aria-label="Side view: the iPhone lies screen up under glass tilted at 45 degrees. You read its reflection, and the camera behind the glass films you through it."
    >
      <svg className="d-wide" viewBox="0 0 800 400" aria-hidden="true">
        <line className="d-base" x1="250" y1="333" x2="560" y2="333" />
        <rect className="d-phone" x="280" y="318" width="240" height="13" rx="4" />
        <rect className="d-screen" x="292" y="315" width="216" height="3" />
        <line className="d-glass" x1="280" y1="78" x2="520" y2="318" />
        <path className="d-ray" d="M360 312 L360 158 L162 158" />
        <path className="d-arrow" d="M148 158 L164 150 L164 166Z" />
        <path className="d-sight" d="M572 176 L150 176" />
        <circle className="d-head" cx="100" cy="166" r="38" />
        <rect className="d-cam" x="600" y="142" width="120" height="68" rx="12" />
        <rect className="d-lens" x="570" y="156" width="32" height="40" rx="5" />
        <text className="d-label em" x="100" y="232" textAnchor="middle">You</text>
        <text className="d-label em" x="660" y="240" textAnchor="middle">Camera</text>
        <text className="d-label" x="660" y="264" textAnchor="middle">films through the glass</text>
        <text className="d-label" x="268" y="66" textAnchor="end">Glass at 45°</text>
        <text className="d-label" x="400" y="366" textAnchor="middle">iPhone, screen up, in landscape</text>
        <text className="d-label" x="236" y="144" textAnchor="middle">You read the reflection</text>
      </svg>
      <svg className="d-narrow" viewBox="0 0 360 300" aria-hidden="true">
        <line className="d-base" x1="120" y1="246" x2="300" y2="246" />
        <rect className="d-phone" x="140" y="234" width="140" height="10" rx="3" />
        <rect className="d-screen" x="148" y="231.5" width="124" height="2.5" />
        <line className="d-glass" x1="140" y1="94" x2="280" y2="234" />
        <path className="d-ray" d="M182 230 L182 136 L86 136" />
        <path className="d-arrow" d="M74 136 L86 130 L86 142Z" />
        <path className="d-sight" d="M290 150 L76 150" />
        <circle className="d-head" cx="44" cy="143" r="26" />
        <rect className="d-cam" x="302" y="124" width="50" height="50" rx="9" />
        <rect className="d-lens" x="288" y="134" width="16" height="30" rx="4" />
        <text className="d-label em" x="44" y="194" textAnchor="middle">You</text>
        <text className="d-label em" x="327" y="200" textAnchor="middle">Camera</text>
        <text className="d-label" x="132" y="82" textAnchor="end">Glass at 45°</text>
        <text className="d-label" x="210" y="276" textAnchor="middle">iPhone, screen up</text>
      </svg>
    </div>
  );
}
