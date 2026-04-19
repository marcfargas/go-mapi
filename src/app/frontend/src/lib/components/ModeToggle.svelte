<script lang="ts">
  import type { Mode } from '../settings';

  let { mode, onModeChange }: {
    mode: Mode;
    onModeChange: (next: Mode) => void;
  } = $props();

  function select(next: Mode) {
    if (next === mode) return; // no-op on active click
    onModeChange(next);
  }
</script>

<div class="toggle" role="group" aria-label="Draft mode">
  <button
    type="button"
    class="segment"
    class:active={mode === 'manual'}
    aria-pressed={mode === 'manual'}
    onclick={() => select('manual')}
  >
    Manual
  </button>
  <button
    type="button"
    class="segment"
    class:active={mode === 'auto-draft'}
    aria-pressed={mode === 'auto-draft'}
    onclick={() => select('auto-draft')}
  >
    Auto-draft
  </button>
</div>

<style>
  .toggle {
    display: inline-flex;
    border: 1px solid var(--c-border);
    border-radius: 4px;
    overflow: hidden;
  }

  .segment {
    padding: 4px 16px;
    min-height: 28px;
    min-width: 72px;
    border: none;
    cursor: pointer;
    font-family: inherit;
    font-size: 14px;
    font-weight: 400;
    background: var(--c-surface-alt);
    color: var(--c-text);
  }

  .segment:hover:not(.active) {
    background: var(--c-border);
  }

  .segment.active {
    background: var(--c-accent);
    color: white;
    font-weight: 600;
    cursor: default;
  }

  .segment:focus-visible {
    outline: 2px solid var(--c-accent);
    outline-offset: -2px;
  }
</style>
