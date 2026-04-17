<script lang="ts">
  let { email, name, onSignOut }: { email: string; name: string; onSignOut: () => void } = $props();
  const displayName = email || name || 'your Google account';
</script>

<header class="hdr">
  <span class="who">Signed in as <strong>{displayName}</strong></span>
  <button type="button" class="signout" onclick={onSignOut}>Sign out</button>
</header>

<style>
  .hdr {
    display: flex; align-items: center; justify-content: space-between;
    padding: 0.5rem 1rem; border-bottom: 1px solid #e5e5e5;
    font-size: 0.9rem;
  }
  .who { color: #333; }
  .signout {
    background: transparent; border: 1px solid #ccc; border-radius: 4px;
    padding: 0.25rem 0.75rem; cursor: pointer; color: #333;
  }
  .signout:hover { background: #f5f5f5; }
</style>
