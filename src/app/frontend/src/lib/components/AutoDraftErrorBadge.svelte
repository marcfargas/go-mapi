<script lang="ts">
  import type { ErrorCategory } from '../settings';

  let {
    category,
    reason,
  }: {
    category: ErrorCategory;
    /** QUICK-260423-tk6: raw Go error text, appended to the tooltip/aria-label. */
    reason?: string;
  } = $props();

  const label = $derived(
    category === 'signed-out'
      ? 'Signed out'
      : category === 'network'
        ? 'Network error'
        : 'Gmail error',
  );

  // Compose a tooltip that includes the raw reason when present so the user
  // can tell "attachment not found" apart from a Gmail 5xx without reading
  // app.log. Keep the category label first so quick-scanners still see it.
  const tooltip = $derived(reason ? `${label}: ${reason}` : label);
</script>

<span
  class="badge"
  role="status"
  tabindex="0"
  title={tooltip}
  aria-label={`Auto-draft failed: ${tooltip}`}
  data-testid="auto-draft-error-badge"
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
