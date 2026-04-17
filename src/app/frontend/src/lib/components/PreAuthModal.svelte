<script lang="ts">
  let { onContinue, onCancel }: { onContinue: () => void; onCancel: () => void } = $props();
</script>

<div class="backdrop" role="dialog" aria-modal="true" aria-labelledby="preauth-title">
  <div class="modal">
    <h2 id="preauth-title">One thing before we continue</h2>
    <p>
      Google will show a warning that <strong>go-mapi isn't verified</strong>.
      This is expected — verification takes several weeks for small open-source apps
      and is in progress.
    </p>
    <p>To continue, click:</p>
    <ol class="steps">
      <li><strong>Advanced</strong></li>
      <li><strong>Go to go-mapi (unsafe)</strong></li>
    </ol>
    <p class="note">
      go-mapi only requests permission to create Gmail drafts on your behalf.
      You can revoke this access at any time from your Google account settings.
    </p>
    <div class="actions">
      <button type="button" class="secondary" onclick={onCancel}>Cancel</button>
      <button type="button" class="primary" onclick={onContinue}>Continue to Google</button>
    </div>
  </div>
</div>

<style>
  .backdrop {
    position: fixed; inset: 0;
    background: rgba(0,0,0,0.5);
    display: flex; align-items: center; justify-content: center;
    z-index: 100;
  }
  .modal {
    background: white; border-radius: 8px;
    max-width: 28rem; width: calc(100% - 2rem);
    padding: 1.5rem;
    box-shadow: 0 10px 30px rgba(0,0,0,0.3);
  }
  .modal h2 { margin-top: 0; }
  .steps { padding-left: 1.5rem; }
  .steps li { margin: 0.25rem 0; }
  .note { font-size: 0.85rem; color: #555; }
  .actions { display: flex; justify-content: flex-end; gap: 0.5rem; margin-top: 1rem; }
  .actions button {
    padding: 0.5rem 1rem; border-radius: 4px; border: 0; cursor: pointer; font-size: 0.95rem;
  }
  .primary { background: #1a73e8; color: white; }
  .secondary { background: #eee; color: #222; }
</style>
