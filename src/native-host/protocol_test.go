package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"testing"

	mapi "github.com/marcfargas/go-mapi/native-host/internal/mapi"
)

// Helper to create a native messaging format message
func createNativeMessage(t *testing.T, msg interface{}) []byte {
	t.Helper()
	body, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("failed to marshal message: %v", err)
	}

	buf := new(bytes.Buffer)
	if err := binary.Write(buf, binary.LittleEndian, uint32(len(body))); err != nil {
		t.Fatalf("failed to write length: %v", err)
	}
	buf.Write(body)
	return buf.Bytes()
}

func TestNativeMessaging_Read_ValidMessage(t *testing.T) {
	input := IncomingMessage{
		Type: MsgTypeList,
	}
	data := createNativeMessage(t, input)

	nm := &NativeMessaging{
		reader: bytes.NewReader(data),
		writer: io.Discard,
	}

	msg, err := nm.Read()
	if err != nil {
		t.Fatalf("Read() error = %v", err)
	}

	if msg.Type != MsgTypeList {
		t.Errorf("Read() type = %v, want %v", msg.Type, MsgTypeList)
	}
}

func TestNativeMessaging_Read_ProcessMessage(t *testing.T) {
	input := IncomingMessage{
		Type: MsgTypeProcess,
		ID:   "test-id-123",
	}
	data := createNativeMessage(t, input)

	nm := &NativeMessaging{
		reader: bytes.NewReader(data),
		writer: io.Discard,
	}

	msg, err := nm.Read()
	if err != nil {
		t.Fatalf("Read() error = %v", err)
	}

	if msg.Type != MsgTypeProcess {
		t.Errorf("Read() type = %v, want %v", msg.Type, MsgTypeProcess)
	}
	if msg.ID != "test-id-123" {
		t.Errorf("Read() id = %v, want %v", msg.ID, "test-id-123")
	}
}

func TestNativeMessaging_Read_DeleteMessage(t *testing.T) {
	input := IncomingMessage{
		Type: MsgTypeDelete,
		ID:   "delete-id-456",
	}
	data := createNativeMessage(t, input)

	nm := &NativeMessaging{
		reader: bytes.NewReader(data),
		writer: io.Discard,
	}

	msg, err := nm.Read()
	if err != nil {
		t.Fatalf("Read() error = %v", err)
	}

	if msg.Type != MsgTypeDelete {
		t.Errorf("Read() type = %v, want %v", msg.Type, MsgTypeDelete)
	}
	if msg.ID != "delete-id-456" {
		t.Errorf("Read() id = %v, want %v", msg.ID, "delete-id-456")
	}
}

func TestNativeMessaging_Read_ShutdownMessage(t *testing.T) {
	input := IncomingMessage{
		Type: MsgTypeShutdown,
	}
	data := createNativeMessage(t, input)

	nm := &NativeMessaging{
		reader: bytes.NewReader(data),
		writer: io.Discard,
	}

	msg, err := nm.Read()
	if err != nil {
		t.Fatalf("Read() error = %v", err)
	}

	if msg.Type != MsgTypeShutdown {
		t.Errorf("Read() type = %v, want %v", msg.Type, MsgTypeShutdown)
	}
}

func TestNativeMessaging_Read_EOF(t *testing.T) {
	nm := &NativeMessaging{
		reader: bytes.NewReader([]byte{}),
		writer: io.Discard,
	}

	_, err := nm.Read()
	if err != io.EOF {
		t.Errorf("Read() error = %v, want io.EOF", err)
	}
}

func TestNativeMessaging_Read_OversizedMessage(t *testing.T) {
	// Create a length prefix indicating > 1MB message
	buf := new(bytes.Buffer)
	binary.Write(buf, binary.LittleEndian, uint32(2*1024*1024)) // 2MB

	nm := &NativeMessaging{
		reader: buf,
		writer: io.Discard,
	}

	_, err := nm.Read()
	if err == nil {
		t.Error("Read() expected error for oversized message")
	}
}

func TestNativeMessaging_Read_TruncatedBody(t *testing.T) {
	// Create a length prefix of 100, but only provide 10 bytes
	buf := new(bytes.Buffer)
	binary.Write(buf, binary.LittleEndian, uint32(100))
	buf.Write([]byte("short"))

	nm := &NativeMessaging{
		reader: buf,
		writer: io.Discard,
	}

	_, err := nm.Read()
	if err == nil {
		t.Error("Read() expected error for truncated body")
	}
}

func TestNativeMessaging_Read_InvalidJSON(t *testing.T) {
	invalidJSON := []byte("not valid json")
	buf := new(bytes.Buffer)
	binary.Write(buf, binary.LittleEndian, uint32(len(invalidJSON)))
	buf.Write(invalidJSON)

	nm := &NativeMessaging{
		reader: buf,
		writer: io.Discard,
	}

	_, err := nm.Read()
	if err == nil {
		t.Error("Read() expected error for invalid JSON")
	}
}

