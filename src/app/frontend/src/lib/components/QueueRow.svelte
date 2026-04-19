<script lang="ts">
  import type { EmailWithId } from '../queue';
  import type { ErrorCategory } from '../settings';
  import AutoDraftErrorBadge from './AutoDraftErrorBadge.svelte';

  let {
    item,
    state = 'idle',
    authenticated = true,
    errorCategory,
    onCreateDraft,
    onDismiss,
  }: {
    item: EmailWithId;
    state?: 'idle' | 'in-flight' | 'drafted-flash' | 'error';
    authenticated?: boolean;
    errorCategory?: ErrorCategory;
    onCreateDraft: (id: string) => void;
    onDismiss: (id: string) => void;
  } = $props();

  // Access typed message fields — message may be undefined for partial items.
  // The local MailMessage interface in queue.ts includes a `from` field.
  const msg = $derived(item.message as (typeof item.message & {
    from?: { name?: string; address?: string };
    attachments?: { filename?: string }[];
  }) | undefined);

  const sender = $derived(
    msg?.from?.name ||
    msg?.from?.address ||
    '(unknown sender)',
  );
  const subject = $derived(msg?.subject || '(no subject)');
  const attachCount = $derived(msg?.attachments?.length ?? 0);
  const tsDisplay = $derived(formatTs(msg?.timestamp));

  const createLabel = $derived(state === 'in-flight' ? 'Creating…' : 'Create draft');
  const buttonsDisabled = $derived(state === 'in-flight' || !authenticated);
  const disabledTitle = $derived(!authenticated ? 'Sign in first' : '');

  function formatTs(iso?: string): string {
    if (!iso) return '';
    const d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    const now = new Date();
    const sameDay = d.toDateString() === now.toDateString();
    if (sameDay) {
      return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
    }
    return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  }
</script>

<li
  class="queue-row"
  class:queue-row--flash={state === 'drafted-flash'}
  class:queue-row--error={state === 'error'}
  class:queue-row--inflight={state === 'in-flight'}
  tabindex="0"
>
  <span class="sender">{sender}</span>
  <span class="subject">
    {#if state === 'drafted-flash'}
      <span class="drafted-label">✓ Drafted</span>
    {:else}
      {subject}{#if attachCount > 0}<span class="attach"> 📎 {attachCount}</span>{/if}
    {/if}
  </span>
  <span class="ts">{tsDisplay}</span>
  <span class="actions">
    <button
      type="button"
      class="btn btn--primary"
      disabled={buttonsDisabled}
      title={disabledTitle}
      onclick={() => onCreateDraft(item.id)}
    >{createLabel}</button>
    <button
      type="button"
      class="btn btn--ghost"
      disabled={buttonsDisabled}
      title={disabledTitle}
      onclick={() => onDismiss(item.id)}
    >Dismiss</button>
  </span>
  {#if state === 'error' && errorCategory}
    <AutoDraftErrorBadge category={errorCategory} />
  {/if}
</li>

<style>
  .queue-row {
    position: relative;
    display: grid;
    grid-template-columns: 1fr 2fr auto auto;
    gap: var(--space-md);
    align-items: center;
    padding: var(--space-sm) var(--space-md);
    border-bottom: 1px solid var(--c-border);
    background: var(--c-surface);
    transition: background-color 150ms ease-in, opacity 300ms ease-out;
    list-style: none;
  }

  .queue-row:hover:not(.queue-row--flash):not(.queue-row--error) {
    background: var(--c-surface-alt);
  }

  .queue-row:focus-visible {
    outline: 2px solid var(--c-accent);
    outline-offset: -2px;
  }

  .queue-row--inflight {
    opacity: 0.7;
  }

  .queue-row--error {
    background: var(--c-error-bg);
  }

  .queue-row--flash {
    background: var(--c-success-flash);
    transition: background-color 300ms ease-in, opacity 300ms ease-out 1200ms;
  }

  .sender {
    font-weight: 600;
    color: var(--c-text);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .subject {
    color: var(--c-text-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .drafted-label {
    color: var(--c-success-text);
    font-size: 11px;
    font-weight: 600;
  }

  .attach {
    font-size: 12px;
    color: var(--c-text-muted);
  }

  .ts {
    font-size: 12px;
    color: var(--c-text-muted);
    text-align: right;
  }

  .actions {
    display: inline-flex;
    gap: var(--space-sm);
  }

  .btn {
    padding: 4px var(--space-btn-x);
    min-height: 28px;
    font-size: 14px;
    font-weight: 600;
    font-family: inherit;
    border-radius: 4px;
    cursor: pointer;
  }

  .btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn--primary {
    background: var(--c-accent);
    color: white;
    border: none;
  }

  .btn--primary:hover:not(:disabled) {
    filter: brightness(0.9);
  }

  .btn--ghost {
    background: transparent;
    color: var(--c-destructive);
    border: 1px solid var(--c-destructive);
  }

  .btn--ghost:hover:not(:disabled) {
    background: var(--c-error-bg);
  }
</style>
