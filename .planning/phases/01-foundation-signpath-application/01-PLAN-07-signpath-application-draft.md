---
phase: 01-foundation-signpath-application
plan: 07
type: execute
wave: 1
depends_on: []
files_modified:
  - .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md
autonomous: true
requirements: [SIGN-01]

must_haves:
  truths:
    - "A SIGNPATH-APPLICATION.md file exists in the phase directory containing the full text Marc will paste into the SignPath Foundation OSS application form"
    - "The draft emphasizes defensive framing: MAPI handler replacement is a standard Windows mechanism, not interception, and requires explicit user consent via UAC"
    - "The draft clearly marks the Chrome Web Store listing URL as a placeholder to be filled in before submission (Marc decides whether to wait for CWS publication or file with a placeholder)"
    - "The draft states LGPL-3.0 licensing, privacy-by-design posture (no telemetry, no persistence), Gmail-only draft creation (no SMTP send), and links to the public repo and Marc's GitHub profile"
  artifacts:
    - path: ".planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md"
      provides: "The full application text ready to paste into SignPath Foundation's OSS program form"
      contains: "SignPath"
  key_links:
    - from: "SIGNPATH-APPLICATION.md"
      to: "https://signpath.org/foundation"
      via: "documented submission URL in the draft header"
      pattern: "signpath"
---

<objective>
Draft the full text of the SignPath Foundation OSS program application for go-mapi. The draft lives in the phase planning directory (not the repo tree, so it does not ship in the installer or public releases) and contains everything Marc needs to paste into SignPath's application form. Phase 1 completes when the draft exists AND Marc confirms during Plan 08's human verification that he has filed the application.

Purpose: Unblocks SIGN-02 weeks later in Phase 3 (actual code signing). SignPath Foundation OSS approval can take weeks, so the application must be filed as the first async action in Phase 1 to start the clock.
Output: A markdown file at `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` containing the complete application text.
</objective>

<execution_context>
This plan implements SIGN-01 from REQUIREMENTS.md. Decisions are locked in `01-CONTEXT.md` section `### SIGN-01 (SignPath application — draft-only in this phase)`:

- **Claude drafts, Marc files.** Phase 1 completes when (a) draft text exists AND (b) Marc confirms "filed" during Plan 08's human verification.
- **Draft location:** `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` (out of the repo tree so it does not ship in the installer; in planning for traceability)
- **Draft contents** (locked in CONTEXT.md): project name, LGPL-3.0 license, short MAPI-interception behavior explanation (defensive wording emphasizing user consent via registry handler registration, privacy-by-design, no telemetry, FOSS), link to Chrome Web Store listing if live (placeholder text if not), Marc's GitHub username, link to the public repo.
- **Known risk:** Chrome Web Store listing may not exist when Marc files. Draft includes a clearly marked placeholder; Marc decides whether to file with placeholder or wait for CWS publication. Phase 1 does not block on the listing being live.
- **Out of scope:** actually creating the CWS listing, paying fees, setting up SignPath org pages, responding to reviewer follow-ups.

**Tone guidance from CONTEXT.md specifics:** "Defensive and factual. Emphasize (a) MAPI handler is registered with explicit user consent via the installer's UAC prompt, (b) no telemetry or persistence, (c) LGPL-3.0 public source, (d) Gmail-only draft creation — no SMTP send. SignPath reviewers have historically pushed back on anything that sounds like 'interception' in a security-sensitive context; frame as 'standard MAPI handler replacement that any Mail client registration does.'"

**Important:** Per the user's confidentiality rule (global CLAUDE.md), the draft must NOT reference any of Marc's companies, firm, or group directly. This is a public-facing application to an external foundation. Marc is the sole author. The draft represents Marc individually, not any employer.

**License verification:** Per `verify-before-assuming`, I confirmed `package.json` declares `GPL-3.0-only` but `README.md` says "License TBD". The `CLAUDE.md` project file says "LGPL-3.0 (Marc's default for FOSS projects)". CONTEXT.md also locks LGPL-3.0. There is a known tech debt item in `.planning/codebase/CONCERNS.md` flagging the package.json/README discrepancy as requiring resolution. The draft states LGPL-3.0 per CONTEXT.md, AND the draft includes a note flagging that the repo's license metadata needs to be aligned with LGPL-3.0 before submission. This alignment is NOT part of this plan's scope — it is flagged for Marc to address before filing.
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/phases/01-foundation-signpath-application/01-CONTEXT.md
@.planning/codebase/CONCERNS.md
@CLAUDE.md
@README.md
@package.json
</context>

