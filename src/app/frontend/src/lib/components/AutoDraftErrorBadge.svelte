<script lang="ts">
  import type { ErrorCategory } from '../settings';

  let { category }: { category: ErrorCategory } = $props();

  const label = $derived(
    category === 'signed-out'
      ? 'Signed out'
      : category === 'network'
        ? 'Network error'
        : 'Gmail error',
  );
</script>

<span
  class="badge"
  role="status"
  tabindex="0"
  title={label}
  aria-label={`Auto-draft failed: ${label}`}
>!</span>

<style>
  .badge {
    position: absolute;
    top: 6px;
    right: 6px;
    width: 20px;
    height: 20px;
    border-radius: 50%;
    background: var(--c-destructive);
    color: white;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 11px;
    font-weight: 600;
    line-height: 1;
    cursor: help;
  }

  .badge:focus-visible {
    outline: 2px solid var(--c-accent);
    outline-offset: 2px;
  }
</style>
