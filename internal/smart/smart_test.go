package smart

import (
	"os"
	"strings"
	"testing"
)

func testDisk() Disk {
	return Disk{
		ID: "disk_test", Name: "/dev/disk0", Type: "nvme",
		Protocol: ProtocolLabel("NVMe", "nvme"), Label: "NVMe（高速固态硬盘接口） · disk0",
	}
}

// reportText 把报告的全部数据拼成一个字符串，便于对中文化做 contains 断言。
func reportText(r Report) string {
	var b strings.Builder
	b.WriteString(r.Overall + " " + r.Summary + " ")
	for _, s := range r.Sections {
		b.WriteString(s.Title + " ")
		for _, item := range s.Rows {
			b.WriteString(item.Label + item.Value + item.Note + " ")
		}
	}
	b.WriteString(strings.Join(r.Warnings, " ") + " ")
	b.WriteString(strings.Join(r.Messages, " ") + " ")
	b.WriteString(strings.Join(r.ExitNotes, " "))
	return b.String()
}

// 不提供 overall SMART status 的盘（部分 NVMe / USB），缺失字段不得被当成「未通过」而误报 critical。
func TestMissingSmartStatusIsNotCritical(t *testing.T) {
	raw := []byte(`{"smartctl":{"exit_status":0,"version":[7,4]},"model_name":"USB Disk","serial_number":"S1"}`)
	r, err := BuildReport(testDisk(), raw)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status == StatusCritical {
		t.Fatalf("缺失 smart_status 被误判为 critical: %+v", r)
	}
	text := reportText(r)
	if !strings.Contains(text, "该设备未提供") {
		t.Fatalf("应明确显示「该设备未提供」，实际: %s", text)
	}
	if strings.Contains(text, "SMART 总体自检未通过") {
		t.Fatalf("不应报「未通过」: %s", text)
	}
}

// 明确给出 smart_status.passed=false 时，仍必须判 critical。
func TestFailedSmartStatusIsCritical(t *testing.T) {
	raw := []byte(`{"smart_status":{"passed":false},"smartctl":{"exit_status":0}}`)
	r, err := BuildReport(testDisk(), raw)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status != StatusCritical {
		t.Fatalf("明确未通过应判 critical，实际: %s", r.Status)
	}
}

func TestBuildReportFromRealNVMe(t *testing.T) {
	raw, err := os.ReadFile("../../testdata/smart_nvme.json")
	if err != nil {
		t.Fatal(err)
	}
	r, err := BuildReport(testDisk(), raw)
	if err != nil {
		t.Fatal(err)
	}
	if r.Overall != "健康" {
		t.Fatalf("本机内置盘应判定为健康，got %s / %+v", r.Overall, r.Warnings)
	}
	if len(r.Sections) < 5 {
		t.Fatalf("报告分区过少: %d", len(r.Sections))
	}
	if r.ExitCode != 4 {
		t.Fatalf("真实退出码应为 4，got %d", r.ExitCode)
	}
	text := reportText(r)
	for _, want := range []string{
		"设备型号", "序列号", "固件版本", "本地时间",
		"临界警告字节", "当前温度", "可用备用空间", "寿命已用百分比",
		"累计读取数据单元", "主机读取命令数", "异常断电次数",
		"介质与数据完整性错误数", "错误日志条目数",
		"电源状态", "采集工具",
		"smartctl 提示：", "退出码 4", "部分 SMART 或日志命令执行失败",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("中文报告缺少 %q", want)
		}
	}
	for _, bad := range []string{
		"PASSED", "Celsius", "Model Number", "Critical Warning",
		"Read 1 entries from Error Information Log failed", "GetLogPage failed",
	} {
		if strings.Contains(text, bad) {
			t.Errorf("报告仍残留英文原文 %q", bad)
		}
	}
}

func TestReportRowsAreChinese(t *testing.T) {
	raw, _ := os.ReadFile("../../testdata/smart_nvme.json")
	r, _ := BuildReport(testDisk(), raw)
	var count int
	for _, s := range r.Sections {
		if !strings.HasPrefix(s.Title, "一、") && !strings.Contains(s.Title, "、") {
			t.Errorf("分区标题未中文化: %s", s.Title)
		}
		for _, row := range s.Rows {
			count++
			if row.Label == "" || row.Value == "" {
				t.Errorf("存在空行: %+v", row)
			}
		}
	}
	if count < 40 {
		t.Fatalf("详细报告行数不足: %d", count)
	}
}