<tasks>

<task type="auto" tdd="false">
  <name>Task 1: Draft SIGNPATH-APPLICATION.md with defensive framing and all required fields</name>
  <files>.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md</files>
  <read_first>
    - .planning/phases/01-foundation-signpath-application/01-CONTEXT.md (re-read the SIGN-01 section, specifics section, and deferred section)
    - CLAUDE.md (project file — note the "Core Value" statement and constraints around privacy, licensing, and distribution)
    - README.md (understand what the public repo currently describes about go-mapi so the application does not contradict the README)
    - package.json (confirm the declared license and description)
    - .planning/codebase/CONCERNS.md lines 7-11 (the license ambiguity concern — flag in the draft that this must be resolved before filing)
  </read_first>
  <action>
    Create `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` containing the full application text. Structure the file in sections so Marc can copy-paste the relevant parts into SignPath's web form fields. The file must contain, in order:

    **Section 1 — Header / Meta (for Marc's reference, not for pasting):**
    - Title: "SignPath Foundation OSS Application — go-mapi"
    - Status: "DRAFT — not yet filed"
    - Drafted by: "Claude (per /gsd-execute-phase 1)"
    - Drafted on: (today's date)
    - Filing URL: `https://signpath.org/apply` (Marc should verify this is still the current URL before filing)
    - A checklist for Marc to complete before filing:
      - Resolve the LGPL-3.0 vs GPL-3.0-only discrepancy between package.json and README.md (CONCERNS.md tech debt item)
      - Decide whether to file before or after Chrome Web Store listing is live
      - Confirm GitHub repo is public
      - Verify the filing URL is still https://signpath.org/apply (or wherever SignPath directs OSS applicants)

    **Section 2 — Project Identity (for pasting into form fields):**
    - Project name: `go-mapi`
    - Project homepage / repository URL: `https://github.com/marcfargas/go-mapi`
    - Primary contact: Marc Fargas (GitHub: marcfargas)
    - License: LGPL-3.0-or-later (per Marc's project convention; note that the repository's license metadata is being aligned from the currently-declared GPL-3.0-only to LGPL-3.0 before filing)
    - Project description (one sentence): "go-mapi is a Free Software bridge that lets Windows users route the system 'Send to Mail recipient' action to Gmail as drafts, replacing the Outlook requirement for legacy desktop applications."

    **Section 3 — Why We Need Code Signing (for pasting into the 'purpose' form field):**
    A one-to-two paragraph explanation of why an OSS project needs Authenticode signing. Write this plainly: unsigned Windows binaries trigger SmartScreen warnings that block non-technical users from installing go-mapi; code signing via SignPath Foundation lets the project ship a signed .exe installer and a signed MAPI handler DLL so end users see a trustworthy publisher identity and can install without clicking through warning dialogs. Note that go-mapi explicitly targets non-technical Windows users (per the project's "Core Value" statement in CLAUDE.md), which makes the SmartScreen friction a distribution blocker rather than a minor inconvenience.

    **Section 4 — What the Binaries Do (the defensive framing — MOST IMPORTANT):**
    This is the section SignPath reviewers will scrutinize. Frame go-mapi using the exact defensive language from CONTEXT.md:

    Paragraph 1 — What it does:
    "go-mapi registers itself as a Mail client handler under `HKLM\\SOFTWARE\\Clients\\Mail\\go-mapi`, a standard Windows registration that any Mail client (Outlook, Thunderbird, Mailbird, Windows Mail) uses to register as an available recipient for the 'Send to Mail recipient' shell action. When a Win32 application invokes the MAPI `MAPISendMail` / `MAPISendMailW` functions exported by the system `mapi32.dll`, Windows routes the call to the registered handler — the standard MAPI extensibility mechanism documented in the Windows Platform SDK. go-mapi's handler DLL receives the MAPI call, serializes the message to a local JSON file, and a native messaging host process forwards it to a Chrome/Edge browser extension which presents it to the user as a Gmail draft preview. No email is ever sent automatically — the user must explicitly click 'Save as Draft' in the Gmail UI."

    Paragraph 2 — Installation and user consent:
    "Installation is performed by an Inno Setup installer that requires a single UAC elevation prompt. During installation, the user is informed that go-mapi will become the default Mail client handler, and the installer backs up the previous default (if any) so uninstall can restore it. There is no silent installation, no background service, no auto-start, and no mechanism by which go-mapi can be installed without explicit user action. Uninstall removes all registry entries, all files, and restores the previous default Mail client from the backup file."

    Paragraph 3 — Privacy posture:
    "go-mapi is privacy-first by design: (a) no telemetry of any kind, (b) no long-term storage of message content — intercepted messages are written to `%TEMP%\\go-mapi\\` as transient JSON files and deleted immediately after the user clicks 'Save as Draft' or 'Delete', (c) no network calls except to the Gmail API on behalf of the signed-in user for draft creation, (d) no logging of message content (only metadata like message IDs truncated to 8 hex chars), (e) no crash reporting, (f) no update check beacons. The project's Privacy rules are documented in the public CLAUDE.md file in the repository."

    Paragraph 4 — Scope limitation:
    "go-mapi only creates Gmail drafts. It does not send email directly, does not support SMTP, does not support POP3/IMAP, and does not support any provider other than Gmail. This is an explicit scope decision — sending is always mediated by the Gmail web UI so the user has final review of every message before it leaves their account."

    **Section 5 — Why MAPI Handler Replacement is Not Interception (direct reviewer pushback defense):**
    A short paragraph directly addressing the predictable reviewer concern. Quote CONTEXT.md's framing: "This is the standard Mail client registration mechanism that Outlook, Thunderbird, Windows Mail, and every other Mail client on Windows uses. go-mapi is not intercepting anything — it is registering itself as a Mail client handler, identically to how any other Mail client does. The user chooses to make go-mapi their default Mail client during installation; Windows then routes MAPI calls to it per the standard documented extensibility model. There is no hooking, no DLL injection, no process attachment, no memory patching. go-mapi is a legitimate Mail client registration, signed-by-user-consent, that happens to forward messages to a web email service instead of sending them via SMTP."

    **Section 6 — Source Code and Build Reproducibility:**
    - Repository: `https://github.com/marcfargas/go-mapi`
    - Build system: Go 1.21 for the native messaging host, MinGW + CMake for the MAPI handler DLL, TypeScript + Vite for the browser extension
    - CI: GitHub Actions (public logs) will build, test, and sign releases
    - Source language mix: Go (native host), C++17 (interceptor DLL), TypeScript (extension UI)
    - The project follows reproducible build practices where practical for the toolchain

    **Section 7 — Links:**
    - Repository: `https://github.com/marcfargas/go-mapi`
    - Maintainer GitHub profile: `https://github.com/marcfargas`
    - License text: `https://github.com/marcfargas/go-mapi/blob/main/LICENSE` (flag in the draft that Marc must confirm this file exists and contains LGPL-3.0 before filing)
    - Chrome Web Store listing: **PLACEHOLDER** — Marc decides whether to file with a "listing pending" note or wait until the CWS listing is live. Mark this prominently with a clear TODO marker so Marc does not miss it.
    - Public issue tracker: `https://github.com/marcfargas/go-mapi/issues`
    - CLAUDE.md in the repo documenting the privacy-first posture and project scope

    **Section 8 — Pre-Filing Checklist (Marc's action items before filing):**
    Repeat the checklist from Section 1 here as the final section so Marc does not miss it:
    - [ ] Resolve the LGPL-3.0 vs GPL-3.0-only discrepancy (update package.json and README.md to LGPL-3.0, add a LICENSE file containing the full LGPL-3.0 text)
    - [ ] Decide: file now with "CWS listing pending" or wait until the Chrome Web Store listing is published
    - [ ] Confirm the GitHub repository is public and the README is up to date
    - [ ] Verify the filing URL (https://signpath.org/apply) is still current
    - [ ] Verify that SignPath Foundation still accepts individual maintainers (vs organization-only)
    - [ ] Confirm no confidential material (employer names, client names, internal tooling references) appears in the application text (the draft deliberately avoids all of this per the global confidentiality rule)

    **Style notes:**
    - Write in plain, factual English. No marketing language, no adjectives like "innovative" or "cutting-edge".
    - Avoid any word that sounds like "intercept" or "hook" in the reviewer-facing sections. Use "handle", "receive", "register" instead.
    - Do NOT reference any of Marc's companies, firms, or groups — per global confidentiality rule. The draft represents Marc as an individual open-source maintainer.
    - Use full URLs, not markdown shortcuts, in sections meant for copy-paste into form fields (SignPath's form may strip markdown).
    - Keep each form-field section under 2000 characters so it fits typical form input limits.
  </action>
  <verify>
    <automated>test -f .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md && wc -l .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md</automated>
  </verify>
  <acceptance_criteria>
    - File `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` exists
    - Contains a prominent DRAFT status marker (grep: `grep -n "DRAFT" .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` returns at least 1 match)
    - Contains all 8 sections listed in the action above (grep for each section title: "Project Identity", "Why We Need Code Signing", "What the Binaries Do", "Why MAPI Handler Replacement is Not Interception", "Source Code", "Links", "Pre-Filing Checklist" — each returns at least 1 match)
    - Mentions LGPL-3.0 explicitly (grep: `grep -c "LGPL-3.0" .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` returns at least 2 matches)
    - Mentions the license ambiguity to resolve before filing (grep: `grep -n "GPL-3.0-only\|discrepancy\|ambiguity" .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` returns at least 1 match)
    - Contains a clearly-marked PLACEHOLDER for the Chrome Web Store listing URL (grep: `grep -n "PLACEHOLDER\|TODO" .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` returns at least 2 matches — one for CWS listing, optionally others)
    - Does NOT contain any of Marc's company/firm names — verify the draft does not contain any of the abstractions listed in the confidentiality rule: no BGBL, BLEGAL, BGA, ACM, or other company-name strings (grep: `grep -Ei "BGBL|BLEGAL|BGA\b|ACM|blegal.dev" .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` returns zero matches)
    - Uses defensive framing in the reviewer-facing section (grep: `grep -ni "standard Mail client\|standard.*handler\|Windows extensibility\|user consent" .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` returns at least 2 matches)
    - Does NOT use the word "intercept" or "interception" in the reviewer-facing sections (exception: acceptable in Section 5 only if it is the word being rebutted; grep: `grep -c "intercept" .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` — the count should be very low, ideally 0-2 and only in a rebuttal context; if >2, revise)
    - Contains "GitHub" and "marcfargas" (grep: each returns at least 1 match)
    - Contains "privacy" and "no telemetry" concepts (grep: `grep -ni "no telemetry\|privacy" .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` returns at least 2 matches)
    - File is 100+ lines long (reasonable length for a complete application draft — wc -l returns a value >= 100)
  </acceptance_criteria>
  <done>
    SIGNPATH-APPLICATION.md exists with all 8 sections, defensive reviewer-facing framing, LGPL-3.0 licensing stated, CWS listing clearly marked as placeholder, no confidentiality violations, and a pre-filing checklist for Marc.
  </done>
</task>

</tasks>

<verification>
- File exists at the expected path
- Contains all 8 sections
- Defensive framing used throughout the reviewer-facing sections
- Chrome Web Store listing clearly marked as placeholder
- Pre-filing checklist gives Marc clear action items
- No confidentiality violations (no company names)
- License is stated as LGPL-3.0 with a flag about the current repo metadata discrepancy
</verification>

<success_criteria>
- Draft application text is complete and ready for Marc to review and file
- Reviewer-facing sections use defensive framing per CONTEXT.md specifics
- Chrome Web Store listing is clearly marked as a placeholder so Marc does not accidentally file with a broken link
- Pre-filing checklist flags the license metadata issue and other action items
- No confidential information is present in the draft
- Plan 08 can now run to collect Marc's confirmation that the application is filed
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundation-signpath-application/01-07-SUMMARY.md` documenting:
- The final file path and line count of SIGNPATH-APPLICATION.md
- A brief confirmation that all 8 sections are present
- Confirmation that no confidential references leaked in
- A one-line note that Plan 08 is the human-verification checkpoint that will mark SIGN-01 complete
</output>
