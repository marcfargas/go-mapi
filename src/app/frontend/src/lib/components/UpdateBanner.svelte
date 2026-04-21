<!--
  UpdateBanner — persistent small update-available banner (Phase 11-03, D-01).

  Design:
  - Small and durable, not modal or noisy (D-01).
  - Only rendered when the backend reports `updateAvailable=true` (the
    caller — App.svelte — is responsible for that gate; this component
    is unconditionally visible when mounted).
  - Exposes a single "View update" action that opens the full panel.
    The panel owns both the release page and the installer link (D-02);
    the banner intentionally stays link-free so the container in
    App.svelte never has to decide which affordance is "primary".
  - Accessible as role="region" with an aria-label so tests and
    screen readers can address it reliably without relying on heading
    text — we intentionally render no heading to keep the footprint
    tight.
  - D-04 silent-failure rule: the banner never surfaces an error state
    for transient update-check failures. It just stays hidden until a
    successful fetch.
-->
<script lang="ts">
  interface Props {
    latestVersion: string;
    onViewUpdate: () => void;
  }
  let { latestVersion, onViewUpdate }: Props = $props();
</script>

<section class="banner" aria-label="Update available">
  <span class="msg">
    Update available — <strong>go-mapi {latestVersion}</strong>
  </span>
  <button type="button" class="view" onclick={onViewUpdate}>
    View update
  </button>
</section>

<style>
  .banner {
    background: var(--c-accent);
    color: white;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.4rem 1rem;
    gap: 1rem;
    font-size: 0.9rem;
  }
  .msg {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .view {
    background: white;
    color: var(--c-accent);
    border: 0;
    padding: 0.3rem 0.75rem;
    border-radius: 4px;
    font-weight: 600;
    cursor: pointer;
    font-size: 0.85rem;
  }
  .view:hover {
    background: #f0f0f0;
  }
</style>