func TestATAAttributesTranslated(t *testing.T) {
	raw := []byte(`{
		"device":{"name":"/dev/disk1","type":"sat","protocol":"ATA"},
		"model_name":"测试机械硬盘",
		"smart_status":{"passed":true},
		"smartctl":{"version":[7,5],"svn_revision":"5714","argv":["smartctl","-j","-a","/dev/disk1"],"exit_status":16,"messages":[]},
		"ata_smart_attributes":{"revision":{"number":1},"table":[
			{"id":5,"name":"Reallocated_Sector_Ct","value":90,"worst":90,"thresh":10,"when_failed":"FAILING_NOW","raw":{"value":123,"string":"123"}},
			{"id":194,"name":"Temperature_Celsius","value":35,"worst":50,"thresh":0,"when_failed":"","raw":{"value":35}}
		]}
	}`)
	r, err := BuildReport(testDisk(), raw)
	if err != nil {
		t.Fatal(err)
	}
	text := reportText(r)
	for _, want := range []string{"重映射扇区数", "温度", "当前已超出阈值", "ATA/SATA 属性表", "检测到预失败属性"} {
		if !strings.Contains(text, want) {
			t.Errorf("ATA 报告缺少 %q", want)
		}
	}
	if r.Status != StatusCritical {
		t.Errorf("FAILING_NOW 属性应判定为严重，got %s", r.Status)
	}
}

func TestRowsCarryStableKeysAndNumbers(t *testing.T) {
	raw, _ := os.ReadFile("../../testdata/smart_nvme.json")
	r, err := BuildReport(testDisk(), raw)
	if err != nil {
		t.Fatal(err)
	}
	var temperature Row
	found := false
	for _, s := range r.Sections {
		for _, row := range s.Rows {
			if row.Key == "nvme_temperature" {
				temperature, found = row, true
			}
		}
	}
	if !found {
		t.Fatal("NVMe 温度行缺少稳定 key")
	}
	if temperature.Numeric <= 0 {
		t.Errorf("NVMe 温度行缺少数值: %+v", temperature)
	}

	ataRaw := []byte(`{
		"device":{"name":"/dev/disk1","type":"sat","protocol":"ATA"},
		"smartctl":{"exit_status":0,"messages":[]},
		"ata_smart_attributes":{"table":[
			{"id":5,"name":"Reallocated_Sector_Ct","value":90,"worst":90,"thresh":10,"when_failed":"","raw":{"value":123}}
		]}
	}`)
	ata, err := BuildReport(testDisk(), ataRaw)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range ata.Sections {
		for _, row := range s.Rows {
			if row.Key == "ata_5" && row.Numeric == 123 {
				return
			}
		}
	}
	t.Fatal("ATA 重映射扇区行缺少 ata_5 键或原始数值")
}

func TestCriticalWarningBits(t *testing.T) {
	notes := CriticalWarningNotes(0b00000111)
	if len(notes) != 3 {
		t.Fatalf("应解析出 3 个警告位: %v", notes)
	}
	if !strings.Contains(strings.Join(notes, "；"), "备用空间") || !strings.Contains(strings.Join(notes, "；"), "温度") {
		t.Fatalf("位含义翻译错误: %v", notes)
	}
}

func TestExitStatusAndMessageTranslation(t *testing.T) {
	notes := ExitStatusNotes(4)
	if !strings.Contains(strings.Join(notes, "；"), "部分 SMART 或日志命令执行失败") {
		t.Fatalf("退出码位未翻译: %v", notes)
	}
	msg := TranslateMessage("Read 1 entries from Error Information Log failed: GetLogPage failed: system=0x38, code=745")
	if strings.Contains(msg, "Read 1 entries") || strings.Contains(msg, "GetLogPage failed") {
		t.Fatalf("英文提示未翻译: %s", msg)
	}
	if !strings.Contains(msg, "条错误信息日志失败") || !strings.Contains(msg, "0x38") {
		t.Fatalf("翻译内容不完整: %s", msg)
	}
}

func TestProtocolAndFormatting(t *testing.T) {
	if !strings.Contains(ProtocolLabel("NVMe", "nvme"), "NVMe") {
		t.Fatal("接口名称翻译异常")
	}
	if got := FormatDataUnits(19262727); !strings.Contains(got, "TiB") {
		t.Errorf("数据单位换算异常: %s", got)
	}
	if got := FormatHours(8760); !strings.Contains(got, "年") {
		t.Errorf("通电时长换算异常: %s", got)
	}
}