func TestNativeMessaging_Write_EmailMessage(t *testing.T) {
	buf := new(bytes.Buffer)
	nm := &NativeMessaging{
		reader: bytes.NewReader([]byte{}),
		writer: buf,
	}

	mail := &mapi.MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		Subject:    "Test Subject",
		Body:       "Test Body",
		BodyFormat: "plain",
		Recipients: mapi.Recipients{
			To: []mapi.Recipient{{Name: "John", Address: "john@example.com"}},
		},
	}

	err := nm.SendEmail("test-id", mail)
	if err != nil {
		t.Fatalf("SendEmail() error = %v", err)
	}

	// Verify output format
	data := buf.Bytes()
	if len(data) < 4 {
		t.Fatal("output too short")
	}

	// Read length prefix
	var length uint32
	binary.Read(bytes.NewReader(data[:4]), binary.LittleEndian, &length)

	// Parse JSON body
	var msg OutgoingMessage
	if err := json.Unmarshal(data[4:4+length], &msg); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}

	if msg.Type != MsgTypeEmail {
		t.Errorf("type = %v, want %v", msg.Type, MsgTypeEmail)
	}
	if msg.ID != "test-id" {
		t.Errorf("id = %v, want %v", msg.ID, "test-id")
	}
	if msg.Data.Subject != "Test Subject" {
		t.Errorf("subject = %v, want %v", msg.Data.Subject, "Test Subject")
	}
}

func TestNativeMessaging_Write_ReadyMessage(t *testing.T) {
	buf := new(bytes.Buffer)
	nm := &NativeMessaging{
		reader: bytes.NewReader([]byte{}),
		writer: buf,
	}

	err := nm.SendReady("1.0.0")
	if err != nil {
		t.Fatalf("SendReady() error = %v", err)
	}

	// Parse output
	data := buf.Bytes()
	var length uint32
	binary.Read(bytes.NewReader(data[:4]), binary.LittleEndian, &length)

	var msg OutgoingMessage
	if err := json.Unmarshal(data[4:4+length], &msg); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}

	if msg.Type != MsgTypeReady {
		t.Errorf("type = %v, want %v", msg.Type, MsgTypeReady)
	}
	if msg.Version != "1.0.0" {
		t.Errorf("version = %v, want %v", msg.Version, "1.0.0")
	}
}

func TestNativeMessaging_Write_ErrorMessage(t *testing.T) {
	buf := new(bytes.Buffer)
	nm := &NativeMessaging{
		reader: bytes.NewReader([]byte{}),
		writer: buf,
	}

	err := nm.SendError("something went wrong")
	if err != nil {
		t.Fatalf("SendError() error = %v", err)
	}

	// Parse output
	data := buf.Bytes()
	var length uint32
	binary.Read(bytes.NewReader(data[:4]), binary.LittleEndian, &length)

	var msg OutgoingMessage
	if err := json.Unmarshal(data[4:4+length], &msg); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}

	if msg.Type != MsgTypeError {
		t.Errorf("type = %v, want %v", msg.Type, MsgTypeError)
	}
	if msg.Error != "something went wrong" {
		t.Errorf("error = %v, want %v", msg.Error, "something went wrong")
	}
}

func TestNativeMessaging_Write_RemovedMessage(t *testing.T) {
	buf := new(bytes.Buffer)
	nm := &NativeMessaging{
		reader: bytes.NewReader([]byte{}),
		writer: buf,
	}

	err := nm.SendRemoved("removed-id")
	if err != nil {
		t.Fatalf("SendRemoved() error = %v", err)
	}

	// Parse output
	data := buf.Bytes()
	var length uint32
	binary.Read(bytes.NewReader(data[:4]), binary.LittleEndian, &length)

	var msg OutgoingMessage
	if err := json.Unmarshal(data[4:4+length], &msg); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}

	if msg.Type != MsgTypeRemoved {
		t.Errorf("type = %v, want %v", msg.Type, MsgTypeRemoved)
	}
	if msg.ID != "removed-id" {
		t.Errorf("id = %v, want %v", msg.ID, "removed-id")
	}
}

func TestNativeMessaging_Roundtrip(t *testing.T) {
	// Test that we can read what we write
	pipe := new(bytes.Buffer)
	writer := &NativeMessaging{
		reader: bytes.NewReader([]byte{}),
		writer: pipe,
	}

	// Write an email
	mail := &mapi.MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		Subject:    "Roundtrip Test",
		Body:       "Body content",
		BodyFormat: "html",
		Recipients: mapi.Recipients{
			To:  []mapi.Recipient{{Name: "To", Address: "to@example.com"}},
			CC:  []mapi.Recipient{{Name: "CC", Address: "cc@example.com"}},
			BCC: []mapi.Recipient{{Name: "BCC", Address: "bcc@example.com"}},
		},
		Attachments: []mapi.Attachment{{Filename: "file.txt", Path: "/tmp/file.txt", Size: 1024}},
		OriginApp:   "TestApp",
	}

	if err := writer.SendEmail("roundtrip-id", mail); err != nil {
		t.Fatalf("SendEmail() error = %v", err)
	}

	// Read it back (as raw OutgoingMessage since reader expects IncomingMessage)
	data := pipe.Bytes()
	var length uint32
	binary.Read(bytes.NewReader(data[:4]), binary.LittleEndian, &length)

	var msg OutgoingMessage
	if err := json.Unmarshal(data[4:4+length], &msg); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}

	// Verify all fields preserved
	if msg.Data.Subject != "Roundtrip Test" {
		t.Errorf("subject mismatch")
	}
	if msg.Data.BodyFormat != "html" {
		t.Errorf("bodyFormat mismatch")
	}
	if len(msg.Data.Recipients.To) != 1 || msg.Data.Recipients.To[0].Address != "to@example.com" {
		t.Errorf("to recipients mismatch")
	}
	if len(msg.Data.Recipients.CC) != 1 {
		t.Errorf("cc recipients mismatch")
	}
	if len(msg.Data.Recipients.BCC) != 1 {
		t.Errorf("bcc recipients mismatch")
	}
	if len(msg.Data.Attachments) != 1 || msg.Data.Attachments[0].Filename != "file.txt" {
		t.Errorf("attachments mismatch")
	}
}
