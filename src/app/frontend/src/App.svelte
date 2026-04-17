<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { EventsOn } from '../wailsjs/runtime/runtime';
  import { subscribeQueue, fetchQueue, type EmailWithId } from './lib/queue';
  import {
    fetchAuthStatus,
    subscribeAuth,
    signIn,
    signOut,
    hasSeenPreAuthExplainer,
    markPreAuthExplainerSeen,
    type AuthStatus,
  } from './lib/auth';
  import SignInScreen from './lib/components/SignInScreen.svelte';
  import PreAuthModal from './lib/components/PreAuthModal.svelte';
  import ReAuthBanner from './lib/components/ReAuthBanner.svelte';
  import SignedInHeader from './lib/components/SignedInHeader.svelte';
  import './lib/styles.css';

  let queue = $state<EmailWithId[]>([]);
  let errorMsg = $state<string | null>(null);
  let auth = $state<AuthStatus>({ authenticated: false });
  let showPreAuthModal = $state(false);
  let showReAuthBanner = $state(false);
  let wasAuthenticated = false; // tracks previous state to trigger banner on transition

  let unsubQueue: (() => void) | null = null;
  let unsubQueueError: (() => void) | null = null;
  let unsubAuth: (() => void) | null = null;

  onMount(async () => {
    // Fetch initial state in parallel.
    const [initialAuth, initialQueue] = await Promise.all([
      fetchAuthStatus(),
      fetchQueue().catch((e) => { errorMsg = (e as Error).message; return []; }),
    ]);
    auth = initialAuth;
    wasAuthenticated = auth.authenticated;
    queue = initialQueue as EmailWithId[];

    unsubQueue = subscribeQueue((next) => { queue = next; });
    unsubQueueError = EventsOn('queue-error', (msg: string) => { errorMsg = msg; });
    unsubAuth = subscribeAuth((s) => {
      const becameSignedOut = wasAuthenticated && !s.authenticated;
      auth = s;
      if (becameSignedOut) {
        showReAuthBanner = true;
      } else if (s.authenticated) {
        showReAuthBanner = false;
      }
      wasAuthenticated = s.authenticated;
    });
  });

  onDestroy(() => {
    unsubQueue?.();
    unsubQueueError?.();
    unsubAuth?.();
  });

  async function handleSignInClick() {
    if (!hasSeenPreAuthExplainer()) {
      showPreAuthModal = true;
      return;
    }
    await signIn();
  }

  async function handlePreAuthContinue() {
    markPreAuthExplainerSeen();
    showPreAuthModal = false;
    await signIn();
  }

  function handlePreAuthCancel() {
    showPreAuthModal = false;
  }

  async function handleReAuthClick() {
    // D-06: re-auth skips the pre-auth modal (user has already seen it).
    showReAuthBanner = false;
    await signIn();
  }

  async function handleSignOutClick() {
    await signOut();
  }

  function formatTimestamp(iso: string): string {
    const d = new Date(iso);
    const now = new Date();
    const sameDay = d.toDateString() === now.toDateString();
    if (sameDay) return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
    return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  }
</script>

{#if showReAuthBanner}
  <ReAuthBanner onRestore={handleReAuthClick} />
{/if}

{#if auth.authenticated}
  <SignedInHeader
    email={auth.email ?? ''}
    name={auth.name ?? ''}
    onSignOut={handleSignOutClick}
  />
{/if}

<main>
  {#if !auth.authenticated}
    <SignInScreen onSignIn={handleSignInClick} />
  {:else if errorMsg}
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
          <span class="sender">{item.message?.from?.address ?? '(unknown sender)'}</span>
          <span class="subject">{item.message?.subject ?? '(no subject)'}</span>
          <span class="meta">{item.message ? formatTimestamp(item.message.timestamp) : ''}</span>
        </li>
      {/each}
    </ul>
  {/if}
</main>

{#if showPreAuthModal}
  <PreAuthModal onContinue={handlePreAuthContinue} onCancel={handlePreAuthCancel} />
{/if}
