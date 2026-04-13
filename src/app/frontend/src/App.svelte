<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { subscribeQueue, fetchQueue, type EmailWithId } from './lib/queue';
  import './lib/styles.css';

  let queue = $state<EmailWithId[]>([]);
  let errorMsg = $state<string | null>(null);
  let unsub: (() => void) | null = null;

  onMount(async () => {
    try {
      queue = await fetchQueue();
      unsub = subscribeQueue((next) => { queue = next; });
    } catch (e) {
      errorMsg = (e as Error).message;
    }
  });

  onDestroy(() => unsub?.());

  function formatTimestamp(iso: string): string {
    const d = new Date(iso);
    const now = new Date();
    const sameDay = d.toDateString() === now.toDateString();
    if (sameDay) return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
    return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  }
</script>

<main>
  {#if errorMsg}
    <section class="state state--error">
      <h2>Watcher stopped</h2>
      <p>go-mapi can't watch %TEMP%\go-mapi\. Restart the app, or check app.log for details.</p>
    </section>
  {:else if queue.length === 0}
    <section class="state state--empty">
      <h2>No emails waiting</h2>
      <p>When a Windows app sends to mail, it will appear here.</p>
    </section>
  {:else}
    <ul class="queue">
      {#each queue as item (item.id)}
        <li class="queue-row" tabindex="0">
          <span class="sender">{item.message.from?.address ?? '(unknown sender)'}</span>
          <span class="subject">{item.message.subject ?? '(no subject)'}</span>
          <span class="meta">{formatTimestamp(item.message.timestamp)}</span>
        </li>
      {/each}
    </ul>
  {/if}
</main>
