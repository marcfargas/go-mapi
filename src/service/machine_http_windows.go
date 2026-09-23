//go:build windows

package service

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/textproto"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	winHTTPAccessTypeAutomaticProxy = 4
	winHTTPFlagSecure               = 0x00800000

	winHTTPOptionDisableFeature  = 63
	winHTTPDisableRedirects      = 0x00000002
	winHTTPOptionAutologonPolicy = 77
	winHTTPAutologonSecurityHigh = 2

	winHTTPQueryContentType   = 1
	winHTTPQueryContentLength = 5
	winHTTPQueryLocation      = 33
	winHTTPQueryStatusCode    = 19
	winHTTPQueryFlagNumber    = 0x20000000
)

var (
	winHTTP                    = windows.NewLazySystemDLL("winhttp.dll")
	procWinHTTPOpen            = winHTTP.NewProc("WinHttpOpen")
	procWinHTTPConnect         = winHTTP.NewProc("WinHttpConnect")
	procWinHTTPOpenRequest     = winHTTP.NewProc("WinHttpOpenRequest")
	procWinHTTPSetOption       = winHTTP.NewProc("WinHttpSetOption")
	procWinHTTPSetTimeouts     = winHTTP.NewProc("WinHttpSetTimeouts")
	procWinHTTPSendRequest     = winHTTP.NewProc("WinHttpSendRequest")
	procWinHTTPReceiveResponse = winHTTP.NewProc("WinHttpReceiveResponse")
	procWinHTTPQueryHeaders    = winHTTP.NewProc("WinHttpQueryHeaders")
	procWinHTTPReadData        = winHTTP.NewProc("WinHttpReadData")
	procWinHTTPCloseHandle     = winHTTP.NewProc("WinHttpCloseHandle")
)

// NewMachineHTTPClient uses WinHTTP's machine context and automatic proxy
// resolver. It deliberately does not consult net/http's environment proxy,
// WinINet/browser state, interactive credentials, or a user profile.
func NewMachineHTTPClient() (*http.Client, error) {
	if err := winHTTP.Load(); err != nil {
		return nil, ErrMachineHTTPUnavailable
	}
	return &http.Client{
		Transport: machineWinHTTPTransport{},
		// Authenticated release policy installs its own bounded, same-origin
		// redirect hook. Other callers must opt in explicitly.
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	}, nil
}

type machineWinHTTPTransport struct{}

func (machineWinHTTPTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if err := validateMachineHTTPRequest(request); err != nil {
		return nil, err
	}
	if err := request.Context().Err(); err != nil {
		return nil, err
	}
	agent, _ := windows.UTF16PtrFromString("go-mapi-service/1")
	session, _, _ := procWinHTTPOpen.Call(uintptr(unsafe.Pointer(agent)), winHTTPAccessTypeAutomaticProxy, 0, 0, 0)
	if session == 0 {
		return nil, ErrMachineHTTPFailure
	}
	owner := &winHTTPBody{session: session, context: request.Context(), done: make(chan struct{})}
	fail := func(err error) (*http.Response, error) {
		_ = owner.Close()
		return nil, err
	}
	if !winHTTPBool(procWinHTTPSetTimeouts.Call(session, machineHTTPResolveTimeoutMS, machineHTTPConnectTimeoutMS, machineHTTPSendTimeoutMS, machineHTTPReceiveTimeoutMS)) {
		return fail(ErrMachineHTTPFailure)
	}
	host, err := windows.UTF16PtrFromString(request.URL.Hostname())
	if err != nil {
		return fail(ErrMachineHTTPInvalidRequest)
	}
	port := request.URL.Port()
	portNumber := uint16(443)
	if port != "" {
		parsed, parseErr := strconv.ParseUint(port, 10, 16)
		if parseErr != nil || parsed == 0 {
			return fail(ErrMachineHTTPInvalidRequest)
		}
		portNumber = uint16(parsed)
	}
	connect, _, _ := procWinHTTPConnect.Call(session, uintptr(unsafe.Pointer(host)), uintptr(portNumber), 0)
	if connect == 0 {
		return fail(ErrMachineHTTPFailure)
	}
	owner.connect = connect
	verb, _ := windows.UTF16PtrFromString(request.Method)
	resource := request.URL.EscapedPath()
	if resource == "" {
		resource = "/"
	}
	if request.URL.RawQuery != "" {
		resource += "?" + request.URL.RawQuery
	}
	resourcePointer, err := windows.UTF16PtrFromString(resource)
	if err != nil {
		return fail(ErrMachineHTTPInvalidRequest)
	}
	requestHandle, _, _ := procWinHTTPOpenRequest.Call(connect, uintptr(unsafe.Pointer(verb)), uintptr(unsafe.Pointer(resourcePointer)), 0, 0, 0, winHTTPFlagSecure)
	if requestHandle == 0 {
		return fail(ErrMachineHTTPFailure)
	}
	owner.request = requestHandle
	disableRedirects := uint32(winHTTPDisableRedirects)
	if !winHTTPBool(procWinHTTPSetOption.Call(requestHandle, winHTTPOptionDisableFeature, uintptr(unsafe.Pointer(&disableRedirects)), unsafe.Sizeof(disableRedirects))) {
		return fail(ErrMachineHTTPFailure)
	}
	autologon := uint32(winHTTPAutologonSecurityHigh)
	if !winHTTPBool(procWinHTTPSetOption.Call(requestHandle, winHTTPOptionAutologonPolicy, uintptr(unsafe.Pointer(&autologon)), unsafe.Sizeof(autologon))) {
		return fail(ErrMachineHTTPFailure)
	}
	owner.watchCancellation()
	if !winHTTPBool(procWinHTTPSendRequest.Call(requestHandle, 0, 0, 0, 0, 0, 0)) {
		return fail(machineHTTPContextError(request.Context()))
	}
	if !winHTTPBool(procWinHTTPReceiveResponse.Call(requestHandle, 0)) {
		return fail(machineHTTPContextError(request.Context()))
	}
	status, err := winHTTPStatus(requestHandle)
	if err != nil {
		return fail(err)
	}
	if status == http.StatusProxyAuthRequired {
		return fail(ErrMachineProxyAuthentication)
	}
	headers := make(http.Header)
	if value, ok := winHTTPHeader(requestHandle, winHTTPQueryLocation); ok {
		headers.Set("Location", value)
	}
	if value, ok := winHTTPHeader(requestHandle, winHTTPQueryContentType); ok {
		headers.Set("Content-Type", value)
	}
	contentLength := int64(-1)
	if value, ok := winHTTPHeader(requestHandle, winHTTPQueryContentLength); ok {
		if parsed, parseErr := strconv.ParseInt(value, 10, 64); parseErr == nil && parsed >= 0 {
			contentLength = parsed
		}
		headers.Set("Content-Length", value)
	}
	return &http.Response{
		Status:        strconv.Itoa(status) + " " + http.StatusText(status),
		StatusCode:    status,
		Proto:         "HTTP/1.1",
		ProtoMajor:    1,
		ProtoMinor:    1,
		Header:        headers,
		Body:          owner,
		ContentLength: contentLength,
		Request:       request,
	}, nil
}

