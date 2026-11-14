import type { Metadata } from 'next';
import { DocPage } from '../../components/DocPage';
import { JsonLd } from '../../components/JsonLd';
import { facts } from '../../content/facts.ts';
import { breadcrumbLd } from '../../content/seo.ts';
import { pageMetadata } from '../../lib/meta.ts';
import { PrompterScreen } from '../../components/PrompterScreen';
import { RigDiagram } from '../../components/RigDiagram';
import { rigBlocks, rigDek, rigTitle } from '../../content/rig.ts';

export const metadata: Metadata = pageMetadata('rig');

const mirrorPair = (
  <div className="s-mirrorpair">
    <figure>
      <PrompterScreen mirrored still />
      <figcaption>On the iPhone</figcaption>
    </figure>
    <figure>
      <PrompterScreen still />
      <figcaption>In the glass</figcaption>
    </figure>
  </div>
);

// The second line is drawn to show the effect, not photographed.
const ghost = (
  <div className="s-ghostdemo" aria-hidden="true">
    <div className="thin">
      <span>Small, regular text</span>Talk straight down the lens
    </div>
    <div className="heavy">
      <span>Prompter&apos;s default</span>Talk straight down the lens
    </div>
  </div>
);

export default function RigPage() {
  return (
    <>
      <JsonLd data={breadcrumbLd(facts, 'rig')} />
      <DocPage
        title={rigTitle}
        dek={rigDek}
        blocks={rigBlocks()}
        figures={{ diagram: <RigDiagram />, 'mirror-pair': mirrorPair, ghost }}
      />
    </>
  );
}
