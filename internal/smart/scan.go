// Package smart 调用 smartctl 采集磁盘 SMART 数据，并把全部字段与提示翻译成简体中文。
// 只做这一件事：设备发现 → 读取 JSON → 中文报告。
package smart

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
)

type Disk struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Type     string `json:"type"`
	Protocol string `json:"protocol"`
	Label    string `json:"label"`
}

type scanDoc struct {
	Devices []struct {
		Name     string `json:"name"`
		Type     string `json:"type"`
		Protocol string `json:"protocol"`
	} `json:"devices"`
}

type Client struct {
	Binary string
	Runner func(ctx context.Context, name string, args ...string) ([]byte, error)
}

// NewClient 按优先级定位 smartctl：
// 1) DITKIT_SMARTCTL 环境变量显式指定；
// 2) 与 ditkitd 同目录的内嵌版本（安装包把二者一起放在 .app/Contents/MacOS）；
// 3) 系统 PATH 里的版本（开发态或用户自行 brew install）。
// 内嵌版只依赖系统自带的 IOKit/CoreFoundation，因此 DMG 安装后无需任何额外依赖。
func NewClient() (Client, error) {
	if custom := os.Getenv("DITKIT_SMARTCTL"); isExecutable(custom) {
		return Client{Binary: custom}, nil
	}
	if exe, err := os.Executable(); err == nil {
		sibling := filepath.Join(filepath.Dir(exe), "smartctl")
		if isExecutable(sibling) {
			return Client{Binary: sibling}, nil
		}
	}
	binary, err := exec.LookPath("smartctl")
	if err != nil {
		return Client{}, fmt.Errorf("未找到 smartctl：请使用完整安装包，或执行 brew install smartmontools")
	}
	return Client{Binary: binary}, nil
}

func isExecutable(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && !info.IsDir() && info.Mode()&0o111 != 0
}

func (c Client) run(ctx context.Context, args ...string) ([]byte, error) {
	if c.Runner != nil {
		return c.Runner(ctx, c.Binary, args...)
	}
	return exec.CommandContext(ctx, c.Binary, args...).Output()
}

// Scan 列出 smartctl 可访问的设备，返回带稳定 ID 的白名单。
func (c Client) Scan(ctx context.Context) ([]Disk, error) {
	out, err := c.run(ctx, "-j", "--scan")
	if err != nil && len(out) == 0 {
		return nil, fmt.Errorf("扫描磁盘设备失败: %w", err)
	}
	var doc scanDoc
	if err := json.Unmarshal(out, &doc); err != nil {
		return nil, fmt.Errorf("解析设备扫描结果: %w", err)
	}
	disks := make([]Disk, 0, len(doc.Devices))
	for _, d := range doc.Devices {
		sum := sha256.Sum256([]byte(d.Name))
		disks = append(disks, Disk{
			ID:       "disk_" + hex.EncodeToString(sum[:])[:10],
			Name:     d.Name,
			Type:     d.Type,
			Protocol: ProtocolLabel(d.Protocol, d.Type),
			Label:    diskLabel(d.Name, d.Protocol, d.Type),
		})
	}
	return disks, nil
}

// Resolve 按 ID 在白名单中查找设备，避免把任意用户输入传给 smartctl。
func (c Client) Resolve(ctx context.Context, id string) (Disk, error) {
	disks, err := c.Scan(ctx)
	if err != nil {
		return Disk{}, err
	}
	for _, d := range disks {
		if d.ID == id {
			return d, nil
		}
	}
	return Disk{}, fmt.Errorf("设备 %s 不在扫描结果中", id)
}

// Read 读取指定设备的完整 SMART JSON。即使 smartctl 退出码非 0 也返回数据，
// 因为退出码的位含义本身是需要翻译展示的信息。
func (c Client) Read(ctx context.Context, disk Disk) ([]byte, error) {
	args := []string{"-j", "-a", disk.Name}
	if disk.Type != "" {
		args = append(args, "-d", disk.Type)
	}
	out, err := c.run(ctx, args...)
	if len(out) == 0 {
		if err != nil {
			return nil, fmt.Errorf("读取 %s 的 SMART 数据失败: %w", disk.Label, err)
		}
		return nil, fmt.Errorf("smartctl 未返回数据")
	}
	return out, nil
}

func diskLabel(name, protocol, typ string) string {
	short := path.Base(strings.TrimSuffix(name, "/"))
	if len(short) > 36 {
		short = short[:36] + "…"
	}
	proto := ProtocolLabel(protocol, typ)
	if strings.Contains(name, "/dev/") {
		return fmt.Sprintf("%s · %s", proto, short)
	}
	return fmt.Sprintf("%s · %s", proto, short)
}
