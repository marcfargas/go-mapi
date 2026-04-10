// Host version gate module (EXT-03).
//
// MIN_SUPPORTED_HOST_VERSION is pinned to the current release so the OUTDATED
// branch in hostDetector.ts ships as dead code in v2.0.0. Bumping this
// constant in v3.0.0 activates the branch without any wire-protocol change.
//
// Pure module: no Chrome API, no side effects.

export const MIN_SUPPORTED_HOST_VERSION = '2.0.0';

/**
 * Compare two dotted-numeric host version strings (e.g. "2.0.0", "1.3.10").
 *
 * Returns:
 *   -1 if current <  minimum
 *    0 if current == minimum
 *   +1 if current >  minimum
 *
 * Non-numeric segments are coerced to 0 via Number.parseInt. Missing segments
 * are treated as 0 so "2.0" compares equal to "2.0.0". This matches the host's
 * plain x.y.z versioning scheme — no pre-release suffixes are expected.
 */
export function compareHostVersion(current: string, minimum: string): number {
  const parse = (v: string): number[] =>
    v.split('.').map((p) => {
      const n = Number.parseInt(p, 10);
      return Number.isNaN(n) ? 0 : n;
    });
  const a = parse(current);
  const b = parse(minimum);
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) {
    const ai = a[i] ?? 0;
    const bi = b[i] ?? 0;
    if (ai > bi) return 1;
    if (ai < bi) return -1;
  }
  return 0;
}

/**
 * Returns true if the given host version is at or above MIN_SUPPORTED_HOST_VERSION.
 *
 * An undefined or empty version (e.g. from a legacy host that doesn't stamp
 * hostVersion yet) is treated as supported — the extension should not lock
 * out users who haven't updated their host in a way that triggers a false
 * OUTDATED state. Once the minimum supported version is bumped in v3.0.0,
 * callers may choose to tighten this policy.
 */
export function isHostVersionSupported(current: string | undefined): boolean {
  if (current === undefined || current === '') return true;
  return compareHostVersion(current, MIN_SUPPORTED_HOST_VERSION) >= 0;
}
