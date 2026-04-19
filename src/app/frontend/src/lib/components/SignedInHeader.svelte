<script lang="ts">
  import type { Mode } from '../settings';
  import ModeToggle from './ModeToggle.svelte';

  let { email, name, onSignOut, mode, onModeChange }: {
    email: string;
    name: string;
    onSignOut: () => void;
    mode: Mode;
    onModeChange: (m: Mode) => void;
  } = $props();

  const displayName = $derived(email || name || 'your Google account');
</script>

<header class="hdr">
  <span class="who">Signed in as <strong>{displayName}</strong></span>
  <ModeToggle {mode} {onModeChange} />
  <button type="button" class="signout" onclick={onSignOut}>Sign out</button>
</header>

<style>
  .hdr {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: var(--space-sm) var(--space-md);
    border-bottom: 1px solid var(--c-border);
    gap: var(--space-md);
  }

  .who {
    color: var(--c-text-muted);
    font-size: 14px;
  }

  .signout {
    background: transparent;
    border: 1px solid var(--c-border);
    border-radius: 4px;
    padding: 4px var(--space-btn-x);
    cursor: pointer;
    color: var(--c-text);
    font-size: 14px;
    font-family: inherit;
  }

  .signout:hover {
    background: var(--c-surface-alt);
  }

  .signout:focus-visible {
    outline: 2px solid var(--c-accent);
    outline-offset: -2px;
  }
</style>
