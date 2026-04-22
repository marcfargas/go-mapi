<script lang="ts">
  let { onRestore }: { onRestore: () => void } = $props();
</script>

<div class="banner" role="alert" data-testid="reauth-banner">
  <span class="msg">Sign-in expired — click to restore</span>
  <button type="button" onclick={onRestore}>Sign in again</button>
</div>

<style>
  .banner {
    background: var(--c-destructive); color: white;
    display: flex; align-items: center; justify-content: space-between;
    padding: 0.5rem 1rem; gap: 1rem;
  }
  .msg { font-weight: 500; }
  button {
    background: white; color: var(--c-destructive); border: 0;
    padding: 0.35rem 0.75rem; border-radius: 4px; font-weight: 600; cursor: pointer;
  }
</style>
