<!--
  UpdatePanel — in-app update panel (Phase 11-03, D-02/D-07/D-08).

  Design:
  - Opened from UpdateBanner "View update" action in the root shell.
  - Invokes the Go update action binding. The backend keeps the validated
    browser or Store candidate and opens it through the system shell.
  - Shows current version and last checked timestamp (D-07).
  - Includes exactly one "update checks are enabled by default" callout
    (D-08). This is the only place that callout appears in the UI so
    the frontend does not accidentally render it in multiple spots.
  - Manual "Check for updates now" action (D-06 tie-in) forwards to the
    lib/settings.ts wrapper that hides Wails' context auto-injection.
  - Modal presentation over a backdrop, matching PreAuthModal's pattern
    so the panel is dismissible with Close and does not require a
    dedicated route/settings page (phase D-05 keeps it lightweight).
  - D-04 silent-failure rule: the manual check wrapper swallows errors;
    we never render a red "check failed" state from the UI.
  - Channel guidance is explicit; no staged installer helper.
-->
<script lang="ts">
  import { OpenUpdateAction } from '../../../wailsjs/go/main/App';
  import { checkForUpdatesNow, type UpdateState } from '../settings';

  interface Props {
    update: UpdateState;
    componentsHealthy?: boolean | null;
    onClose: () => void;
  }
  // Note: the prop is named `update` (not `state`) because Svelte 5 runes
  // mode treats `state` as a reserved identifier in reactive contexts; a
  // prop destructured as `state` collides with the `$state` rune and the
  // compiler raises `store_invalid_shape` at runtime.
  let { update, componentsHealthy = null, onClose }: Props = $props();

  let checking = $state(false);

  /** Render the last-checked timestamp in a user-friendly form. */
  const lastCheckedLabel = $derived(formatLastChecked(update.lastCheckedAt));

  function formatLastChecked(iso: string): string {
    if (!iso) return 'never';
    try {
      const d = new Date(iso);
      if (Number.isNaN(d.getTime())) return iso;
      return d.toLocaleString();
    } catch {
      return iso;
    }
  }

  function openUpdateAction() {
    if (update.updateActionUrl && update.updateAvailable) void OpenUpdateAction();
  }

  async function handleCheckNow() {
    if (checking) return;
    checking = true;
    try {
      // D-04: wrapper already swallows failures; backend logs them.
      await checkForUpdatesNow();
    } finally {
      checking = false;
    }
  }
</script>

