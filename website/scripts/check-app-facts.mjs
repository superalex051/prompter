// Checks the claims in src/content/facts.ts against the app source in this repo.
// Run from website/ (npm run check:facts). Exits 1 and lists every mismatch.
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { facts } from '../src/content/facts.ts';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

export function checkFacts(root = repoRoot, f = facts) {
  const problems = [];
  for (const feature of f.features) {
    const path = join(root, feature.file);
    if (!existsSync(path)) {
      problems.push(`feature "${feature.id}": file missing: ${feature.file}`);
      continue;
    }
    if (!new RegExp(feature.pattern, 'i').test(readFileSync(path, 'utf8'))) {
      problems.push(`feature "${feature.id}": /${feature.pattern}/ not found in ${feature.file}`);
    }
  }
  // Flags that say the app has a capability must match the code.
  const sources = ['Prompter', 'Shared', 'PrompterMac', 'PrompterWatch'];
  if (!f.icloud && sourcesMention(root, sources, /import CloudKit/)) {
    problems.push('facts.icloud is false but the app imports CloudKit');
  }
  if (!f.pro && sourcesMention(root, sources, /import StoreKit/)) {
    problems.push('facts.pro is false but the app imports StoreKit');
  }
  if (f.price.pendingStoreKit && sourcesMention(root, sources, /import StoreKit/)) {
    problems.push('facts.price is marked pending StoreKit but the app imports StoreKit; update the flag');
  }
  // A platform the site names must have its app target in this repo.
  if (f.platforms.mac && !existsSync(join(root, 'PrompterMac'))) {
    problems.push('facts.platforms.mac is true but there is no PrompterMac folder');
  }
  if (f.platforms.watch && !existsSync(join(root, 'PrompterWatch'))) {
    problems.push('facts.platforms.watch is true but there is no PrompterWatch folder');
  }
  return problems;
}

import { readdirSync, statSync } from 'node:fs';
function sourcesMention(root, dirs, re) {
  const walk = (dir) => {
    if (!existsSync(dir)) return false;
    for (const name of readdirSync(dir)) {
      const p = join(dir, name);
      if (statSync(p).isDirectory()) {
        if (walk(p)) return true;
      } else if (name.endsWith('.swift') && re.test(readFileSync(p, 'utf8'))) {
        return true;
      }
    }
    return false;
  };
  return dirs.some((d) => walk(join(root, d)));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const problems = checkFacts();
  if (problems.length) {
    console.error('App facts check failed:\n- ' + problems.join('\n- '));
    process.exit(1);
  }
  console.log(`App facts check passed (${facts.features.length} features).`);
}
