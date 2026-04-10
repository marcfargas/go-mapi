import { describe, it, expect } from 'vitest';
import {
  compareHostVersion,
  isHostVersionSupported,
  MIN_SUPPORTED_HOST_VERSION,
} from '../hostVersion';

// TSTEST-03: compareHostVersion + isHostVersionSupported unit tests.
//
// Locks the dotted-numeric semver comparator behavior. The dead-branch
// case (current === minimum) is the most important: it's what makes
// OUTDATED unreachable in v2.0.0.

describe('compareHostVersion', () => {
  it('returns 0 for equal versions', () => {
    expect(compareHostVersion('2.0.0', '2.0.0')).toBe(0);
  });

  it('returns 1 when current > minimum (patch)', () => {
    expect(compareHostVersion('2.0.1', '2.0.0')).toBe(1);
  });

  it('returns -1 when current < minimum (patch)', () => {
    expect(compareHostVersion('2.0.0', '2.0.1')).toBe(-1);
  });

  it('returns 1 when current > minimum (major)', () => {
    expect(compareHostVersion('3.0.0', '2.0.0')).toBe(1);
  });

  it('returns -1 when current < minimum (major)', () => {
    expect(compareHostVersion('1.9.9', '2.0.0')).toBe(-1);
  });

  it('returns 0 when current has fewer segments (2.0 == 2.0.0)', () => {
    expect(compareHostVersion('2.0', '2.0.0')).toBe(0);
  });

  it('coerces non-numeric segments to 0', () => {
    // "abc" → [0], minimum "2.0.0" → [2,0,0], so 0 < 2.
    expect(compareHostVersion('abc', '2.0.0')).toBe(-1);
  });

  it('treats missing trailing segments as 0', () => {
    expect(compareHostVersion('2', '2.0.0')).toBe(0);
  });
});

describe('isHostVersionSupported', () => {
  it('returns true for undefined host version (legacy host compat)', () => {
    expect(isHostVersionSupported(undefined)).toBe(true);
  });

  it('returns true for empty string host version', () => {
    expect(isHostVersionSupported('')).toBe(true);
  });

  it('returns true for the v2.0.0 dead-branch case (min == current)', () => {
    // This is the key Phase 2 invariant: MIN_SUPPORTED_HOST_VERSION
    // equals the current release so OUTDATED is a dead branch shipped
    // ready for v3.0.0 activation.
    expect(MIN_SUPPORTED_HOST_VERSION).toBe('2.0.0');
    expect(isHostVersionSupported('2.0.0')).toBe(true);
  });

  it('returns true for a version above minimum', () => {
    expect(isHostVersionSupported('3.0.0')).toBe(true);
  });

  it('returns false for a version below minimum', () => {
    expect(isHostVersionSupported('1.9.9')).toBe(false);
  });

  it('returns false for a malformed non-numeric version (NaN → 0)', () => {
    // "not-a-version" → [0] which compares less than [2,0,0].
    expect(isHostVersionSupported('not-a-version')).toBe(false);
  });
});
