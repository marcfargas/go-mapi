// E2E-04 companion: minimal native-messaging host stub used by the
// install-UX test. Sends exactly one READY message on stdout using the
// Chrome Native Messaging framing (4-byte little-endian length prefix +
// JSON payload), then blocks reading stdin until EOF.
//
// This is NOT a real native host — it does no watching, no Gmail API
// work, and does not handle any incoming messages. It exists purely so
// install-ux.spec.ts can register a manifest pointing at SOMETHING that
// delivers a READY message, letting the extension transition out of
// the MISSING state.

package main

import (
	"encoding/binary"
	"encoding/json"
	"io"
	"os"
)

type readyMessage struct {
	Type        string `json:"type"`
	Version     string `json:"version"`
	HostVersion string `json:"hostVersion"`
}

func writeMessage(w io.Writer, msg interface{}) error {
	body, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	// 4-byte little-endian length prefix per Chrome Native Messaging spec.
	if err := binary.Write(w, binary.LittleEndian, uint32(len(body))); err != nil {
		return err
	}
	_, err = w.Write(body)
	return err
}

func main() {
	ready := readyMessage{
		Type:        "ready",
		Version:     "2.0.0",
		HostVersion: "2.0.0",
	}

	if err := writeMessage(os.Stdout, ready); err != nil {
		os.Exit(1)
	}
	_ = os.Stdout.Sync()

	// Block reading stdin until EOF — exits cleanly when the extension
	// disconnects the port.
	buf := make([]byte, 4096)
	for {
		_, err := os.Stdin.Read(buf)
		if err != nil {
			return
		}
	}
}
