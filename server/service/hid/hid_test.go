package hid

import (
	"errors"
	"io"
	"os"
	"syscall"
	"testing"
	"time"
)

func TestReportLengthValidation(t *testing.T) {
	h := &Hid{}
	if err := h.WriteKeyboardReport(make([]byte, 7)); err == nil {
		t.Fatal("expected keyboard length error")
	}
	if err := h.WriteRelativeMouseReport(make([]byte, 5)); err == nil {
		t.Fatal("expected relative mouse length error")
	}
	if err := h.WriteAbsoluteMouseReport(make([]byte, 7)); err == nil {
		t.Fatal("expected absolute mouse length error")
	}
}

func TestPasteDurationLeavesModeSwitchMargin(t *testing.T) {
	if maxPasteDuration >= 30*time.Second {
		t.Fatalf("maxPasteDuration = %s, want below 30s mode switch wait budget", maxPasteDuration)
	}
	if got := time.Duration(maxPasteContentRunes) * defaultPasteDelay; got > maxPasteDuration {
		t.Fatalf("max paste content duration = %s, want <= %s", got, maxPasteDuration)
	}
}

type scriptedWriter struct {
	writes []scriptedWrite
}

type scriptedWrite struct {
	n   int
	err error
}

func (w *scriptedWriter) Write(_ []byte) (int, error) {
	if len(w.writes) == 0 {
		return 0, io.ErrUnexpectedEOF
	}
	write := w.writes[0]
	w.writes = w.writes[1:]
	return write.n, write.err
}

func TestWriteWithTimeoutRetriesEAGAIN(t *testing.T) {
	writer := &scriptedWriter{
		writes: []scriptedWrite{
			{err: syscall.EAGAIN},
			{n: 3},
		},
	}

	if err := writeWithTimeout(writer, []byte{1, 2, 3}, 20*time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if len(writer.writes) != 0 {
		t.Fatalf("unused scripted writes: %d", len(writer.writes))
	}
}

func TestWriteWithTimeoutRejectsShortWrite(t *testing.T) {
	writer := &scriptedWriter{
		writes: []scriptedWrite{{n: 2}},
	}

	if !errors.Is(writeWithTimeout(writer, []byte{1, 2, 3}, 20*time.Millisecond), io.ErrShortWrite) {
		t.Fatal("writeWithTimeout did not reject a short write")
	}
}

func TestWriteWithTimeoutExpiresAfterRetryableErrors(t *testing.T) {
	writer := &scriptedWriter{
		writes: []scriptedWrite{
			{err: syscall.EAGAIN},
			{err: syscall.EAGAIN},
			{err: syscall.EAGAIN},
		},
	}

	if !errors.Is(writeWithTimeout(writer, []byte{1}, time.Millisecond), os.ErrDeadlineExceeded) {
		t.Fatal("writeWithTimeout did not time out after retryable errors")
	}
}

func TestOpenNoLockWithRetryRetriesUntilSuccess(t *testing.T) {
	attempts := 0
	err := openNoLockWithRetry(func() error {
		attempts++
		if attempts < 3 {
			return syscall.ENODEV
		}
		return nil
	}, 100*time.Millisecond, time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if attempts != 3 {
		t.Fatalf("attempts = %d, want 3", attempts)
	}
}

func TestOpenNoLockWithRetryReturnsLastError(t *testing.T) {
	attempts := 0
	err := openNoLockWithRetry(func() error {
		attempts++
		return syscall.ENODEV
	}, time.Millisecond, time.Millisecond)
	if !errors.Is(err, syscall.ENODEV) {
		t.Fatalf("openNoLockWithRetry error = %v, want ENODEV", err)
	}
	if attempts == 0 {
		t.Fatal("openNoLockWithRetry did not attempt to open")
	}
}
