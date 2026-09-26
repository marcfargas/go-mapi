//go:build windows

package main

import (
	"errors"
	"io"
	"path/filepath"
	"time"
	"unsafe"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"golang.org/x/sys/windows"
)

// readPublicMachineStatus is deliberately read-only. It never asks the
// service to create a status tree, repair permissions, or install anything.
// All three objects are held open without write/delete sharing while the
// child is inspected, so a path swap cannot turn an untrusted file into a
// management signal.
func readPublicMachineStatus() publicMachineStatus {
	var raw *uint16
	hr, _, _ := procSHGetKnownFolderPath.Call(uintptr(unsafe.Pointer(&folderIDProgramData)), 0, 0, uintptr(unsafe.Pointer(&raw)))
	if int32(hr) < 0 || raw == nil {
		return publicMachineStatus{}
	}
	defer procCoTaskMemFree.Call(uintptr(unsafe.Pointer(raw)))
	serviceSID, _, _, err := windows.LookupSID("", `NT SERVICE\go-mapi`)
	if err != nil {
		return publicMachineStatus{}
	}
	base := filepath.Join(windows.UTF16PtrToString(raw), "go-mapi")
	root := filepath.Join(base, "status")
	file := filepath.Join(root, "status-v2.json")
	baseHandle, err := openVerifiedStatusObject(base, true, serviceSID.String())
	if err != nil {
		return publicMachineStatus{}
	}
	defer windows.CloseHandle(baseHandle)
	rootHandle, err := openVerifiedStatusObject(root, true, serviceSID.String())
	if err != nil {
		return publicMachineStatus{}
	}
	defer windows.CloseHandle(rootHandle)
	fileHandle, err := openVerifiedStatusObject(file, false, serviceSID.String())
	if err != nil {
		return publicMachineStatus{}
	}
	defer windows.CloseHandle(fileHandle)
	data := make([]byte, 4097)
	var count uint32
	if err := windows.ReadFile(fileHandle, data, &count, nil); err != nil && !errors.Is(err, io.EOF) {
		return publicMachineStatus{}
	}
	status, err := mapi.DecodePublicStatusV2(data[:count])
	if err != nil {
		return publicMachineStatus{}
	}
	now := time.Now().UTC()
	if status.UpdatedAt.After(now.Add(time.Minute)) || now.Sub(status.UpdatedAt) > 5*time.Minute {
		return publicMachineStatus{}
	}
	snapshot := publicMachineStatus{Status: status, Trusted: true}
	if status.Capability == "automatic" {
		snapshot.Identity, snapshot.ServiceRunning = installedMachineStatusIdentity(status)
	}
	return snapshot
}

func openVerifiedStatusObject(path string, directory bool, serviceSID string) (windows.Handle, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	access := uint32(windows.READ_CONTROL | windows.FILE_READ_ATTRIBUTES)
	if !directory {
		access |= windows.FILE_READ_DATA
	}
	handle, err := windows.CreateFile(name, access, windows.FILE_SHARE_READ, nil, windows.OPEN_EXISTING,
		windows.FILE_FLAG_OPEN_REPARSE_POINT|windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return 0, err
	}
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil || info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 ||
		(info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0) != directory {
		windows.CloseHandle(handle)
		return 0, errors.New("public status path is not an ordinary file or directory")
	}
	if err := verifyPublicStatusACL(handle, serviceSID); err != nil {
		windows.CloseHandle(handle)
		return 0, err
	}
	return handle, nil
}

func verifyPublicStatusACL(handle windows.Handle, serviceSID string) error {
	sd, err := windows.GetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil || owner == nil || (owner.String() != "S-1-5-18" && owner.String() != "S-1-5-32-544") {
		return errors.New("public status has untrusted owner")
	}
	dacl, _, err := sd.DACL()
	if err != nil || dacl == nil {
		return errors.New("public status lacks a DACL")
	}
	const writeMask = windows.FILE_WRITE_DATA | windows.FILE_APPEND_DATA | windows.FILE_WRITE_EA | windows.FILE_WRITE_ATTRIBUTES |
		0x00000040 /* FILE_DELETE_CHILD */ | windows.DELETE | windows.WRITE_DAC | windows.WRITE_OWNER | windows.GENERIC_WRITE | windows.GENERIC_ALL
	for index := uint32(0); index < uint32(dacl.AceCount); index++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, index, &ace); err != nil {
			return err
		}
		if ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return errors.New("public status has unsupported ACL entry")
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
		if ace.Mask&writeMask != 0 && sid != "S-1-5-18" && sid != "S-1-5-32-544" && sid != serviceSID {
			return errors.New("public status grants untrusted write access")
		}
	}
	return nil
}
