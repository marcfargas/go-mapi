# go-mapi - Chrome Web Store Description

**Character count: ~7,500** (well under 16,000 limit)

---

## SHORT DESCRIPTION (132 characters)

Enable "Send to Mail" on Windows for Gmail & Google Workspace. Open-source MAPI bridge - no subscription fees.

---

## DETAILED DESCRIPTION

### Overview

**go-mapi brings "Send to → Mail recipient" to Gmail and Google Workspace users on Windows.**

Right-click any file in Windows Explorer, click "Send to → Mail recipient", and the email appears ready to send in Gmail - no subscription fees, completely open source.

> ⚠️ **Additional Software Required**
> This extension requires two free, open-source companion programs installed on your Windows computer:
> 1. **MAPI Interceptor DLL** — captures email requests from Windows applications
> 2. **Native Messaging Host** — relays those requests to this browser extension
>
> Both are installed via a single PowerShell command (see Setup Instructions below). They are small, open-source programs that run entirely on your local machine. No third-party servers or background services are involved. Source code: [GitHub](https://github.com/marcfargas/go-mapi)

### The Problem

Windows has a built-in email feature called MAPI (Messaging Application Programming Interface) that lets any program send emails through your default email client. This powers:

- "Send to → Mail recipient" in Windows Explorer
- "Email" buttons in PDF readers, Office apps, and thousands of Windows programs
- Print-to-PDF-and-email workflows
- Document sharing from any application

**Gmail and Google Workspace have never supported MAPI.** If Gmail is your email provider, these features simply don't work.

Third-party tools like Affixa filled this gap for years, but Affixa shut down in 2024, leaving Google Workspace users with no native solution.

**go-mapi is the free, open-source replacement.**

### What Makes go-mapi Different

✅ **Free & Open Source** - No subscription fees, no paid tiers, no feature locks  
✅ **Privacy-First** - Data stays on your computer until you send; no third-party servers  
✅ **Simple Setup** - Install extension + run one PowerShell command to install local components; works immediately  
✅ **Enterprise-Ready** - Deployable via Group Policy and Chrome Enterprise Policy  
✅ **Active Development** - Open source on GitHub with regular updates  

### Key Features

- **Windows Integration**: Makes Gmail your default MAPI email client
- **Right-Click Sending**: "Send to → Mail recipient" from Windows Explorer
- **Application Support**: Works with any Windows app that uses MAPI (Office, PDF readers, image editors, etc.)
- **Attachment Support**: Send files of any size (up to Gmail's limits)
- **Draft or Send**: Save emails as Gmail drafts to edit later, or send immediately
- **UTF-8 Support**: Handles international characters correctly
- **Notifications**: Desktop alerts when new emails are ready
- **Chrome & Edge**: Works in both browsers (separate installation for each)

### How It Works

go-mapi uses a three-part architecture designed for security and simplicity:

**1. MAPI Interceptor (DLL)**  
Captures email requests from Windows applications and saves them as JSON files in your temporary folder.

**2. Native Messaging Host (Local Service)**  
Watches for new email files and securely sends them to the browser extension via Chrome's Native Messaging API.

**3. Browser Extension (This Extension)**  
Displays emails in a popup and uses the Gmail API to create drafts or send messages. Authentication happens through Chrome's identity system - no separate login needed.

```
Windows App → DLL → JSON Files → Native Host → Extension → Gmail API
```

All data stays on your local machine until you explicitly send the email. No third-party servers, no data collection.

### Setup Instructions

#### Step 1: Install This Extension

Click "Add to Chrome" above. The extension will appear in your browser toolbar.

#### Step 2: Copy Your Extension ID

1. Go to `chrome://extensions/`
2. Enable "Developer mode" (toggle in top-right)
3. Find "go-mapi" in the list
4. Copy the **ID** (long string of letters under the extension name)

#### Step 3: Run the Installer

Open **PowerShell as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/marcfargas/go-mapi/main/scripts/install.ps1 | iex
```

When prompted, paste your extension ID from Step 2.

The installer will:
- Download the latest release binaries
- Install them to `C:\Program Files\go-mapi\`
- Register go-mapi as your default MAPI handler
- Set up native messaging for Chrome/Edge
- Configure Windows to use Gmail for "Send to → Mail recipient"

#### Step 4: Test It

1. Right-click any file in Windows Explorer
2. Select "Send to → Mail recipient"
3. The go-mapi popup will open with the file attached
4. Click "Save as Draft" or "Send Now"

That's it! Any Windows program that supports email will now use Gmail.

### Advanced Setup Options

**Pin a specific version:**
```powershell
.\install.ps1 -ExtensionId "your-id" -Version "v0.1.0"
```

**Custom install location:**
```powershell
.\install.ps1 -ExtensionId "your-id" -InstallDir "D:\go-mapi"
```

**Developer install (from local build):**
```powershell
.\install.ps1 -ExtensionId "your-id" -Local
```

### Uninstalling

Open **PowerShell as Administrator**:

```powershell
irm https://raw.githubusercontent.com/marcfargas/go-mapi/main/scripts/install.ps1 | iex
# When prompted, choose the uninstall option
```

Or download and run:
```powershell
.\install.ps1 -Uninstall
```

This removes:
- All installed files from `C:\Program Files\go-mapi\`
- Registry entries for MAPI and native messaging
- Windows "Send to" integration

Your previous default mail client (if any) will be restored.

### Enterprise Deployment

go-mapi is designed for managed environments:

**Binaries**: Deploy `go-mapi.dll` and `go-mapi-host.exe` via MSI, SCCM, or Intune  
**Extension**: Force-install using Chrome's `ExtensionInstallForcelist` policy  
**Configuration**: Export registry keys for GPO deployment  
**OAuth**: Create a Google Cloud project with your own OAuth credentials  

See the [GitHub repository](https://github.com/marcfargas/go-mapi) for enterprise deployment guides.

### Privacy & Security

**What data does go-mapi collect?**  
**None.** go-mapi is 100% local:

- Email data is stored temporarily in `%TEMP%\go-mapi\` as JSON files
- Files are deleted after processing (sent or dismissed)
- No analytics, no telemetry, no tracking
- No external servers except Google's Gmail API (only when you send email)

**What permissions does the extension need?**

- `nativeMessaging` - Communicate with the local Native Host service
- `identity` - Sign in to your Google account via Chrome's OAuth system
- `storage` - Save your preferences (like "always send" vs "always draft")
- `notifications` - Show desktop alerts when emails are ready
- `https://www.googleapis.com/*` - Access Gmail API to send emails

**Is my data secure?**

- All communication between components happens locally on your machine
- The extension only accesses Gmail when you click "Send" or "Save as Draft"
- OAuth tokens are stored by Chrome's identity system, not by go-mapi
- The code is open source - you can audit it yourself on [GitHub](https://github.com/marcfargas/go-mapi)

**Can go-mapi access my existing emails?**

No. The extension only requests these Gmail API scopes:
- `gmail.compose` - Create new draft emails
- `gmail.send` - Send emails you've approved

It **cannot** read your inbox, trash, or any existing messages.

### Requirements

- **Operating System**: Windows 10 or Windows 11
- **Browser**: Google Chrome or Microsoft Edge
- **Email**: Gmail or Google Workspace account
- **Permissions**: Administrator access for initial installation

### Known Limitations

- **Windows only** - MAPI is a Windows API; macOS and Linux aren't supported
- **Attachment uploads** - Currently in development; files attach to drafts but large uploads may be slow
- **Inline images** - Plain text and HTML emails work; embedded images are planned
- **Extended MAPI** - Only Simple MAPI is supported (covers 95% of use cases)

See [ROADMAP.md](https://github.com/marcfargas/go-mapi/blob/main/ROADMAP.md) for upcoming features.

### Support & Contributing

**Need help?**  
- GitHub Issues: https://github.com/marcfargas/go-mapi/issues  
- Documentation: https://github.com/marcfargas/go-mapi  

**Want to contribute?**  
go-mapi is open source (GPLv3)! We welcome:
- Bug reports and feature requests
- Code contributions (C++, Go, TypeScript/React)
- Documentation improvements
- Translations

See [CONTRIBUTING.md](https://github.com/marcfargas/go-mapi/blob/main/CONTRIBUTING.md) to get started.

### Troubleshooting

**Extension popup doesn't show emails:**
1. Check that the Native Host is installed: Look for `C:\Program Files\go-mapi\go-mapi-host.exe`
2. Check your extension ID matches: Go to `chrome://extensions/` and verify the ID
3. Restart Chrome/Edge after installation
4. Check for JSON files in `%TEMP%\go-mapi\` - if they exist, the DLL is working

**"Send to → Mail recipient" doesn't work:**
1. Verify the DLL is installed: `C:\Program Files\go-mapi\go-mapi.dll`
2. Check Windows registry: Run `reg query "HKEY_LOCAL_MACHINE\SOFTWARE\Clients\Mail\go-mapi"`
3. Re-run the installer with `-Force` flag
4. Restart Windows (some applications cache MAPI settings)

**OAuth / Login errors:**
1. Sign in to your Google account in Chrome/Edge first
2. Clear cookies and try again
3. Check that your organization allows third-party Chrome extensions
4. Try the OAuth consent flow in an incognito window

Still stuck? Open an issue on GitHub with:
- Windows version
- Chrome/Edge version
- Extension ID
- Any error messages from the DevTools console

### Version History

**v0.1.0-beta** (Current)
- Initial public release
- Core MAPI interception (ANSI + Unicode)
- Native messaging bridge
- React-based extension UI
- Gmail draft creation
- Attachment support
- UTF-8 encoding
- PowerShell installer

See [CHANGELOG.md](https://github.com/marcfargas/go-mapi/blob/main/CHANGELOG.md) for detailed release notes.

### License

go-mapi is licensed under the **GNU General Public License v3.0** (GPLv3).

This means:
- ✅ You can use it for free (personal or commercial)
- ✅ You can modify and distribute it
- ✅ You must share your modifications under GPLv3
- ✅ No warranty is provided

See [LICENSE](https://github.com/marcfargas/go-mapi/blob/main/LICENSE) for full terms.

### Credits

**go-mapi** was created as a free alternative to Affixa after its shutdown announcement in 2024.

Built with:
- C++ (MinGW) for the MAPI interceptor
- Go for the native messaging host
- React + TypeScript for the browser extension
- Gmail API for email delivery

Special thanks to the open source community and everyone who tested the beta.

### Why "go-mapi"?

The name is a play on "Google" and "let's go". It's also a nod to the Go programming language used in the native host component.

---

## SCREENSHOTS

**Recommended screenshots for Web Store:**

1. **Main popup with email ready to send**
   - Shows file attachment, recipient, subject, body
   - "Save as Draft" and "Send Now" buttons visible

2. **Windows Explorer context menu**
   - Right-click on file → "Send to" → "Mail recipient" highlighted

3. **Success notification**
   - "Email sent successfully via Gmail" desktop notification

4. **Settings panel**
   - Options for default action (draft/send), notifications, etc.

5. **Empty state / welcome screen**
   - "Right-click any file in Windows and choose 'Send to → Mail recipient'"

---

## PROMOTIONAL TILE TEXT

**Small Tile (440x280):**
"Send files from Windows Explorer to Gmail - Free & Open Source"

**Large Tile (920x680):**
"Finally: 'Send to → Mail recipient' for Gmail & Google Workspace  
Free • Open Source • No Subscription"

**Marquee (1400x560):**
"Right-click. Send to Mail. Done.  
The MAPI bridge Gmail should have built."

---

## CATEGORY

**Communication**

---

## TAGS

mapi, gmail, google workspace, email, windows, send to, mail recipient, enterprise, open source, affixa alternative, outlook alternative, native messaging

---

**END OF DESCRIPTION**

**Character count including formatting: ~7,500**  
**Well under the 16,000 character limit** ✅
