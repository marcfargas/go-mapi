import { describe, it, expect } from 'vitest';
import {
  classifyLastError,
  classifyReadyMessage,
  MISSING_HOST_SUBSTRING,
} from '../hostDetector';
import {
  MISSING_HOST_CHROMIUM,
  ACCESS_FORBIDDEN,
  UNKNOWN_HOST_ERROR,
} from '../../__fixtures__/chrome-errors';

// TSTEST-02: classifyLastError + classifyReadyMessage unit tests.
//
// Drives the Phase 2 hostDetector pure helpers through the fixture strings
// in src/extension/src/__fixtures__/chrome-errors.ts. The fixture file is
// seeded from Chromium source (E2E-06) and may be updated from real E2E
// runs on windows-latest.

describe('classifyLastError', () => {
  it('returns ERROR when message is undefined', () => {
    expect(classifyLastError(undefined)).toBe('ERROR');
  });

  it('returns ERROR when message is empty string', () => {
    expect(classifyLastError('')).toBe('ERROR');
  });

  it('classifies the real Chromium MISSING_HOST_CHROMIUM string as MISSING', () => {
    expect(classifyLastError(MISSING_HOST_CHROMIUM)).toBe('MISSING');
  });

  it('classifies ACCESS_FORBIDDEN as ERROR (substring does not match MISSING)', () => {
    // The "forbidden" branch is classified as ERROR because it means the
    // host IS present but the extension is not in allowed_origins. This
    // requires reinstalling the host with the right extension ID — not a
    // "go install the host" flow.
    expect(classifyLastError(ACCESS_FORBIDDEN)).toBe('ERROR');
  });

  it('classifies UNKNOWN_HOST_ERROR as ERROR', () => {
    expect(classifyLastError(UNKNOWN_HOST_ERROR)).toBe('ERROR');
  });

  it('classifies an arbitrary unknown string as ERROR', () => {
    expect(classifyLastError('Some completely random error string')).toBe('ERROR');
  });

  it('matches the MISSING substring even when surrounded by other text', () => {
    const wrapped = 'prefix ' + MISSING_HOST_SUBSTRING + ' suffix';
    expect(classifyLastError(wrapped)).toBe('MISSING');
  });
});

describe('classifyReadyMessage', () => {
  it('returns READY when hostVersion is undefined (legacy unstamped host)', () => {
    // isHostVersionSupported treats undefined as supported so the
    // extension does not lock out legacy hosts that predate FOUND-02.
    expect(classifyReadyMessage(undefined)).toBe('READY');
  });

  it('returns READY when hostVersion is empty string', () => {
    expect(classifyReadyMessage('')).toBe('READY');
  });

  it('returns READY for the current v2.0.0 dead-branch case', () => {
    // MIN_SUPPORTED_HOST_VERSION === '2.0.0' — this is the branch that
    // makes OUTDATED dead code in v2.0.0.
    expect(classifyReadyMessage('2.0.0')).toBe('READY');
  });

  it('returns READY for a future host version', () => {
    expect(classifyReadyMessage('3.0.0')).toBe('READY');
  });

  it('returns OUTDATED for a host version below the minimum', () => {
    // Future-facing: if MIN_SUPPORTED_HOST_VERSION is bumped in v3.0.0,
    // this branch becomes live. Test locks the classifier wiring.
    expect(classifyReadyMessage('1.9.9')).toBe('OUTDATED');
  });

  it('returns OUTDATED for an early v1 host', () => {
    expect(classifyReadyMessage('1.0.0')).toBe('OUTDATED');
  });
});