func winHTTPBool(result uintptr, _ uintptr, _ error) bool { return result != 0 }

func machineHTTPContextError(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return ErrMachineHTTPFailure
}

func winHTTPStatus(handle uintptr) (int, error) {
	var status uint32
	length := uint32(unsafe.Sizeof(status))
	result, _, _ := procWinHTTPQueryHeaders.Call(handle, winHTTPQueryStatusCode|winHTTPQueryFlagNumber, 0, uintptr(unsafe.Pointer(&status)), uintptr(unsafe.Pointer(&length)), 0)
	if result == 0 || status < 100 || status > 999 {
		return 0, ErrMachineHTTPFailure
	}
	return int(status), nil
}

func winHTTPHeader(handle uintptr, query uint32) (string, bool) {
	var length uint32
	result, _, callErr := procWinHTTPQueryHeaders.Call(handle, uintptr(query), 0, 0, uintptr(unsafe.Pointer(&length)), 0)
	if result != 0 || !errors.Is(callErr, windows.ERROR_INSUFFICIENT_BUFFER) || length < 2 {
		return "", false
	}
	buffer := make([]uint16, (length+1)/2)
	result, _, _ = procWinHTTPQueryHeaders.Call(handle, uintptr(query), 0, uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&length)), 0)
	if result == 0 {
		return "", false
	}
	value := strings.TrimSpace(windows.UTF16ToString(buffer))
	if strings.ContainsAny(value, "\r\n") {
		return "", false
	}
	return textproto.TrimString(value), value != ""
}

type winHTTPBody struct {
	mutex   sync.Mutex
	session uintptr
	connect uintptr
	request uintptr
	context context.Context
	done    chan struct{}
	closed  bool
}

func (body *winHTTPBody) watchCancellation() {
	go func() {
		select {
		case <-body.context.Done():
			_ = body.Close()
		case <-body.done:
		}
	}()
}

func (body *winHTTPBody) Read(buffer []byte) (int, error) {
	if len(buffer) == 0 {
		return 0, nil
	}
	body.mutex.Lock()
	if body.closed || body.request == 0 {
		body.mutex.Unlock()
		if err := body.context.Err(); err != nil {
			return 0, err
		}
		return 0, io.ErrClosedPipe
	}
	handle := body.request
	body.mutex.Unlock()
	var read uint32
	result, _, _ := procWinHTTPReadData.Call(handle, uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)), uintptr(unsafe.Pointer(&read)))
	if result == 0 {
		if err := body.context.Err(); err != nil {
			return 0, err
		}
		return 0, ErrMachineHTTPFailure
	}
	if read == 0 {
		return 0, io.EOF
	}
	return int(read), nil
}

func (body *winHTTPBody) Close() error {
	body.mutex.Lock()
	defer body.mutex.Unlock()
	if body.closed {
		return nil
	}
	body.closed = true
	close(body.done)
	for _, handle := range []uintptr{body.request, body.connect, body.session} {
		if handle != 0 {
			procWinHTTPCloseHandle.Call(handle)
		}
	}
	body.request, body.connect, body.session = 0, 0, 0
	return nil
}

var _ http.RoundTripper = machineWinHTTPTransport{}
var _ io.ReadCloser = (*winHTTPBody)(nil)
