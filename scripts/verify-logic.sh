#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

LOG_DIR="$ROOT/build/logs"
BIN_DIR="$ROOT/build/verify"
mkdir -p "$LOG_DIR" "$BIN_DIR"

RUN_ID="$$-$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOG_DIR/verify-logic-$RUN_ID.log"
BIN="$BIN_DIR/truongcam-verify-$RUN_ID"

PORTABLE_DIRS=(
  "src/TruongCam/Core"
  "src/TruongCam/Preview"
  "src/TruongCam/Storage"
  "src/TruongCam/Sequence"
  "src/TruongCam/Capture"
)

PORTABLE_FILES=(
  "src/TruongCam/App/LibrarySessionCoordinator.swift"
  "src/TruongCam/UI/LibraryModel.swift"
  "src/TruongCam/UI/PreferenceStoring.swift"
  "src/TruongCam/UI/CameraViewModel.swift"
  "src/TruongCam/UI/ExportPresenter.swift"
)

TEST_DIR="src/TruongCamTests"

collect_sources() {
  local files=()
  for dir in "${PORTABLE_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r file; do files+=("$file"); done < <(find "$dir" -name '*.swift' | sort)
  done
  for file in "${PORTABLE_FILES[@]}"; do
    [ -f "$file" ] && files+=("$file")
  done
  while IFS= read -r file; do
    [ -s "$file" ] || continue
    files+=("$file")
  done < <(find "$TEST_DIR" -name '*.swift' | sort)
  printf '%s\n' "${files[@]}"
}

SOURCES=()
while IFS= read -r file; do
  SOURCES+=("$file")
done < <(collect_sources)

if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "FAIL: no sources collected" >&2
  exit 2
fi

echo "== local logic verifier =="
echo "sources: ${#SOURCES[@]} files"
echo "binary:  $BIN"
echo "log:     $LOG (per-run; verify-logic-latest.log is a convenience copy)"
echo

xcrun --sdk macosx swiftc \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -D TC_TESTKIT_STANDALONE \
  -D TC_PORTABLE_VERIFIER \
  -O \
  -o "$BIN" \
  "${SOURCES[@]}" >"$LOG" 2>&1
compile_status=$?

if [ $compile_status -ne 0 ]; then
  echo "FAIL: verifier compile (exit $compile_status)"
  grep -E "error:|warning:" "$LOG" | sort -u | head -60
  exit $compile_status
fi
echo "compile: PASS (exit 0)"
echo

WATCHDOG_SECONDS="${TRUONGCAM_VERIFY_TIMEOUT:-600}"

RUN_LOG="$LOG_DIR/verify-logic-run-$RUN_ID.log"
: > "$RUN_LOG"
ln -sf "$(basename "$RUN_LOG")" "$LOG_DIR/verify-logic-run.log" 2>/dev/null || true

run_status=0
perl -e '
  my $timeout = shift @ARGV;
  my $pid = fork();
  die "fork failed: $!\n" unless defined $pid;
  if ($pid == 0) { exec { $ARGV[0] } @ARGV; print STDERR "exec failed: $!\n"; exit 127 }
  my $timed_out = 0;
  $SIG{ALRM} = sub { $timed_out = 1; kill "KILL", $pid };
  alarm $timeout;
  my $reaped;
  while (1) { $reaped = waitpid($pid, 0); last if $reaped == $pid || $reaped == -1 }
  alarm 0;
  my $raw = $?;
  exit 137 if $timed_out;
  exit 128 + ($raw & 127) if $raw & 127;
  exit($raw >> 8);
' "$WATCHDOG_SECONDS" "$BIN" "$@" >"$RUN_LOG" 2>&1 || run_status=$?

cat "$RUN_LOG"

if [ "$run_status" -eq 142 ] || [ "$run_status" -eq 137 ]; then
  echo "watchdog: verifier did not exit within ${WATCHDOG_SECONDS}s; terminated."
  echo "RESULT: FAIL (verification timed out; no passing result is accepted)"
  exit 124
fi
if [ "$run_status" -ne 0 ]; then
  echo "RESULT: FAIL (verifier exit status $run_status)"
  exit "$run_status"
fi
exit 0
