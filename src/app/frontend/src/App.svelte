<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { EventsOn } from '../wailsjs/runtime/runtime';
  import { CreateDraftForID, DismissEmail, GetAdminInstallState, GetComponentHealth, StartAdminRepair } from '../wailsjs/go/main/App';
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
    fetchSettingsState,
    saveSettings,
    fetchStartupState,
    setAutostartEnabled,
    openStartupSettings,
    setMode as persistMode,
    getPausedState,
    subscribeAutoDraftResult,
    subscribePauseChanged,
    fetchUpdateState,
    subscribeUpdateState,
    type Mode,
    type ErrorCategory,
    type AutoDraftResult,
    type UpdateState,
    type StartupState,
  } from './lib/settings';
  import SignInScreen from './lib/components/SignInScreen.svelte';
  import PreAuthModal from './lib/components/PreAuthModal.svelte';
  import ReAuthBanner from './lib/components/ReAuthBanner.svelte';
  import SignedInHeader from './lib/components/SignedInHeader.svelte';
  import QueueRow from './lib/components/QueueRow.svelte';
  import UpdateBanner from './lib/components/UpdateBanner.svelte';
  import UpdatePanel from './lib/components/UpdatePanel.svelte';
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
  // QUICK-260423-tk6: parallel map of raw Go error text per failed emailId.
  // Populated on auto-draft-result failure, cleared on success or queue prune.
  // Passed through to QueueRow → AutoDraftErrorBadge so the badge tooltip /
  // subtitle can show *why* the draft failed (not just the opaque category).
  let autoDraftReasons = $state(new Map<string, string>());
  let flashingIds = $state(new Set<string>());
  let inflightIds = $state(new Set<string>());

  // Phase 11-03 state — notify-only update UX (D-01/D-02/D-07/D-08).
  let updateState = $state<UpdateState | null>(null);
  let showUpdatePanel = $state(false);
  let bannerDismissedForVersion = $state<string | null>(null);

  type HealthIssue = {
    code: string;
    component: string;
    installedVersion?: string;
    required?: { minInclusive?: string; maxExclusive?: string };
    architectures?: string[];
    action: string;
    message: string;
  };
  type ComponentHealth = { healthy: boolean; issues: HealthIssue[] };
  type AdminInstallState = {
    phase: 'healthy' | 'offer' | 'preparing' | 'rechecking' | 'reboot-required' | 'failed';
    fingerprint?: string;
    errorCode?: string;
    message?: string;
    retryable: boolean;
  };
  let componentHealth = $state<ComponentHealth | null>(null);
  let adminInstallState = $state<AdminInstallState | null>(null);
  let settingsIssue = $state<{ kind: string; message: string; path: string } | null>(null);
  let startupState = $state<StartupState | null>(null);
  let preferencesOpen = $state(false);
  let startupReadError = $state<string | null>(null);
  let startupWriteError = $state<string | null>(null);
  let startupOpenError = $state<string | null>(null);
  let settingsRepairError = $state<string | null>(null);
  let startupPending = $state(false);
  let startupReadPending = $state(false);
  let settingsRepairPending = $state(false);
  const canFixStartup = $derived(
    !settingsIssue && !settingsRepairPending && !!startupState?.requested && !!startupState.warning &&
    (startupState.backend === 'standalone' && ['missing', 'mismatched', 'disabled', 'error'].includes(startupState.effective) ||
      startupState.backend === 'msix' && ['disabled', 'error'].includes(startupState.effective))
  );

  // Collect all unsub functions for cleanup
  const unsubs: Array<() => void> = [];

  onMount(async () => {
    // Fetch initial state in parallel.
    const [initialAuth, initialQueue, initialSettings, initialPaused, initialUpdate, initialHealth, initialAdminInstall, initialStartup] =
      await Promise.all([
        fetchAuthStatus(),
        fetchQueue().catch((e) => { errorMsg = (e as Error).message; return []; }),
        fetchSettingsState().catch(() => ({
          settings: { mode: '', autostart_enabled: true, default_apps_prompted: false, update_checks_enabled: true },
          issue: { kind: 'binding', message: 'Settings could not be loaded.', path: '%APPDATA%\\go-mapi\\settings.json' },
        })),
        getPausedState().catch(() => false),
        // D-04 silent-failure: never block startup on update hydration.
        fetchUpdateState().catch(() => null),
        GetComponentHealth().catch(() => null),
        GetAdminInstallState().catch(() => null),
        fetchStartupState().catch(() => null),
      ]);

    auth = initialAuth as AuthStatus;
    wasAuthenticated = auth.authenticated;
    queue = initialQueue as EmailWithId[];
    const loadedSettings = (initialSettings as {
      settings: { mode: string };
      issue?: { kind: string; message: string; path: string };
    });
    settingsIssue = loadedSettings.issue ?? null;
    mode = (loadedSettings.settings.mode === 'auto-draft' ? 'auto-draft' : 'manual');
    paused = initialPaused as boolean;
    updateState = initialUpdate as UpdateState | null;
    componentHealth = initialHealth as ComponentHealth | null;
    adminInstallState = initialAdminInstall as AdminInstallState | null;
    startupState = initialStartup as StartupState | null;
    if (!startupState) startupReadError = 'Windows startup state could not be read.';

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

        // Prune the tk6 reasons map in lockstep with autoDraftErrors.
        const nextReasons = new Map(autoDraftReasons);
        let reasonChanged = false;
        for (const id of nextReasons.keys()) {
          if (!ids.has(id)) { nextReasons.delete(id); reasonChanged = true; }
        }
        if (reasonChanged) autoDraftReasons = nextReasons;

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
        // Clear tk6 reason tracking on success too — the row will flash green
        // (if visible) then leave the queue on the next queue-update.
        const nextReasons = new Map(autoDraftReasons);
        if (nextReasons.delete(r.emailId)) autoDraftReasons = nextReasons;
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
        // QUICK-260423-tk6: stash raw reason so AutoDraftErrorBadge can show
        // it. Gracefully tolerate missing reason (older Go builds).
        if (r.reason) {
          const nextReasons = new Map(autoDraftReasons);
          nextReasons.set(r.emailId, r.reason);
          autoDraftReasons = nextReasons;
        }
      }
    }));

    // Pause state changes from Go (tray menu or PauseWatching/ResumeWatching calls).
    unsubs.push(subscribePauseChanged((p: boolean) => { paused = p; }));

    // Update state changes from Go (startup check, 24h scheduler, manual check).
    // Plan 11-01 guarantees one event per material state change.
    unsubs.push(subscribeUpdateState((s: UpdateState) => { updateState = s; }));
    unsubs.push(EventsOn('component-health-changed', (s: ComponentHealth) => { componentHealth = s; }));
    unsubs.push(EventsOn('admin-install-state-changed', (s: AdminInstallState) => { adminInstallState = s; }));
  });

  onDestroy(() => {
    for (const u of unsubs) u();
  });

  /** D-04: visible + focused proxy using web platform APIs supported by WebView2. */
  function isWindowVisibleAndFocused(): boolean {
    return document.visibilityState === 'visible' && document.hasFocus();
  }

  async function handleAdminRepair() {
    try {
      await StartAdminRepair();
    } catch {
      // Rehydrate if a validation failure arrived before the event listener.
      adminInstallState = await GetAdminInstallState().catch(() => adminInstallState);
    }
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

  async function repairSettingsAsManual() {
    if (!settingsIssue || settingsRepairPending || startupPending || startupReadPending) return;
    settingsRepairPending = true;
    settingsRepairError = null;
    try {
      await saveSettings({
        mode: 'manual',
        autostart_enabled: true,
        default_apps_prompted: false,
        update_checks_enabled: true,
      });
      mode = 'manual';
      settingsIssue = null;
      startupState = null;
      await readStartupState();
    } catch (error) {
      settingsRepairError = `Settings repair failed: ${String(error)}`;
    } finally {
      settingsRepairPending = false;
    }
  }

  async function readStartupState() {
    if (startupReadPending) return;
    startupReadPending = true;
    try {
      startupState = await fetchStartupState();
      startupReadError = null;
    } catch {
      startupState = null;
      startupReadError = 'Windows startup state could not be read.';
    } finally {
      startupReadPending = false;
    }
  }

  async function writeStartup(enabled: boolean) {
    if (settingsIssue || settingsRepairPending || startupReadPending || startupPending || !startupState) return;
    startupPending = true;
    try {
      startupState = await setAutostartEnabled(enabled);
      startupWriteError = null;
    } catch (error) {
      startupWriteError = `Startup preference could not be saved: ${String(error)}`;
    } finally {
      startupPending = false;
    }
  }

  function handleAutostartChange(event: Event) {
    const checkbox = event.currentTarget as HTMLInputElement;
    const enabled = checkbox.checked;
    checkbox.checked = startupState?.requested ?? false;
    void writeStartup(enabled);
  }

  async function openStartupApps() {
    try {
      await openStartupSettings();
      startupOpenError = null;
    } catch (error) {
      startupOpenError = `Startup Apps could not be opened: ${String(error)}`;
    }
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

  /** Phase 11-03: open the update panel from the banner (D-01 → D-02). */
  function handleOpenUpdatePanel() {
    showUpdatePanel = true;
  }

  /** Phase 11-03: close the panel without dismissing the banner — the
   *  banner stays until a newer version actually ships. bannerDismissedForVersion
   *  is reserved for an optional future "hide until next release" dismissal
   *  flow; we keep it inert this phase to avoid suppressing legitimate
   *  upgrade prompts. */
  function handleCloseUpdatePanel() {
    showUpdatePanel = false;
    // bannerDismissedForVersion intentionally not updated here (D-01: banner
    // remains persistent across panel open/close cycles).
    void bannerDismissedForVersion; // silence "assigned but never read" without removing the state field
  }
</script>

{#if componentHealth && componentHealth.issues.length > 0}
  <section class="component-health" role="alert" aria-label="Component compatibility">
    <h2>go-mapi needs attention</h2>
    {#each componentHealth.issues as issue}
      <article class="component-health__issue">
        <strong>{issue.message}</strong>
        <span>
          {#if issue.installedVersion}Installed: {issue.installedVersion}. {/if}
          {#if issue.required?.minInclusive}Required: {issue.required.minInclusive}{#if issue.required.maxExclusive}–{issue.required.maxExclusive}{/if}. {/if}
          Action: {issue.action}.
        </span>
      </article>
    {/each}
  </section>
{/if}

{#if adminInstallState && adminInstallState.phase !== 'healthy'}
  <section class="component-health" role="alert" aria-label="Admin component installation">
    <h2>Install or repair the go-mapi interceptor</h2>
    {#if adminInstallState.phase === 'offer'}
      <p>The machine-wide interceptor needs administrator approval. go-mapi will verify a trusted installer before Windows asks for approval.</p>
      <button type="button" onclick={handleAdminRepair}>Install or repair interceptor</button>
    {:else if adminInstallState.phase === 'preparing' || adminInstallState.phase === 'rechecking'}
      <p>Preparing the verified interceptor installation. Keep go-mapi open while Windows completes the check.</p>
      <button type="button" disabled>Installing interceptor…</button>
    {:else if adminInstallState.phase === 'reboot-required'}
      <p>{adminInstallState.message ?? 'Restart Windows, then open go-mapi again to verify the interceptor.'}</p>
    {:else}
      <p>{adminInstallState.message ?? 'The interceptor could not be installed.'}</p>
      {#if adminInstallState.retryable}
        <button type="button" onclick={handleAdminRepair}>Try again</button>
      {/if}
    {/if}
  </section>
{/if}

{#if settingsIssue}
  <section class="component-health" role="alert" aria-label="Invalid settings">
    <h2>Settings need repair</h2>
    <p>{settingsIssue.message}</p>
    <p><code>{settingsIssue.path}</code></p>
    {#if settingsRepairError}<p>{settingsRepairError}</p>{/if}
    <button type="button" onclick={repairSettingsAsManual} disabled={settingsRepairPending}>Repair and use manual mode</button>
  </section>
{/if}

<details class="email-guidance">
  <summary>Email with Send To</summary>
  <p>Use Windows “Send to → Mail recipient” or an app that supports Simple MAPI to create Gmail drafts. You need the go-mapi system component and the running go-mapi app, signed in to Gmail. A suite installation includes both; installing only the user app does not install the system component. If the system component is missing or incompatible, use the installation or repair guidance shown in this app. go-mapi does not currently handle mailto links and does not register a MAILTO handler in Windows Default Apps. Drafts are never sent automatically.</p>
</details>

<section class="startup-preferences" aria-label="Startup preferences">
  <button type="button" class="startup-preferences__toggle" aria-expanded={preferencesOpen} aria-controls="startup-preferences-content" onclick={() => { preferencesOpen = !preferencesOpen; }}>Preferences</button>
  <div id="startup-preferences-content">
    {#if preferencesOpen}
      {#if startupState}
        <label>
          <input type="checkbox" checked={startupState.requested} disabled={!!settingsIssue || settingsRepairPending || startupReadPending || startupPending} onchange={handleAutostartChange} />
          Start go-mapi when I sign in
        </label>
        <p>Windows status: {startupState.effective} ({startupState.backend})</p>
      {:else}
        <p>Startup status is unavailable. Editing is paused until it can be read.</p>
      {/if}
      {#if settingsIssue || settingsRepairPending}<p>Repair settings before changing startup preferences.</p>{/if}
    {/if}
  </div>
</section>

{#if startupState?.warning || startupReadError || startupWriteError || startupOpenError}
  <section class="component-health" role="alert" aria-label="Startup warning">
    <h2>Startup needs attention</h2>
    {#if startupState?.warning}<p>{startupState.warning}</p>{/if}
    {#if startupReadError}<p>{startupReadError}</p>{/if}
    {#if startupWriteError}<p>{startupWriteError}</p>{/if}
    {#if startupOpenError}<p>{startupOpenError}</p>{/if}
    {#if settingsIssue || settingsRepairPending}
      <p>Repair settings first, then review startup status.</p>
    {:else if startupState?.warning && !startupState.requested}
      <p>Startup is off by your choice. Review Preferences or Windows Startup Apps to resolve this warning.</p>
    {/if}
    {#if canFixStartup}<button type="button" onclick={() => { void writeStartup(true); }} disabled={startupPending}>Fix startup</button>{/if}
    {#if startupReadError}<button type="button" onclick={() => { void readStartupState(); }} disabled={startupReadPending || settingsRepairPending}>Retry startup status</button>{/if}
    <button type="button" onclick={openStartupApps}>Open Startup Apps</button>
  </section>
{/if}

{#if updateState && (updateState.updateAvailable || updateState.interceptorUpdateAvailable)}
  <UpdateBanner
    latestVersion={updateState.updateAvailable ? updateState.latestVersion : updateState.interceptorLatestVersion || 'new version'}
    component={updateState.updateAvailable ? 'app' : 'system'}
    onViewUpdate={handleOpenUpdatePanel}
  />
{/if}

{#if showReAuthBanner}
  <ReAuthBanner onRestore={handleReAuthClick} />
{/if}

{#if auth.authenticated && !settingsIssue}
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
      <p>go-mapi can't watch %LOCALAPPDATA%\go-mapi\queue\. Restart the app, or check app.log for details.</p>
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
          errorReason={autoDraftReasons.get(item.id)}
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

{#if showUpdatePanel && updateState}
  <UpdatePanel update={updateState} componentsHealthy={componentHealth?.healthy ?? null} onClose={handleCloseUpdatePanel} />
{/if}
