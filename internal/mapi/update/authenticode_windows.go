//go:build windows

package update

import (
	"crypto/x509"
	"errors"
	"runtime"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// VerifyAuthenticode delegates the file's signature and certificate trust
// decision to Windows. The service uses this check before a silent install.
func VerifyAuthenticode(path string) error {
	return withVerifiedWinTrust(path, nil)
}

// InspectAuthenticode is retained for the existing interactive admin repair
// path, which still consumes signer identity from the live WinTrust state.
func InspectAuthenticode(path string) (AuthenticodeIdentity, error) {
	var identity AuthenticodeIdentity
	err := withVerifiedWinTrust(path, func(data *windows.WinTrustData) error {
		var inspectErr error
		identity, inspectErr = inspectWinTrustIdentity(data)
		return inspectErr
	})
	return identity, err
}

func withVerifiedWinTrust(path string, inspect func(*windows.WinTrustData) error) error {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	file := windows.WinTrustFileInfo{Size: uint32(unsafe.Sizeof(windows.WinTrustFileInfo{})), FilePath: p}
	data := windows.WinTrustData{Size: uint32(unsafe.Sizeof(windows.WinTrustData{})), UIChoice: windows.WTD_UI_NONE, RevocationChecks: windows.WTD_REVOKE_WHOLECHAIN, UnionChoice: windows.WTD_CHOICE_FILE, FileOrCatalogOrBlobOrSgnrOrCert: unsafe.Pointer(&file), StateAction: windows.WTD_STATEACTION_VERIFY, ProvFlags: windows.WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT | windows.WTD_MOTW, UIContext: windows.WTD_UICONTEXT_INSTALL}
	if err := windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data); err != nil {
		return err
	}
	defer func() {
		data.StateAction = windows.WTD_STATEACTION_CLOSE
		_ = windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
	}()
	if inspect == nil {
		return nil
	}
	return inspect(&data)
}

func inspectWinTrustIdentity(data *windows.WinTrustData) (AuthenticodeIdentity, error) {
	if err := procWTHelperProvDataFromStateData.Find(); err != nil {
		return AuthenticodeIdentity{}, err
	}
	providerData, _, _ := procWTHelperProvDataFromStateData.Call(uintptr(data.StateData))
	runtime.KeepAlive(data)
	if providerData == 0 {
		return AuthenticodeIdentity{}, errors.New("missing WinTrust provider data")
	}
	if err := procWTHelperGetProvSignerFromChain.Find(); err != nil {
		return AuthenticodeIdentity{}, err
	}
	signer := winTrustProviderSignerFromChain(providerData)
	runtime.KeepAlive(data)
	if signer == nil {
		return AuthenticodeIdentity{}, errors.New("missing WinTrust provider signer")
	}
	cert := signer.CertChain
	if cert == nil || cert.Cert == nil || cert.Cert.EncodedCert == nil || cert.Cert.Length == 0 {
		return AuthenticodeIdentity{}, errors.New("missing WinTrust signer certificate")
	}
	parsed, err := x509.ParseCertificate(unsafe.Slice(cert.Cert.EncodedCert, cert.Cert.Length))
	if err != nil {
		return AuthenticodeIdentity{}, err
	}
	ekus := make([]string, 0, len(parsed.ExtKeyUsage)+len(parsed.UnknownExtKeyUsage))
	for _, usage := range parsed.ExtKeyUsage {
		if usage == x509.ExtKeyUsageCodeSigning {
			ekus = append(ekus, "1.3.6.1.5.5.7.3.3")
		}
	}
	for _, oid := range parsed.UnknownExtKeyUsage {
		ekus = append(ekus, oid.String())
	}
	cn := canonicalWinTrustCN(cert.Cert)
	if cn == "" {
		return AuthenticodeIdentity{}, errors.New("signer publisher identity is empty")
	}
	return AuthenticodeIdentity{ChainValid: true, Publisher: cn, EKUs: ekus}, nil
}

type winTrustProviderCert struct {
	cbStruct uint32
	Cert     *windows.CertContext
}
type winTrustProviderSigner struct {
	cbStruct       uint32
	VerifyAsOf     windows.Filetime
	CertChainCount uint32
	CertChain      *winTrustProviderCert
}

var procWTHelperProvDataFromStateData = windows.NewLazySystemDLL("wintrust.dll").NewProc("WTHelperProvDataFromStateData")
var procWTHelperGetProvSignerFromChain = windows.NewLazySystemDLL("wintrust.dll").NewProc("WTHelperGetProvSignerFromChain")

// The returned pointer belongs to the live WinTrust state; the caller must
// consume it before WTD_STATEACTION_CLOSE and keep WinTrustData alive.
//
//go:nocheckptr
func winTrustProviderSignerFromChain(providerData uintptr) *winTrustProviderSigner {
	r, _, _ := procWTHelperGetProvSignerFromChain.Call(providerData, 0, 0, 0)
	if r == 0 {
		return nil
	}
	p := *(*unsafe.Pointer)(unsafe.Pointer(&r))
	return (*winTrustProviderSigner)(p)
}

func canonicalWinTrustCN(cert *windows.CertContext) string {
	n := windows.CertGetNameString(cert, windows.CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nil, nil, 0)
	if n == 0 {
		return ""
	}
	buf := make([]uint16, n)
	windows.CertGetNameString(cert, windows.CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nil, &buf[0], n)
	return strings.ToLower(strings.TrimSpace(windows.UTF16PtrToString(&buf[0])))
}
