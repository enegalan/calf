//go:build darwin

package runtime

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

// Darwin proc_info constants (sys/proc_info.h). Prefer SYS_PROC_INFO over /bin/ps:
// Cursor/IDE sandboxes often deny fork/exec of the setuid ps binary while still
// allowing the proc_info syscall for same-user processes.
const (
	sysProcInfo         = 336
	procInfoCallPidInfo = 2
	procPidTaskInfo     = 4
)

// procTaskInfo matches struct proc_taskinfo on Darwin.
type procTaskInfo struct {
	VirtualSize      uint64
	ResidentSize     uint64
	TotalUser        uint64
	TotalSystem      uint64
	ThreadsUser      uint64
	ThreadsSystem    uint64
	Policy           int32
	Faults           int32
	Pageins          int32
	CowFaults        int32
	MessagesSent     int32
	MessagesReceived int32
	SyscallsMach     int32
	SyscallsUnix     int32
	Csw              int32
	Threadnum        int32
	Numrunning       int32
	Priority         int32
}

// cpuSample stores prior CPU time for instantaneous %CPU between status polls.
type cpuSample struct {
	at         time.Time
	totalTicks uint64
}

var (
	cpuSamples   sync.Map // pid (int) -> cpuSample
	ticksPerSec  float64
	ticksPerOnce sync.Once
)

// processCpuAndRSS returns %CPU and RSS bytes for the PID stored in path.
func processCpuAndRSS(pidPath string) (cpuPercent float64, rssBytes int64, err error) {
	data, err := os.ReadFile(pidPath)
	if err != nil {
		return 0, 0, err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid < 1 {
		return 0, 0, fmt.Errorf("invalid pid file %s", pidPath)
	}
	return processCpuAndRSSForPID(pid)
}

// processCpuAndRSSForPID returns %CPU and RSS bytes for pid.
// Uses Darwin proc_info first (works under exec-restricted sandboxes), then /bin/ps.
func processCpuAndRSSForPID(pid int) (cpuPercent float64, rssBytes int64, err error) {
	if info, infoErr := darwinProcTaskInfo(pid); infoErr == nil {
		return cpuPercentFromTaskInfo(pid, info), int64(info.ResidentSize), nil
	}
	return processCpuAndRSSForPIDViaPS(pid)
}

// darwinProcTaskInfo reads struct proc_taskinfo for pid via SYS_PROC_INFO.
func darwinProcTaskInfo(pid int) (procTaskInfo, error) {
	var info procTaskInfo
	r1, _, errno := syscall.RawSyscall6(
		sysProcInfo,
		procInfoCallPidInfo,
		uintptr(pid),
		procPidTaskInfo,
		0,
		uintptr(unsafe.Pointer(&info)),
		uintptr(unsafe.Sizeof(info)),
	)
	if errno != 0 {
		return procTaskInfo{}, errno
	}
	if r1 != uintptr(unsafe.Sizeof(info)) {
		return procTaskInfo{}, fmt.Errorf("proc_info short read: got %d want %d", r1, unsafe.Sizeof(info))
	}
	return info, nil
}

// ensureTicksPerSec calibrates mach absolute-time ticks to wall seconds.
// Rosetta makes GOARCH/uname unreliable for the 125/3 vs 1/1 timebase choice.
func ensureTicksPerSec() {
	ticksPerOnce.Do(func() {
		ticksPerSec = 1e9 // nanoseconds fallback until calibrated
		pid := os.Getpid()
		info1, err := darwinProcTaskInfo(pid)
		if err != nil {
			return
		}
		start := time.Now()
		deadline := start.Add(25 * time.Millisecond)
		sink := 0
		for time.Now().Before(deadline) {
			for i := 0; i < 1000; i++ {
				sink += i
			}
		}
		elapsed := time.Since(start).Seconds()
		info2, err := darwinProcTaskInfo(pid)
		if err != nil || elapsed < 0.01 {
			return
		}
		delta := float64((info2.TotalUser + info2.TotalSystem) - (info1.TotalUser + info1.TotalSystem))
		if delta > 0 {
			// One busy core ≈ elapsed seconds of CPU time.
			ticksPerSec = delta / elapsed
		}
		_ = sink
	})
}

// cpuPercentFromTaskInfo computes instantaneous %CPU from successive samples.
func cpuPercentFromTaskInfo(pid int, info procTaskInfo) float64 {
	ensureTicksPerSec()
	total := info.TotalUser + info.TotalSystem
	now := time.Now()
	cpu := 0.0
	if prev, ok := cpuSamples.Load(pid); ok {
		p := prev.(cpuSample)
		dt := now.Sub(p.at).Seconds()
		if dt > 0 && total >= p.totalTicks && ticksPerSec > 0 {
			dCPU := float64(total-p.totalTicks) / ticksPerSec
			cpu = 100.0 * dCPU / dt
		}
	}
	cpuSamples.Store(pid, cpuSample{at: now, totalTicks: total})
	if cpu < 0 {
		return 0
	}
	return cpu
}

// processCpuAndRSSForPIDViaPS returns %CPU and RSS bytes for pid via /bin/ps.
func processCpuAndRSSForPIDViaPS(pid int) (cpuPercent float64, rssBytes int64, err error) {
	out, err := exec.Command("/bin/ps", "-p", strconv.Itoa(pid), "-o", "rss=", "-o", "%cpu=").CombinedOutput()
	if err != nil {
		return 0, 0, fmt.Errorf("ps pid %d: %w (%s)", pid, err, strings.TrimSpace(string(out)))
	}
	fields := strings.Fields(strings.TrimSpace(string(out)))
	if len(fields) < 2 {
		return 0, 0, fmt.Errorf("unexpected ps output %q", strings.TrimSpace(string(out)))
	}
	kb, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return 0, 0, err
	}
	if kb < 0 {
		return 0, 0, fmt.Errorf("negative rss: %d", kb)
	}
	cpu, err := strconv.ParseFloat(fields[1], 64)
	if err != nil {
		return 0, 0, err
	}
	if cpu < 0 {
		cpu = 0
	}
	return cpu, kb * 1024, nil
}

// processCpuAndRSSByCommand finds the krunkit process whose argv references diskPath.
func processCpuAndRSSByCommand(diskPath string) (cpuPercent float64, rssBytes int64, err error) {
	diskPath = strings.TrimSpace(diskPath)
	if diskPath == "" {
		return 0, 0, fmt.Errorf("empty disk path")
	}
	out, err := exec.Command("/bin/ps", "-axo", "pid=,rss=,%cpu=,command=").CombinedOutput()
	if err != nil {
		return 0, 0, fmt.Errorf("ps scan: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	var bestCPU float64
	var bestRSS int64
	found := false
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || !strings.Contains(line, diskPath) || !strings.Contains(line, "krunkit") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		pid, pidErr := strconv.Atoi(fields[0])
		if pidErr != nil || pid < 1 {
			continue
		}
		if cpu, mem, probeErr := processCpuAndRSSForPID(pid); probeErr == nil {
			if !found || mem > bestRSS {
				bestCPU, bestRSS = cpu, mem
				found = true
			}
		}
	}
	if !found {
		return 0, 0, fmt.Errorf("no krunkit process for disk %s", diskPath)
	}
	return bestCPU, bestRSS, nil
}
