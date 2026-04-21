<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { EventsOn } from '../wailsjs/runtime/runtime';
  import { CreateDraftForID, DismissEmail } from '../wailsjs/go/main/App';
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
  import {
    fetchSettings,
    setMode as persistMode,
    getPausedState,
    subscribeAutoDraftResult,
    subscribePauseChanged,
    fetchUpdateState,
    checkForUpdatesNow,
    subscribeUpdateState,
    type Mode,
    type ErrorCategory,
    type AutoDraftResult,
    type UpdateState,
  } from './lib/settings';
  import SignInScreen from './lib/components/SignInScreen.svelte';
  import PreAuthModal from './lib/components/PreAuthModal.svelte';
  import ReAuthBanner from './lib/components/ReAuthBanner.svelte';
  import SignedInHeader from './lib/components/SignedInHeader.svelte';
  import QueueRow from './lib/components/QueueRow.svelte';
  import './lib/styles.css';

  // Existing state
  let queue = $state<EmailWithId[]>([]);
  let errorMsg = $state<string | null>(null);
  let auth = $state<AuthStatus>({ authenticated: false });
  let showPreAuthModal = $state(false);
  let showReAuthBanner = $state(false);
  let wasAuthenticated = false;

  // Phase 9 state
  let mode = $state<Mode>('manual');
  let paused = $state(false);
  let autoDraftErrors = $state(new Map<string, ErrorCategory>());
  let flashingIds = $state(new Set<string>());
  let inflightIds = $state(new Set<string>());

  // Phase 11-03 state — notify-only update UX (D-01/D-02/D-07/D-08).
  let updateState = $state<UpdateState | null>(null);
  let showUpdatePanel = $state(false);
  let bannerDismissedForVersion = $state<string | null>(null);

  // Collect all unsub functions for cleanup
  const unsubs: Array<() => void> = [];

  onMount(async () => {
    // Fetch initial state in parallel.
    const [initialAuth, initialQueue, initialSettings, initialPaused, initialUpdate] =
      await Promise.all([
        fetchAuthStatus(),
        fetchQueue().catch((e) => { errorMsg = (e as Error).message; return []; }),
        fetchSettings().catch(() => ({ mode: 'manual' as Mode })),
        getPausedState().catch(() => false),
        // D-04 silent-failure: never block startup on update hydration.
        fetchUpdateState().catch(() => null),
      ]);

    auth = initialAuth as AuthStatus;
    wasAuthenticated = auth.authenticated;
    queue = initialQueue as EmailWithId[];
    mode = ((initialSettings as { mode: string }).mode === 'auto-draft' ? 'auto-draft' : 'manual');
    paused = initialPaused as boolean;
    updateState = initialUpdate as UpdateState | null;

    // Subscribe to queue updates — prune stale state entries on each update.
    unsubs.push(subscribeQueue(
      (next) => {
        queue = next;
        // Reassign Maps/Sets to guarantee Svelte 5 detects the change when pruning.
        const ids = new Set(next.map((e) => e.id));
        const nextErrors = new Map(autoDraftErrors);
        let errChanged = false;
        for (const id of nextErrors.keys()) {
          if (!ids.has(id)) { nextErrors.delete(id); errChanged = true; }
        }
        if (errChanged) autoDraftErrors = nextErrors;

        const nextFlashing = new Set(flashingIds);
        let flashChanged = false;
        for (const id of nextFlashing) {
          if (!ids.has(id)) { nextFlashing.delete(id); flashChanged = true; }
        }
        if (flashChanged) flashingIds = nextFlashing;

        const nextInflight = new Set(inflightIds);
        let inflightChanged = false;
        for (const id of nextInflight) {
          if (!ids.has(id)) { nextInflight.delete(id); inflightChanged = true; }
        }
        if (inflightChanged) inflightIds = nextInflight;
      },
      (e) => { errorMsg = (e as Error)?.message ?? 'queue fetch failed'; },
    ));

    // Queue error events from Go
    unsubs.push(EventsOn('queue-error', (msg: string) => { errorMsg = msg; }));

    // Auth state changes — trigger re-auth banner on sign-out.
    unsubs.push(subscribeAuth((s) => {
      const becameSignedOut = wasAuthenticated && !s.authenticated;
      auth = s;
      if (becameSignedOut) {
        showReAuthBanner = true;
      } else if (s.authenticated) {
        showReAuthBanner = false;
      }
      wasAuthenticated = s.authenticated;
    }));

    // Auto-draft result (fires for both manual CreateDraftForID and automode).
    unsubs.push(subscribeAutoDraftResult((r: AutoDraftResult) => {
      // Reassign to guarantee Svelte 5 fine-grained reactivity detects the change.
      inflightIds = new Set([...inflightIds].filter((id) => id !== r.emailId));
      if (r.success) {
        const next = new Map(autoDraftErrors);
        next.delete(r.emailId);
        autoDraftErrors = next;
        // D-04: only flash in-window when visible + focused; Go fires toast when hidden.
        if (isWindowVisibleAndFocused()) {
          flashingIds = new Set([...flashingIds, r.emailId]);
          setTimeout(() => {
            flashingIds = new Set([...flashingIds].filter((id) => id !== r.emailId));
          }, 1600);
        }
      } else if (r.errorCategory) {
        const next = new Map(autoDraftErrors);
        next.set(r.emailId, r.errorCategory);
        autoDraftErrors = next;
      }
    }));

    // Pause state changes from Go (tray menu or PauseWatching/ResumeWatching calls).
    unsubs.push(subscribePauseChanged((p: boolean) => { paused = p; }));

    // Update state changes from Go (startup check, 24h scheduler, manual check).
    // Plan 11-01 guarantees one event per material state change.
    unsubs.push(subscribeUpdateState((s: UpdateState) => { updateState = s; }));
  });

  onDestroy(() => {
    for (const u of unsubs) u();
  });

  /** D-04: visible + focused proxy using web platform APIs supported by WebView2. */
  function isWindowVisibleAndFocused(): boolean {
    return document.visibilityState === 'visible' && document.hasFocus();
  }

  /** Compute per-row UI state from the three tracking sets/maps. */
  function rowStateFor(id: string): 'idle' | 'in-flight' | 'drafted-flash' | 'error' {
    if (flashingIds.has(id)) return 'drafted-flash';
    if (inflightIds.has(id)) return 'in-flight';
    if (autoDraftErrors.has(id)) return 'error';
    return 'idle';
  }

  /** Manual draft: put row in-flight, call binding; auto-draft-result event resolves state. */
  async function handleCreateDraft(id: string) {
    inflightIds = new Set([...inflightIds, id]);
    try {
      await CreateDraftForID(id);
      // auto-draft-result event will handle success/failure state update.
    } catch {
      // Binding threw (network/IPC error) — clear in-flight, show generic gmail error.
      inflightIds = new Set([...inflightIds].filter((x) => x !== id));
      const next = new Map(autoDraftErrors);
      next.set(id, 'gmail');
      autoDraftErrors = next;
    }
  }

  /** Dismiss: call binding; queue-update handles row removal. */
  async function handleDismiss(id: string) {
    try { await DismissEmail(id); } catch { /* ignore dismiss errors */ }
  }

  /** Mode toggle: persist then update local state. */
  async function handleModeChange(next: Mode) {
    await persistMode(next);
    mode = next;
  }

  // Auth flow handlers — unchanged from Phase 8.
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
    showReAuthBanner = false;
    await signIn();
  }

  async function handleSignOutClick() {
    await signOut();
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
    {mode}
    onModeChange={handleModeChange}
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
    <ul class="queue" aria-live="polite">
      {#each queue as item (item.id)}
        <QueueRow
          {item}
          state={rowStateFor(item.id)}
          authenticated={auth.authenticated}
          errorCategory={autoDraftErrors.get(item.id)}
          onCreateDraft={handleCreateDraft}
          onDismiss={handleDismiss}
        />
      {/each}
    </ul>
  {/if}
</main>

{#if showPreAuthModal}
  <PreAuthModal onContinue={handlePreAuthContinue} onCancel={handlePreAuthCancel} />
{/if}