<div class="backdrop" role="dialog" aria-modal="true" aria-labelledby="update-panel-title">
  <div class="panel">
    <header>
      <h2 id="update-panel-title">
        {#if update.updateGuidance}
          Update guidance
        {:else if update.updateAvailable}
          Update available
        {:else if update.interceptorUpdateAvailable}
          System component update available
        {:else if update.lastSuccessfulAt}
          No update available
        {:else}
          Update status unavailable
        {/if}
      </h2>
      <button type="button" class="close" aria-label="Close" onclick={onClose}>×</button>
    </header>

    <section class="body">
      {#if update.updateGuidance}
        <p class="lede">{update.updateGuidance}</p>
      {:else if update.updateAvailable}
        <p class="lede">
          A newer release is available:
          <strong>go-mapi {update.latestVersion}</strong>.
        </p>
        {#if update.distributionChannel === 'store'}
          <p>Use Microsoft Store to update this installation.</p>
        {:else}
          <p>Open the download page and start the installer when you're ready.</p>
        {/if}
        {#if update.updateActionUrl}
        <div class="actions">
          <button
            type="button"
            class="primary link"
            onclick={openUpdateAction}
          >
            {update.updateActionLabel || 'Open update channel'}
          </button>
        </div>
        {/if}
      {:else if update.interceptorUpdateAvailable}
        <p class="lede">A newer go-mapi system component is available{update.interceptorLatestVersion ? ` (${update.interceptorLatestVersion})` : ''}.</p>
        <p>Ask your administrator to install the system component update. Compatibility and repair guidance remains available in the main window.</p>
      {:else if update.lastSuccessfulAt}
        <p class="lede">
          No newer app release was reported at the last successful check.
        </p>
      {:else}
        <p class="lede">No verified update result is available yet.</p>
      {/if}

      <dl class="status">
        <dt>Current version</dt>
        <dd>{update.currentVersion || 'unknown'}</dd>
        <dt>Last checked</dt>
        <dd>{lastCheckedLabel}</dd>
        <dt>Interceptor</dt>
        <dd>
          {#if update.managedSystemUpdate}
            Managed automatically by the machine service
          {:else if update.distributionChannel === 'machine' || update.distributionChannel === 'unknown'}
            Ask your administrator
          {:else if update.interceptorUpdateAvailable}
            Update available{update.interceptorLatestVersion ? ` (${update.interceptorLatestVersion})` : ''}
          {:else if !update.lastSuccessfulAt}
            Not checked
          {:else}
            {update.interceptorLatestVersion || 'No update reported'}
          {/if}
        </dd>
        <dt>Installed components</dt>
        <dd>
          {#if componentsHealthy === true}
            Healthy
          {:else if componentsHealthy === false}
            Need attention — see the main window
          {:else}
            Status unavailable
          {/if}
        </dd>
      </dl>

      {#if update.distributionChannel !== 'machine' && update.distributionChannel !== 'unknown'}
      <p class="default-note">
        Background update checks are <strong>enabled by default</strong>.
        You can turn them off from the tray menu.
      </p>
      {/if}

      {#if update.distributionChannel !== 'machine' && update.distributionChannel !== 'unknown'}
      <div class="manual">
        <button
          type="button"
          class="check"
          onclick={handleCheckNow}
          disabled={checking}
        >
          {checking ? 'Checking…' : 'Check for updates now'}
        </button>
      </div>
      {/if}
    </section>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 90;
  }
  .panel {
    background: white;
    border-radius: 8px;
    max-width: 32rem;
    width: calc(100% - 2rem);
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.3);
    overflow: hidden;
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.75rem 1rem;
    border-bottom: 1px solid var(--c-border);
  }
  header h2 {
    margin: 0;
    font-size: 1.05rem;
  }
  .close {
    background: transparent;
    border: 0;
    font-size: 1.5rem;
    line-height: 1;
    cursor: pointer;
    color: var(--c-text);
    padding: 0 0.25rem;
  }
  .body {
    padding: 1rem;
  }
  .lede {
    margin-top: 0;
  }
  .actions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    margin: 0.5rem 0 1rem;
  }
  .link {
    padding: 0.5rem 0.85rem;
    border-radius: 4px;
    border: 0;
    cursor: pointer;
    font-size: 0.9rem;
  }
  .primary {
    background: var(--c-accent);
    color: white;
  }
  .status {
    display: grid;
    grid-template-columns: max-content 1fr;
    gap: 0.25rem 1rem;
    margin: 0.75rem 0 1rem;
    font-size: 0.9rem;
  }
  .status dt {
    font-weight: 600;
    color: #555;
  }
  .status dd {
    margin: 0;
  }
  .default-note {
    font-size: 0.85rem;
    color: #555;
    border-left: 3px solid var(--c-accent);
    padding: 0.25rem 0.75rem;
    background: #f7f9fc;
    border-radius: 2px;
  }
  .manual {
    display: flex;
    justify-content: flex-end;
    margin-top: 0.75rem;
  }
  .check {
    background: transparent;
    border: 1px solid var(--c-border);
    padding: 0.4rem 0.85rem;
    border-radius: 4px;
    cursor: pointer;
    font-size: 0.9rem;
  }
  .check:disabled {
    opacity: 0.6;
    cursor: default;
  }
</style>
