<script lang="ts">
  let { onSignIn }: { onSignIn: () => void } = $props();
</script>

<section class="signin">
  <h1>go-mapi</h1>
  <p class="tagline">Gmail drafts for Windows "Send to Mail recipient".</p>
  <p class="copy">
    Sign in with your Google account. go-mapi will create drafts in your Gmail
    account; it never sends mail on its own and never stores message bodies.
  </p>
  <button class="signin-btn" type="button" onclick={onSignIn}>
    Sign in with Google
  </button>
  <p class="footnote">
    Queued emails stay on your computer until you sign in.
  </p>
</section>

<style>
  .signin {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 1rem;
    padding: 3rem 2rem;
    min-height: 100%;
    text-align: center;
  }
  .signin h1 { font-size: 2rem; margin: 0; }
  .tagline { color: var(--c-text-muted, #666); margin: 0; }
  .copy { max-width: 32em; line-height: 1.5; color: var(--c-text, #222); }
  .signin-btn {
    background: #1a73e8;
    color: white;
    font-size: 1rem;
    font-weight: 600;
    padding: 0.75rem 1.5rem;
    border: 0;
    border-radius: 4px;
    cursor: pointer;
  }
  .signin-btn:hover { background: #1662c4; }
  .footnote { font-size: 0.85rem; color: var(--c-text-muted, #666); }
</style>
