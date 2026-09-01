export namespace main {
	
	export class AppSettings {
	    mode: string;
	    autostart_enabled: boolean;
	    default_apps_prompted: boolean;
	    update_checks_enabled: boolean;
	    last_update_check?: string;
	
	    static createFrom(source: any = {}) {
	        return new AppSettings(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.mode = source["mode"];
	        this.autostart_enabled = source["autostart_enabled"];
	        this.default_apps_prompted = source["default_apps_prompted"];
	        this.update_checks_enabled = source["update_checks_enabled"];
	        this.last_update_check = source["last_update_check"];
	    }
	}
	export class SettingsIssue {
	    kind: string;
	    message: string;
	    path: string;

	    static createFrom(source: any = {}) { return new SettingsIssue(source); }
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.kind = source["kind"];
	        this.message = source["message"];
	        this.path = source["path"];
	    }
	}
	export class SettingsLoadResult {
	    settings: AppSettings;
	    issue?: SettingsIssue;

	    static createFrom(source: any = {}) { return new SettingsLoadResult(source); }
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.settings = this.convertValues(source["settings"], AppSettings);
	        this.issue = this.convertValues(source["issue"], SettingsIssue);
	    }
	    convertValues(a: any, classs: any): any {
	        if (!a) return a;
	        return new classs(a);
	    }
	}
	export class StartupState {
	    backend: string;
	    requested: boolean;
	    registered: boolean;
	    effective: string;
	    warning?: string;

	    static createFrom(source: any = {}) { return new StartupState(source); }
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.backend = source["backend"];
	        this.requested = source["requested"];
	        this.registered = source["registered"];
	        this.effective = source["effective"];
	        this.warning = source["warning"];
	    }
	}
	export class AuthStatus {
	    authenticated: boolean;
	    email?: string;
	    name?: string;
	
	    static createFrom(source: any = {}) {
	        return new AuthStatus(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.authenticated = source["authenticated"];
	        this.email = source["email"];
	        this.name = source["name"];
	    }
	}
	export class UpdateState {
	    currentVersion: string;
	    latestVersion: string;
	    latestReleaseUrl: string;
	    installerUrl: string;
	    updateAvailable: boolean;
	    lastCheckedAt: string;
	    enabled: boolean;
	
	    static createFrom(source: any = {}) {
	        return new UpdateState(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.currentVersion = source["currentVersion"];
	        this.latestVersion = source["latestVersion"];
	        this.latestReleaseUrl = source["latestReleaseUrl"];
	        this.installerUrl = source["installerUrl"];
	        this.updateAvailable = source["updateAvailable"];
	        this.lastCheckedAt = source["lastCheckedAt"];
	        this.enabled = source["enabled"];
	    }
	}

}

export namespace mapi {
	
	export class Attachment {
	    filename: string;
	    path: string;
	    size: number;
	
	    static createFrom(source: any = {}) {
	        return new Attachment(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.filename = source["filename"];
	        this.path = source["path"];
	        this.size = source["size"];
	    }
	}
	export class Recipient {
	    name: string;
	    address: string;
	
	    static createFrom(source: any = {}) {
	        return new Recipient(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.address = source["address"];
	    }
	}
	export class Recipients {
	    to: Recipient[];
	    cc: Recipient[];
	    bcc: Recipient[];
	
	    static createFrom(source: any = {}) {
	        return new Recipients(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.to = this.convertValues(source["to"], Recipient);
	        this.cc = this.convertValues(source["cc"], Recipient);
	        this.bcc = this.convertValues(source["bcc"], Recipient);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class MailMessage {
	    version: number;
	    interceptorVersion?: string;
	    hostVersion?: string;
	    timestamp: string;
	    subject: string;
	    body: string;
	    bodyFormat: string;
	    recipients: Recipients;
	    attachments: Attachment[];
	    originApp: string;
	
	    static createFrom(source: any = {}) {
	        return new MailMessage(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.version = source["version"];
	        this.interceptorVersion = source["interceptorVersion"];
	        this.hostVersion = source["hostVersion"];
	        this.timestamp = source["timestamp"];
	        this.subject = source["subject"];
	        this.body = source["body"];
	        this.bodyFormat = source["bodyFormat"];
	        this.recipients = this.convertValues(source["recipients"], Recipients);
	        this.attachments = this.convertValues(source["attachments"], Attachment);
	        this.originApp = source["originApp"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class EmailWithId {
	    id: string;
	    message?: MailMessage;
	
	    static createFrom(source: any = {}) {
	        return new EmailWithId(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.message = this.convertValues(source["message"], MailMessage);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	
	

}
